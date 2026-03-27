import Foundation

/// Rips audio CD tracks from mounted AIFF files to WAV using macOS native afconvert.
@MainActor
class AudioCDRipper: ObservableObject {
    @Published var discName: String = ""
    @Published var tracks: [AudioCDTrack] = []
    @Published var isScanning = false
    @Published var isRipping = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var isComplete = false
    @Published var errorMessage: String? = nil
    @Published var currentRipIndex = 0
    @Published var totalRipCount = 0

    var onRipComplete: (() -> Void)?

    private var ripProcess: Process?
    private var volumePath: URL?

    // CD audio is always 44100 Hz, 16-bit, stereo = 176400 bytes/sec
    // AIFF has a 54-byte header, but we ignore that for a close-enough duration
    private let cdBytesPerSecond: Double = 176_400

    // MARK: - Scan

    func scan(volumePath: URL) {
        isScanning = true
        tracks = []
        discName = volumePath.lastPathComponent
        self.volumePath = volumePath
        statusMessage = "Reading tracks…"

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: volumePath,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            isScanning = false
            statusMessage = "Could not read disc"
            return
        }

        let aiffFiles = contents
            .filter { $0.pathExtension.lowercased() == "aiff" || $0.pathExtension.lowercased() == "cdda" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var parsed: [AudioCDTrack] = []
        for (index, file) in aiffFiles.enumerated() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeBytes = Int64(size)
            let durationSeconds = Int(Double(sizeBytes) / cdBytesPerSecond)
            let minutes = durationSeconds / 60
            let seconds = durationSeconds % 60
            let duration = "\(minutes):\(String(format: "%02d", seconds))"

            let baseName = file.deletingPathExtension().lastPathComponent
            let outputName = baseName + ".wav"

            parsed.append(AudioCDTrack(
                id: index + 1,
                filename: file.lastPathComponent,
                duration: duration,
                durationSeconds: durationSeconds,
                sizeBytes: sizeBytes,
                sizeLabel: formatSize(sizeBytes),
                outputName: outputName
            ))
        }

        tracks = parsed
        isScanning = false

        if tracks.isEmpty {
            statusMessage = "No audio tracks found"
        } else {
            statusMessage = "Found \(tracks.count) track\(tracks.count == 1 ? "" : "s")"
        }
    }

    // MARK: - Rip

    func rip(trackIDs: [Int], outputDir: URL) {
        let selectedTracks = tracks.filter { trackIDs.contains($0.id) }
        guard !selectedTracks.isEmpty, let vol = volumePath else { return }

        // If multiple tracks, create a subfolder named after the disc
        let actualDir: URL
        if selectedTracks.count > 1 {
            let folderName = discName.isEmpty ? "Audio CD" : discName
            actualDir = outputDir.appendingPathComponent(folderName)
            try? FileManager.default.createDirectory(at: actualDir, withIntermediateDirectories: true)
        } else {
            actualDir = outputDir
        }

        totalRipCount = selectedTracks.count
        currentRipIndex = 0
        isRipping = true
        isComplete = false
        progress = 0

        Task {
            for track in selectedTracks {
                currentRipIndex += 1
                let inputPath = vol.appendingPathComponent(track.filename)
                let outputPath = actualDir.appendingPathComponent(track.outputName)

                if totalRipCount > 1 {
                    statusMessage = "Converting track \(currentRipIndex)/\(totalRipCount)…"
                } else {
                    statusMessage = "Converting…"
                }

                let success = await convertTrack(input: inputPath, output: outputPath)
                if !success {
                    errorMessage = "Failed to convert \(track.filename)"
                    isRipping = false
                    return
                }

                progress = Double(currentRipIndex) / Double(totalRipCount)
            }

            isRipping = false
            isComplete = true
            progress = 1.0
            statusMessage = "Done!"
            onRipComplete?()
        }
    }

    private func convertTrack(input: URL, output: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            ripProcess = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-d", "LEI16", "-f", "WAVE", input.path, output.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.ripProcess = nil
                    continuation.resume(returning: p.terminationStatus == 0)
                }
            }

            do {
                try process.run()
            } catch {
                ripProcess = nil
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        ripProcess?.terminate()
        ripProcess = nil
        isRipping = false
        statusMessage = "Cancelled"
    }

    // MARK: - Reset

    func reset() {
        tracks = []
        discName = ""
        volumePath = nil
        if !isComplete {
            progress = 0
            statusMessage = ""
        }
    }

    // MARK: - Helpers

    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}
