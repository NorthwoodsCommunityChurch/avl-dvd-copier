import Foundation

/// Rips DVD video from mounted VIDEO_TS folders using ffmpeg when MakeMKV can't read the disc.
/// Groups VOB files by title set and remuxes each into an .mpg file.
@MainActor
class DVDFallbackRipper: ObservableObject {
    @Published var discName: String = ""
    @Published var titleSets: [TitleSet] = []
    @Published var isScanning = false
    @Published var isRipping = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var isComplete = false
    @Published var errorMessage: String? = nil
    @Published var currentRipIndex = 0
    @Published var totalRipCount = 0

    var onRipComplete: (() -> Void)?

    private var volumePath: URL?
    private var ripProcess: Process?
    private var activeErrPipe: Pipe?
    private var isCancelled = false

    struct TitleSet: Identifiable, Equatable {
        let id: Int
        let vobFiles: [URL]
        let totalSize: Int64
        var sizeLabel: String {
            let gb = Double(totalSize) / 1_073_741_824
            if gb >= 1.0 { return String(format: "%.1f GB", gb) }
            return String(format: "%.1f MB", Double(totalSize) / 1_048_576)
        }
    }

    // MARK: - Scan

    func scan(volumePath: URL) {
        isScanning = true
        self.volumePath = volumePath
        discName = volumePath.lastPathComponent
        statusMessage = "Reading disc…"
        titleSets = []

        let videoTS = volumePath.appendingPathComponent("VIDEO_TS")
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: videoTS,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            isScanning = false
            statusMessage = "No VIDEO_TS folder found"
            return
        }

        // Group VOB files by title set number (VTS_XX_N.VOB where N > 0)
        var groups: [Int: [URL]] = [:]
        var sizes: [Int: Int64] = [:]

        for file in contents {
            let name = file.lastPathComponent.uppercased()
            guard name.hasSuffix(".VOB") else { continue }
            // Skip menu/navigation VOBs (VTS_XX_0.VOB and VIDEO_TS.VOB)
            guard name.hasPrefix("VTS_") else { continue }

            let parts = name.replacingOccurrences(of: ".VOB", with: "").components(separatedBy: "_")
            // parts: ["VTS", "01", "1"]
            guard parts.count == 3,
                  let setNum = Int(parts[1]),
                  let partNum = Int(parts[2]),
                  partNum > 0 else { continue }

            groups[setNum, default: []].append(file)
            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizes[setNum, default: 0] += Int64(fileSize)
        }

        // Sort VOBs within each group and build title sets
        var sets: [TitleSet] = []
        for (setNum, files) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            sets.append(TitleSet(id: setNum, vobFiles: sorted, totalSize: sizes[setNum] ?? 0))
        }

        titleSets = sets
        isScanning = false

        if sets.isEmpty {
            statusMessage = "No video content found"
        } else {
            let totalSize = sizes.values.reduce(0, +)
            let gb = Double(totalSize) / 1_073_741_824
            let sizeStr = gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.1f MB", Double(totalSize) / 1_048_576)
            statusMessage = "\(sets.count) title\(sets.count == 1 ? "" : "s"), \(sizeStr)"
        }
    }

    // MARK: - Rip

    func rip(titleSetIDs: [Int], outputDir: URL) {
        guard !isRipping else { return }
        let selected = titleSets.filter { titleSetIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let folderName = discName.isEmpty ? "DVD" : discName
        let destDir = outputDir.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        isRipping = true
        isComplete = false
        isCancelled = false
        progress = 0
        currentRipIndex = 0
        totalRipCount = selected.count

        Task {
            for titleSet in selected {
                if isCancelled { break }

                currentRipIndex += 1
                let outputName = selected.count == 1
                    ? "\(folderName).mpg"
                    : "\(folderName) - Title \(titleSet.id).mpg"
                let outputPath = destDir.appendingPathComponent(outputName)

                statusMessage = totalRipCount > 1
                    ? "Converting title \(currentRipIndex)/\(totalRipCount)…"
                    : "Converting…"

                let success = await convertTitleSet(titleSet, output: outputPath)
                if !success && !isCancelled {
                    errorMessage = "Failed to convert title set \(titleSet.id)"
                    isRipping = false
                    return
                }

                progress = Double(currentRipIndex) / Double(totalRipCount)
            }

            isRipping = false

            if isCancelled {
                statusMessage = "Cancelled"
            } else {
                isComplete = true
                progress = 1.0
                statusMessage = "Done!"
                onRipComplete?()
            }
        }
    }

    // MARK: - Convert

    private func convertTitleSet(_ titleSet: TitleSet, output: URL) async -> Bool {
        let totalBytes = titleSet.totalSize

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let concatInput = titleSet.vobFiles.map(\.path).joined(separator: "|")

            let process = Process()
            ripProcess = process
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            process.arguments = [
                "-i", "concat:\(concatInput)",
                "-c", "copy",
                "-y",
                output.path
            ]
            // Discard stdout
            process.standardOutput = FileHandle.nullDevice

            // Read stderr to prevent pipe deadlock and parse progress
            let errPipe = Pipe()
            activeErrPipe = errPipe
            process.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                // ffmpeg progress: "size=  123456KiB time=00:01:23.45 ..."
                let regex = try? NSRegularExpression(pattern: #"size=\s*(\d+)\s*[kK]i[Bb]"#)
                let nsRange = NSRange(chunk.startIndex..., in: chunk)
                if let result = regex?.firstMatch(in: chunk, range: nsRange),
                   let numRange = Range(result.range(at: 1), in: chunk),
                   let sizeKB = Double(chunk[numRange]),
                   totalBytes > 0 {
                    let fraction = min((sizeKB * 1024) / Double(totalBytes), 0.99)
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                    }
                }
            }

            process.terminationHandler = { [weak self] p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    self?.ripProcess = nil
                    continuation.resume(returning: p.terminationStatus == 0)
                }
            }

            do {
                try process.run()
            } catch {
                ripProcess = nil
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Failed to launch ffmpeg: \(error.localizedDescription)"
                }
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
        activeErrPipe?.fileHandleForReading.readabilityHandler = nil
        activeErrPipe = nil
        ripProcess?.terminate()
    }

    // MARK: - Reset

    func reset() {
        titleSets = []
        discName = ""
        volumePath = nil
        isCancelled = false
        if !isComplete {
            progress = 0
            statusMessage = ""
        }
    }
}
