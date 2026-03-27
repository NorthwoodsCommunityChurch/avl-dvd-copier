import DiskArbitration
import Foundation

/// Watches for optical disc insertion and ejection using macOS DiskArbitration framework.
class DiscWatcher: ObservableObject {
    private var session: DASession?
    var onDiscInserted: ((_ mediaKind: String, _ volumePath: URL?) -> Void)?
    var onDiscEjected: (() -> Void)?

    func start() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Callback when any disc appears
        let appeared: DADiskAppearedCallback = { disk, context in
            guard let context else { return }
            let watcher = Unmanaged<DiscWatcher>.fromOpaque(context).takeUnretainedValue()
            if let info = watcher.opticalDiscInfo(disk) {
                watcher.onDiscInserted?(info.mediaKind, info.volumePath)
            }
        }

        // Callback when any disc disappears
        let disappeared: DADiskDisappearedCallback = { disk, context in
            guard let context else { return }
            let watcher = Unmanaged<DiscWatcher>.fromOpaque(context).takeUnretainedValue()
            if watcher.isOpticalDisc(disk) {
                watcher.onDiscEjected?()
            }
        }

        // nil match = all discs, we filter in the callback
        DARegisterDiskAppearedCallback(session, nil, appeared, selfPtr)
        DARegisterDiskDisappearedCallback(session, nil, disappeared, selfPtr)
    }

    func stop() {
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        session = nil
    }

    /// Returns media kind and volume path if this is an optical disc, nil otherwise.
    private func opticalDiscInfo(_ disk: DADisk) -> (mediaKind: String, volumePath: URL?)? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        guard let mediaKind = desc[kDADiskDescriptionMediaKindKey as String] as? String,
              mediaKind.contains("DVD") || mediaKind.contains("CD") || mediaKind.contains("BD")
        else { return nil }

        let volumePath = desc[kDADiskDescriptionVolumePathKey as String] as? URL
        return (mediaKind, volumePath)
    }

    /// Check if a disk is optical media (DVD, CD, or Blu-ray).
    private func isOpticalDisc(_ disk: DADisk) -> Bool {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        if let mediaKind = desc[kDADiskDescriptionMediaKindKey as String] as? String {
            return mediaKind.contains("DVD") || mediaKind.contains("CD") || mediaKind.contains("BD")
        }
        return false
    }

    deinit {
        stop()
    }
}
