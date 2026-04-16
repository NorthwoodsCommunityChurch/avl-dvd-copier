import Foundation
import Combine
import AppKit

/// Owns all disc detection, ripping, and state coordination.
/// Lives as a class so closures capture a stable reference, not a stale struct copy.
@MainActor
class DiscCoordinator: ObservableObject {
    // MARK: - Rippers (owned)
    let ripper = DVDRipper()
    let fallbackRipper = DVDFallbackRipper()
    let audioCDRipper = AudioCDRipper()
    let dataCDCopier = DataCDCopier()
    private let discWatcher = DiscWatcher()

    // MARK: - Published State
    @Published var discType: DiscType = .none
    @Published var isEjecting = false
    @Published var selectedTitleIDs: Set<Int> = []
    @Published var selectedFallbackIDs: Set<Int> = []
    @Published var selectedTrackIDs: Set<Int> = []

    // Pushed from ContentView
    var outputFolder: URL?
    var autoRip: Bool = false

    // Queued disc event (for discs arriving during eject window)
    private var pendingDiscEvent: (mediaKind: String, volumePath: URL?)?

    // Forward nested ObservableObject changes to SwiftUI
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Computed

    var canRipDVD: Bool {
        !selectedTitleIDs.isEmpty && outputFolder != nil
            && !ripper.isScanning && !ripper.isRipping
    }

    var canRipFallback: Bool {
        !selectedFallbackIDs.isEmpty && outputFolder != nil
            && !fallbackRipper.isScanning && !fallbackRipper.isRipping
    }

    var canRipAudio: Bool {
        !selectedTrackIDs.isEmpty && outputFolder != nil
            && !audioCDRipper.isScanning && !audioCDRipper.isRipping
    }

    var canCopyData: Bool {
        dataCDCopier.fileCount > 0 && outputFolder != nil
            && !dataCDCopier.isScanning && !dataCDCopier.isCopying
    }

    var isBusy: Bool {
        ripper.isScanning || ripper.isRipping
            || fallbackRipper.isScanning || fallbackRipper.isRipping
            || audioCDRipper.isScanning || audioCDRipper.isRipping
            || dataCDCopier.isScanning || dataCDCopier.isCopying
    }

    var isComplete: Bool {
        ripper.isComplete || fallbackRipper.isComplete
            || audioCDRipper.isComplete || dataCDCopier.isComplete
    }

    var discDetected: Bool {
        switch discType {
        case .dvd: return ripper.discDetected
        case .dvdFallback: return !fallbackRipper.titleSets.isEmpty
        case .audioCD: return !audioCDRipper.tracks.isEmpty
        case .dataCD: return dataCDCopier.fileCount > 0
        case .none: return false
        }
    }

    var currentDiscName: String {
        switch discType {
        case .dvd: return ripper.discName.isEmpty ? "DVD" : ripper.discName
        case .dvdFallback: return fallbackRipper.discName.isEmpty ? "DVD" : fallbackRipper.discName
        case .audioCD: return audioCDRipper.discName.isEmpty ? "Audio CD" : audioCDRipper.discName
        case .dataCD: return dataCDCopier.discName.isEmpty ? "Data CD" : dataCDCopier.discName
        case .none: return ""
        }
    }

    var currentStatusMessage: String {
        switch discType {
        case .dvd: return ripper.statusMessage
        case .dvdFallback: return fallbackRipper.statusMessage
        case .audioCD: return audioCDRipper.statusMessage
        case .dataCD: return dataCDCopier.statusMessage
        case .none:
            if isComplete {
                if !ripper.statusMessage.isEmpty { return ripper.statusMessage }
                if !fallbackRipper.statusMessage.isEmpty { return fallbackRipper.statusMessage }
                if !audioCDRipper.statusMessage.isEmpty { return audioCDRipper.statusMessage }
                return dataCDCopier.statusMessage
            }
            return ""
        }
    }

    var activeError: String? {
        ripper.errorMessage ?? fallbackRipper.errorMessage
            ?? audioCDRipper.errorMessage ?? dataCDCopier.errorMessage
    }

    var isScanning: Bool {
        ripper.isScanning || fallbackRipper.isScanning
            || audioCDRipper.isScanning || dataCDCopier.isScanning
    }

    private var isStarted = false

    // MARK: - Init & Start

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Forward child ObservableObject changes so SwiftUI re-renders
        ripper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        fallbackRipper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        audioCDRipper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        dataCDCopier.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        setupCompletionHandlers()
        setupDiscWatcher()
    }

    // MARK: - Disc Watcher

    private func setupDiscWatcher() {
        discWatcher.onDiscInserted = { [weak self] mediaKind, volumePath in
            Task { @MainActor [weak self] in
                self?.handleDiscInserted(mediaKind: mediaKind, volumePath: volumePath)
            }
        }
        discWatcher.onDiscEjected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDiscEjected()
            }
        }
        discWatcher.start()
    }

    private func handleDiscInserted(mediaKind: String, volumePath: URL?) {
        if isEjecting {
            // Queue the event — process when eject finishes
            pendingDiscEvent = (mediaKind, volumePath)
            return
        }

        // Don't reset during an active rip
        guard !isBusy else { return }

        resetAll()

        if mediaKind.contains("DVD") {
            discType = .dvd
            ripper.discConfirmedByDA = true
            ripper.statusMessage = "Disc detected, reading…"
            ripper.discDetected = false
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !self.ripper.isRipping, !self.ripper.isScanning, !self.isEjecting else { return }
                self.ripper.scan()
            }
        } else if mediaKind.contains("CD") {
            Task {
                let mountPath = await self.waitForMount(volumePath: volumePath)
                guard !self.isEjecting else { return }

                if let mountPath {
                    if self.isAudioCD(at: mountPath) {
                        self.discType = .audioCD
                        self.audioCDRipper.scan(volumePath: mountPath)
                    } else {
                        self.discType = .dataCD
                        self.dataCDCopier.scan(volumePath: mountPath)
                    }
                }
            }
        }
    }

    private func handleDiscEjected() {
        guard !isEjecting else { return }
        let wasComplete = isComplete
        ripper.discConfirmedByDA = false
        ripper.resetDisc()
        fallbackRipper.reset()
        audioCDRipper.reset()
        dataCDCopier.reset()
        if !wasComplete {
            discType = .none
        }
    }

    private func setupCompletionHandlers() {
        ripper.onRipComplete = { [weak self] in self?.ejectAfterRip() }
        ripper.onScanFailed = { [weak self] in self?.fallbackToCopy() }
        fallbackRipper.onRipComplete = { [weak self] in self?.ejectAfterRip() }
        audioCDRipper.onRipComplete = { [weak self] in self?.ejectAfterRip() }
        dataCDCopier.onCopyComplete = { [weak self] in self?.ejectAfterRip() }
    }

    // MARK: - Auto-Rip Handlers (called from ContentView .onChange)

    func handleTitlesChanged(_ titles: [DVDTitle]) {
        if autoRip {
            selectedTitleIDs = Set(titles.map(\.id))
        } else if let first = titles.first {
            selectedTitleIDs = [first.id]
        } else {
            selectedTitleIDs = []
        }
        if autoRip && !titles.isEmpty && outputFolder != nil && !ripper.isRipping {
            startDVDRip()
        }
    }

    func handleTracksChanged(_ tracks: [AudioCDTrack]) {
        selectedTrackIDs = Set(tracks.map(\.id))
        if autoRip && !tracks.isEmpty && outputFolder != nil && !audioCDRipper.isRipping {
            startAudioRip()
        }
    }

    func handleFallbackTitleSetsChanged(_ sets: [DVDFallbackRipper.TitleSet]) {
        selectedFallbackIDs = Set(sets.map(\.id))
        if autoRip && !sets.isEmpty && outputFolder != nil && !fallbackRipper.isRipping {
            startFallbackRip()
        }
    }

    func handleFileCountChanged(_ count: Int) {
        if autoRip && count > 0 && outputFolder != nil && !dataCDCopier.isCopying {
            startDataCopy()
        }
    }

    // MARK: - Rip Actions

    func startDVDRip() {
        guard !selectedTitleIDs.isEmpty, let folder = outputFolder else { return }
        ripper.ripMultiple(titleIndices: selectedTitleIDs.sorted(), outputDir: folder)
    }

    func startAudioRip() {
        guard !selectedTrackIDs.isEmpty, let folder = outputFolder else { return }
        audioCDRipper.rip(trackIDs: selectedTrackIDs.sorted(), outputDir: folder)
    }

    func startFallbackRip() {
        guard !selectedFallbackIDs.isEmpty, let folder = outputFolder else { return }
        fallbackRipper.rip(titleSetIDs: selectedFallbackIDs.sorted(), outputDir: folder)
    }

    func startDataCopy() {
        guard let folder = outputFolder else { return }
        dataCDCopier.copy(outputDir: folder)
    }

    // MARK: - Eject

    func ejectDisc() {
        _ = Process.run("/usr/bin/drutil", args: ["eject"])
        ripper.resetDisc()
        fallbackRipper.reset()
        audioCDRipper.reset()
        dataCDCopier.reset()
        discType = .none
    }

    func ejectAfterRip() {
        isEjecting = true

        // Capture disc type NOW so async blocks don't read stale/changed values
        let currentDiscType = discType

        let discLabel: String
        switch currentDiscType {
        case .dvd, .dvdFallback: discLabel = "DVD"
        case .audioCD, .dataCD: discLabel = "CD"
        case .none: discLabel = "disc"
        }

        // Set status on the active handler
        switch currentDiscType {
        case .dvd: ripper.statusMessage = "Rip complete — ejecting disc…"
        case .dvdFallback: fallbackRipper.statusMessage = "Rip complete — ejecting disc…"
        case .audioCD: audioCDRipper.statusMessage = "Rip complete — ejecting disc…"
        case .dataCD: dataCDCopier.statusMessage = "Copy complete — ejecting disc…"
        case .none: break
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            _ = Process.run("/usr/bin/drutil", args: ["eject"])

            switch currentDiscType {
            case .dvd: self.ripper.statusMessage = "Rip complete — disc ejected. Insert another \(discLabel)."
            case .dvdFallback: self.fallbackRipper.statusMessage = "Rip complete — disc ejected. Insert another disc."
            case .audioCD: self.audioCDRipper.statusMessage = "Rip complete — disc ejected. Insert another disc."
            case .dataCD: self.dataCDCopier.statusMessage = "Copy complete — disc ejected. Insert another disc."
            case .none: break
            }

            self.discType = .none

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.isEjecting = false

                // Process any disc that arrived during the eject window
                if let pending = self.pendingDiscEvent {
                    self.pendingDiscEvent = nil
                    self.handleDiscInserted(mediaKind: pending.mediaKind, volumePath: pending.volumePath)
                }
            }
        }
    }

    // MARK: - Reset

    func resetCompletion() {
        ripper.isComplete = false
        ripper.progress = 0
        ripper.statusMessage = ""
        fallbackRipper.isComplete = false
        fallbackRipper.progress = 0
        fallbackRipper.statusMessage = ""
        audioCDRipper.isComplete = false
        audioCDRipper.progress = 0
        audioCDRipper.statusMessage = ""
        dataCDCopier.isComplete = false
        dataCDCopier.progress = 0
        dataCDCopier.statusMessage = ""
        // Also clear selections to prevent stale IDs on next disc
        selectedTitleIDs = []
        selectedFallbackIDs = []
        selectedTrackIDs = []
        discType = .none
    }

    func resetAll() {
        ripper.resetDisc()
        ripper.isComplete = false
        ripper.progress = 0
        fallbackRipper.reset()
        fallbackRipper.isComplete = false
        fallbackRipper.progress = 0
        audioCDRipper.reset()
        audioCDRipper.isComplete = false
        audioCDRipper.progress = 0
        dataCDCopier.reset()
        dataCDCopier.isComplete = false
        dataCDCopier.progress = 0
        selectedTitleIDs = []
        selectedFallbackIDs = []
        selectedTrackIDs = []
    }

    func clearErrors() {
        ripper.errorMessage = nil
        fallbackRipper.errorMessage = nil
        audioCDRipper.errorMessage = nil
        dataCDCopier.errorMessage = nil
    }

    // MARK: - Rescan

    func rescan() {
        switch discType {
        case .dvd: ripper.scan()
        case .dvdFallback:
            if let vol = findDVDVolume() { fallbackRipper.scan(volumePath: vol) }
        case .audioCD:
            if !audioCDRipper.discName.isEmpty {
                let vol = URL(fileURLWithPath: "/Volumes/\(audioCDRipper.discName)")
                audioCDRipper.scan(volumePath: vol)
            }
        case .dataCD:
            if !dataCDCopier.discName.isEmpty {
                let vol = URL(fileURLWithPath: "/Volumes/\(dataCDCopier.discName)")
                dataCDCopier.scan(volumePath: vol)
            }
        case .none: break
        }
    }

    // MARK: - Reveal Output

    func revealOutput() {
        guard let folder = outputFolder else { return }
        switch discType {
        case .dvd:
            if selectedTitleIDs.count > 1 {
                let folderName = ripper.discName.isEmpty ? "DVD" : ripper.discName
                let subFolder = folder.appendingPathComponent(folderName)
                NSWorkspace.shared.selectFile(subFolder.path, inFileViewerRootedAtPath: "")
            } else if let titleID = selectedTitleIDs.first,
                      let title = ripper.titles.first(where: { $0.id == titleID }) {
                let fileURL = folder.appendingPathComponent(title.outputName)
                NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
            }
        case .dvdFallback:
            let folderName = fallbackRipper.discName.isEmpty ? "DVD" : fallbackRipper.discName
            let subFolder = folder.appendingPathComponent(folderName)
            NSWorkspace.shared.selectFile(subFolder.path, inFileViewerRootedAtPath: "")
        case .audioCD:
            if selectedTrackIDs.count > 1 {
                let folderName = audioCDRipper.discName.isEmpty ? "Audio CD" : audioCDRipper.discName
                let subFolder = folder.appendingPathComponent(folderName)
                NSWorkspace.shared.selectFile(subFolder.path, inFileViewerRootedAtPath: "")
            } else if let trackID = selectedTrackIDs.first,
                      let track = audioCDRipper.tracks.first(where: { $0.id == trackID }) {
                let fileURL = folder.appendingPathComponent(track.outputName)
                NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
            }
        case .dataCD:
            let folderName = dataCDCopier.discName.isEmpty ? "Data CD" : dataCDCopier.discName
            let subFolder = folder.appendingPathComponent(folderName)
            NSWorkspace.shared.selectFile(subFolder.path, inFileViewerRootedAtPath: "")
        case .none: break
        }
    }

    // MARK: - Helpers

    func findDVDVolume() -> URL? {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        for name in volumes {
            let vol = URL(fileURLWithPath: "/Volumes/\(name)")
            let videoTS = vol.appendingPathComponent("VIDEO_TS")
            if fm.fileExists(atPath: videoTS.path) {
                return vol
            }
        }
        return nil
    }

    func fallbackToCopy() {
        guard let vol = findDVDVolume() else { return }
        ripper.resetDisc()
        discType = .dvdFallback
        fallbackRipper.scan(volumePath: vol)
    }

    private func waitForMount(volumePath: URL?) async -> URL? {
        let fm = FileManager.default

        if let volumePath, fm.fileExists(atPath: volumePath.path) {
            return volumePath
        }

        let volumesBefore = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)

            if let volumePath, fm.fileExists(atPath: volumePath.path) {
                return volumePath
            }

            let volumesNow = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            let newVolumes = volumesNow.subtracting(volumesBefore)
            if let newVolume = newVolumes.first {
                return URL(fileURLWithPath: "/Volumes/\(newVolume)")
            }
        }
        // Return nil instead of the original path if mount wasn't found
        return nil
    }

    private func isAudioCD(at url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        guard !contents.isEmpty else { return false }

        return contents.allSatisfy { file in
            let ext = file.pathExtension.lowercased()
            return ext == "aiff" || ext == "cdda"
        }
    }
}
