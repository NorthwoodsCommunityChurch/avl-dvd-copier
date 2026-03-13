import Foundation

/// Wraps makemkvcon to scan DVD titles and rip them to MKV.
@MainActor
class DVDRipper: ObservableObject {
    @Published var discName: String = ""
    @Published var titles: [DVDTitle] = []
    @Published var isScanning = false
    @Published var isRipping = false
    @Published var progress: Double = 0
    @Published var progressMax: Double = 1
    @Published var statusMessage = ""
    @Published var isComplete = false
    @Published var currentRipIndex = 0
    @Published var totalRipCount = 0
    @Published var errorMessage: String? = nil
    @Published var discDetected = false

    private var ripProcess: Process?
    private let discWatcher = DiscWatcher()

    private let makemkvconPath = "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"

    // MARK: - Disc Watching

    func startWatching() {
        discWatcher.onDiscInserted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isRipping, !self.isScanning else { return }
                self.statusMessage = "Disc detected, reading…"
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s for drive spin-up
                guard !self.isRipping, !self.isScanning else { return } // re-check after delay
                self.scan()
            }
        }
        discWatcher.onDiscEjected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.resetDisc()
            }
        }
        discWatcher.start()
    }

    func resetDisc() {
        guard !isRipping else { return }
        discDetected = false
        titles = []
        discName = ""
        isComplete = false
        progress = 0
        statusMessage = ""
    }

    var isMakeMKVInstalled: Bool {
        FileManager.default.fileExists(atPath: makemkvconPath)
    }

    // MARK: - Scan

    func scan() {
        guard isMakeMKVInstalled else {
            errorMessage = "MakeMKV is not installed.\n\nDownload it from makemkv.com and drag it to Applications."
            return
        }

        // Don't scan while ripping or already scanning
        guard !isRipping && !isScanning else { return }

        isScanning = true
        discDetected = false
        titles = []
        discName = ""
        errorMessage = nil
        statusMessage = "Scanning disc…"

        let path = makemkvconPath
        Task.detached {
            let output = await Self.runScan(makemkvconPath: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.parseScanOutput(output)
                self.isScanning = false
            }
        }
    }

    private static func runScan(makemkvconPath: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: makemkvconPath)
        // --robot for machine-readable output, --minlength=0 to show all titles
        process.arguments = ["--robot", "--minlength=0", "info", "disc:0"]

        // Use separate pipes to avoid deadlock when output exceeds buffer
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read data asynchronously to prevent pipe buffer deadlock
        var outputData = Data()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputData.append(data) }
        }
        // Discard stderr (just drain it so it doesn't block)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try? process.run()
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Read any remaining data
        outputData.append(outPipe.fileHandleForReading.readDataToEndOfFile())

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func parseScanOutput(_ output: String) {
        var parsed: [DVDTitle] = []
        // Temp storage keyed by title index
        var titleData: [Int: [Int: String]] = [:]  // [titleIdx: [attrCode: value]]

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // CINFO:2,0,"Disc Name"
            if line.hasPrefix("CINFO:2,") {
                discName = extractQuotedValue(line) ?? ""
                discDetected = true
            }

            // TCOUNT:N — confirms disc was readable
            if line.hasPrefix("TCOUNT:") {
                discDetected = true
            }

            // MSG:5010 — "Failed to open disc"
            if line.contains("MSG:5010") {
                errorMessage = "Failed to open disc. Make sure the DVD is inserted and MakeMKV is not already open."
                discDetected = false
                return
            }

            // TINFO:titleIdx,attrCode,attrFlag,"value"
            if line.hasPrefix("TINFO:") {
                let parts = line.dropFirst("TINFO:".count).components(separatedBy: ",")
                if parts.count >= 4,
                   let titleIdx = Int(parts[0]),
                   let attrCode = Int(parts[1]) {
                    let value = extractQuotedValue(line) ?? ""
                    titleData[titleIdx, default: [:]][attrCode] = value
                }
            }
        }

        // Build DVDTitle objects from parsed TINFO data
        for (idx, attrs) in titleData.sorted(by: { $0.key < $1.key }) {
            let duration = attrs[9] ?? "0:00:00"    // attribute 9 = duration
            let chapters = Int(attrs[8] ?? "0") ?? 0 // attribute 8 = chapter count
            let sizeLabel = attrs[10] ?? ""          // attribute 10 = human-readable size
            let sizeBytes = Int64(attrs[11] ?? "0") ?? 0  // attribute 11 = size in bytes
            let outputName = attrs[27] ?? "title_\(idx).mkv" // attribute 27 = suggested filename
            let description = attrs[30] ?? ""        // attribute 30 = summary description

            let secs = parseDuration(duration)

            parsed.append(DVDTitle(
                id: idx,
                duration: duration,
                durationSeconds: secs,
                chapters: chapters,
                sizeBytes: sizeBytes,
                sizeLabel: sizeLabel,
                outputName: outputName,
                description: description
            ))
        }

        titles = parsed.sorted { $0.durationSeconds > $1.durationSeconds }

        if discDetected && titles.isEmpty {
            statusMessage = "No titles found on disc."
        } else if discDetected {
            statusMessage = "Found \(titles.count) title\(titles.count == 1 ? "" : "s")"
        } else {
            statusMessage = "No disc detected"
        }
    }

    // MARK: - Rip

    func rip(titleIndex: Int, outputDir: URL) {
        guard isMakeMKVInstalled else {
            errorMessage = "MakeMKV is not installed."
            return
        }

        isRipping = true
        isComplete = false
        progress = 0
        progressMax = 1
        statusMessage = "Starting…"
        errorMessage = nil

        let process = Process()
        ripProcess = process
        process.executableURL = URL(fileURLWithPath: makemkvconPath)
        process.arguments = [
            "--robot",
            "--progress=-same",
            "--minlength=0",
            "mkv",
            "disc:0",
            "\(titleIndex)",
            outputDir.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read progress in real time
        var lineBuffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }

            lineBuffer += chunk
            // Process complete lines
            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                Task { @MainActor [weak self] in
                    self?.parseProgressLine(line)
                }
            }
        }

        process.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ripProcess = nil
                self.isRipping = false
                pipe.fileHandleForReading.readabilityHandler = nil

                if p.terminationStatus == 0 {
                    self.isComplete = true
                    self.progress = 1.0
                    self.statusMessage = "Done!"
                } else if p.terminationStatus != 15 {
                    self.errorMessage = "Rip failed (exit code \(p.terminationStatus))"
                }
            }
        }

        try? process.run()
    }

    /// Rip multiple titles sequentially. Creates a disc-name subfolder when more than one title.
    func ripMultiple(titleIndices: [Int], outputDir: URL) {
        guard isMakeMKVInstalled else {
            errorMessage = "MakeMKV is not installed."
            return
        }
        guard !titleIndices.isEmpty else { return }

        // If multiple titles, create a subfolder named after the disc
        let actualDir: URL
        if titleIndices.count > 1 {
            let folderName = discName.isEmpty ? "DVD" : discName
            actualDir = outputDir.appendingPathComponent(folderName)
            try? FileManager.default.createDirectory(at: actualDir, withIntermediateDirectories: true)
        } else {
            actualDir = outputDir
        }

        totalRipCount = titleIndices.count
        currentRipIndex = 0

        Task {
            for index in titleIndices {
                guard ripProcess == nil || ripProcess?.isRunning == false else { break }
                currentRipIndex += 1
                if totalRipCount > 1 {
                    statusMessage = "Ripping title \(currentRipIndex)/\(totalRipCount)…"
                }
                await ripAndWait(titleIndex: index, outputDir: actualDir)
                // Check if cancelled
                if !isRipping && !isComplete { break }
            }
        }
    }

    private func ripAndWait(titleIndex: Int, outputDir: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            isRipping = true
            isComplete = false
            progress = 0
            progressMax = 1
            errorMessage = nil

            let titleLabel = totalRipCount > 1 ? "Title \(currentRipIndex)/\(totalRipCount)" : "Starting…"
            statusMessage = titleLabel

            let process = Process()
            ripProcess = process
            process.executableURL = URL(fileURLWithPath: makemkvconPath)
            process.arguments = [
                "--robot",
                "--progress=-same",
                "--minlength=0",
                "mkv",
                "disc:0",
                "\(titleIndex)",
                outputDir.path
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var lineBuffer = ""
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }

                lineBuffer += chunk
                while let newlineRange = lineBuffer.range(of: "\n") {
                    let line = String(lineBuffer[..<newlineRange.lowerBound])
                    lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                    Task { @MainActor [weak self] in
                        self?.parseProgressLine(line)
                    }
                }
            }

            process.terminationHandler = { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.ripProcess = nil
                    pipe.fileHandleForReading.readabilityHandler = nil

                    if p.terminationStatus == 0 {
                        self.isComplete = true
                        self.progress = 1.0
                        if self.currentRipIndex >= self.totalRipCount {
                            self.statusMessage = "Done!"
                            self.isRipping = false
                        }
                    } else if p.terminationStatus == 15 {
                        // Cancelled
                        self.isRipping = false
                    } else {
                        self.errorMessage = "Rip failed (exit code \(p.terminationStatus))"
                        self.isRipping = false
                    }
                    continuation.resume()
                }
            }

            try? process.run()
        }
    }

    private func parseProgressLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // PRGV:current,total,max — progress values
        if trimmed.hasPrefix("PRGV:") {
            let parts = trimmed.dropFirst("PRGV:".count).components(separatedBy: ",")
            if parts.count >= 3,
               let current = Double(parts[0]),
               let max = Double(parts[2]),
               max > 0 {
                progress = current / max
            }
        }

        // PRGC:code,id,"message" — current operation
        if trimmed.hasPrefix("PRGC:") {
            if let msg = extractQuotedValue(trimmed) {
                statusMessage = msg
            }
        }

        // PRGT:code,id,"message" — overall task
        if trimmed.hasPrefix("PRGT:") {
            if let msg = extractQuotedValue(trimmed) {
                statusMessage = msg
            }
        }

        // MSG with "successfully completed"
        if trimmed.contains("successfully completed") {
            statusMessage = "Done!"
        }
    }

    // MARK: - Cancel

    func cancel() {
        ripProcess?.terminate()
        ripProcess = nil
        isRipping = false
        statusMessage = "Cancelled"
    }

    // MARK: - Helpers

    private func extractQuotedValue(_ line: String) -> String? {
        // Extract the LAST quoted string from a line like: TINFO:0,9,0,"1:18:58"
        guard let lastQuote = line.lastIndex(of: "\"") else { return nil }
        let beforeLast = line[..<lastQuote]
        guard let secondQuote = beforeLast.lastIndex(of: "\"") else { return nil }
        let start = beforeLast.index(after: secondQuote)
        return String(line[start..<lastQuote])
    }

    private func parseDuration(_ duration: String) -> Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}
