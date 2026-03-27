import Foundation

/// Copies files from a mounted data CD to a local folder.
@MainActor
class DataCDCopier: ObservableObject {
    @Published var discName: String = ""
    @Published var fileCount: Int = 0
    @Published var totalSize: Int64 = 0
    @Published var totalSizeLabel: String = ""
    @Published var isScanning = false
    @Published var isCopying = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var isComplete = false
    @Published var errorMessage: String? = nil

    var onCopyComplete: (() -> Void)?

    private var volumePath: URL?
    private var filesToCopy: [URL] = []
    private var isCancelled = false

    // MARK: - Scan

    func scan(volumePath: URL) {
        isScanning = true
        self.volumePath = volumePath
        discName = volumePath.lastPathComponent
        statusMessage = "Reading disc…"
        fileCount = 0
        totalSize = 0
        filesToCopy = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: volumePath,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            isScanning = false
            statusMessage = "Could not read disc"
            return
        }

        var files: [URL] = []
        var size: Int64 = 0

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files.append(url)
            size += Int64(values.fileSize ?? 0)
        }

        filesToCopy = files
        fileCount = files.count
        totalSize = size
        totalSizeLabel = formatSize(size)
        isScanning = false

        if fileCount == 0 {
            statusMessage = "Disc is empty"
        } else {
            statusMessage = "\(fileCount) file\(fileCount == 1 ? "" : "s"), \(totalSizeLabel)"
        }
    }

    // MARK: - Copy

    func copy(outputDir: URL) {
        guard let vol = volumePath, !filesToCopy.isEmpty else { return }

        let folderName = discName.isEmpty ? "Data CD" : discName
        let destDir = outputDir.appendingPathComponent(folderName)

        isCopying = true
        isComplete = false
        isCancelled = false
        progress = 0

        Task {
            let fm = FileManager.default
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            var copiedBytes: Int64 = 0
            var copiedCount = 0

            for file in filesToCopy {
                if isCancelled { break }

                // Preserve directory structure relative to volume root
                let relativePath = file.path.replacingOccurrences(of: vol.path + "/", with: "")
                let destFile = destDir.appendingPathComponent(relativePath)

                // Create parent directories
                let parentDir = destFile.deletingLastPathComponent()
                try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

                do {
                    // Remove existing file if present (re-copy scenario)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: file, to: destFile)
                } catch {
                    errorMessage = "Failed to copy \(file.lastPathComponent): \(error.localizedDescription)"
                    isCopying = false
                    return
                }

                let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                copiedBytes += Int64(fileSize)
                copiedCount += 1

                statusMessage = "Copying \(copiedCount)/\(fileCount)…"
                if totalSize > 0 {
                    progress = Double(copiedBytes) / Double(totalSize)
                }
            }

            isCopying = false

            if isCancelled {
                statusMessage = "Cancelled"
            } else {
                isComplete = true
                progress = 1.0
                statusMessage = "Done!"
                onCopyComplete?()
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
    }

    // MARK: - Reset

    func reset() {
        filesToCopy = []
        fileCount = 0
        totalSize = 0
        totalSizeLabel = ""
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
