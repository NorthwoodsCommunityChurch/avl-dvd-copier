import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var ripper = DVDRipper()

    @State private var selectedTitleIDs: Set<Int> = []
    @AppStorage("outputFolderBookmark") private var outputFolderBookmark: Data = Data()
    @State private var outputFolder: URL? = nil

    private var canRip: Bool {
        !selectedTitleIDs.isEmpty && outputFolder != nil
            && !ripper.isScanning && !ripper.isRipping
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if ripper.discDetected {
                titlesSection
                Divider()
                outputSection
            } else if ripper.isScanning {
                scanningView
            } else {
                noDVDView
            }
        }
        .frame(width: 540)
        .onAppear {
            restoreOutputFolder()
            ripper.startWatching()
            // Scan on first appear as a fallback (DA callback also fires for already-inserted discs)
            if !ripper.discDetected && !ripper.isRipping && !ripper.isComplete {
                ripper.scan()
            }
        }
        // Auto-select the largest title after scan
        .onChange(of: ripper.titles) { titles in
            if let first = titles.first {
                selectedTitleIDs = [first.id]
            } else {
                selectedTitleIDs = []
            }
        }
        .alert("Error", isPresented: .constant(ripper.errorMessage != nil)) {
            Button("OK") { ripper.errorMessage = nil }
        } message: {
            Text(ripper.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 30))
                .foregroundStyle(ripper.discDetected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                if ripper.discDetected {
                    Text(ripper.discName.isEmpty ? "DVD" : ripper.discName)
                        .font(.headline)
                    Text(ripper.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("DVD Copier")
                        .font(.headline)
                    Text(ripper.statusMessage.isEmpty ? "Insert a DVD to get started" : ripper.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if ripper.isScanning {
                ProgressView()
                    .scaleEffect(0.75)
                    .padding(.trailing, 4)
            }

            if !ripper.isScanning && !ripper.isRipping {
                Button {
                    ripper.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan disc")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Scanning / No DVD

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Scanning disc…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    private var noDVDView: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 60))
                .foregroundStyle(.quaternary)
            Text("No disc detected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Insert a DVD — it will be detected automatically")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - Titles List

    private var titlesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TITLES")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if ripper.titles.isEmpty {
                Text("No titles found on disc")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(ripper.titles) { title in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { selectedTitleIDs.contains(title.id) },
                                    set: { isOn in
                                        if isOn {
                                            selectedTitleIDs.insert(title.id)
                                        } else {
                                            selectedTitleIDs.remove(title.id)
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("Title \(title.id + 1)")
                                            .fontWeight(.medium)
                                        Text(title.outputName.replacingOccurrences(of: ".mkv", with: ""))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        if title.id == ripper.titles.first?.id {
                                            Text("LARGEST")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15))
                                                .foregroundStyle(Color.accentColor)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(title.duration)
                                        Text("\u{00B7}")
                                        Text("\(title.chapters) ch")
                                        Text("\u{00B7}")
                                        Text(title.sizeLabel)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)

                            if title.id != ripper.titles.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - Output + Actions

    private var outputSection: some View {
        VStack(spacing: 12) {
            // Folder picker row
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                if let folder = outputFolder {
                    Text(folder.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                } else {
                    Text("Choose an output folder…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { pickFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)

            // Progress bar (visible while ripping or after completion)
            if ripper.isRipping || ripper.isComplete {
                VStack(spacing: 5) {
                    ProgressView(value: ripper.progress)
                        .padding(.horizontal, 16)
                    HStack {
                        Text(ripper.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if ripper.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Action buttons
            HStack {
                if ripper.isRipping {
                    Spacer()
                    Button("Cancel") { ripper.cancel() }
                        .buttonStyle(.bordered)
                } else if ripper.isComplete {
                    Button("Show in Finder") { revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    let count = selectedTitleIDs.count
                    Button("Rip \(count) Title\(count == 1 ? "" : "s") to MKV") { startRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRip)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose where to save ripped MKV files"
        if let folder = outputFolder {
            panel.directoryURL = folder
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            saveOutputFolder(url)
        }
    }

    private func startRip() {
        guard !selectedTitleIDs.isEmpty, let folder = outputFolder else { return }
        let sortedIndices = selectedTitleIDs.sorted()
        ripper.ripMultiple(titleIndices: sortedIndices, outputDir: folder)
    }

    private func revealOutput() {
        guard let folder = outputFolder else { return }
        // If multiple titles, reveal the disc-name subfolder
        if selectedTitleIDs.count > 1 {
            let folderName = ripper.discName.isEmpty ? "DVD" : ripper.discName
            let subFolder = folder.appendingPathComponent(folderName)
            NSWorkspace.shared.selectFile(subFolder.path, inFileViewerRootedAtPath: "")
        } else if let titleID = selectedTitleIDs.first,
                  let title = ripper.titles.first(where: { $0.id == titleID }) {
            let fileURL = folder.appendingPathComponent(title.outputName)
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func ejectDisc() {
        // Eject via drutil — DA disappeared callback will also fire
        _ = Process.run("/usr/bin/drutil", args: ["eject"])
        ripper.resetDisc()
        ripper.statusMessage = "Disc ejected — insert another DVD"
    }

    // MARK: - Folder Persistence

    private func saveOutputFolder(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            outputFolderBookmark = bookmark
        }
    }

    private func restoreOutputFolder() {
        guard !outputFolderBookmark.isEmpty else { return }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: outputFolderBookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            outputFolder = url
        }
    }
}

// MARK: - Process Helper

extension Process {
    @discardableResult
    static func run(_ path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
