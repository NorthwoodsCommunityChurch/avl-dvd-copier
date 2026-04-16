import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var coordinator = DiscCoordinator()

    @AppStorage("outputFolderBookmark") private var outputFolderBookmark: Data = Data()
    @AppStorage("autoRip") private var autoRip: Bool = false
    @State private var outputFolder: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            switch coordinator.discType {
            case .none:
                if coordinator.isComplete {
                    completionView
                } else {
                    noDiscView
                }
            case .dvd:
                dvdBody
            case .dvdFallback:
                dvdFallbackBody
            case .audioCD:
                audioCDBody
            case .dataCD:
                dataCDBody
            }
        }
        .frame(width: 540)
        .onAppear {
            restoreOutputFolder()
            coordinator.outputFolder = outputFolder
            coordinator.autoRip = autoRip
            coordinator.start()
        }
        .onChange(of: outputFolder) { folder in
            coordinator.outputFolder = folder
        }
        .onChange(of: autoRip) { value in
            coordinator.autoRip = value
        }
        // DVD: auto-select titles after scan
        .onChange(of: coordinator.ripper.titles) { titles in
            coordinator.handleTitlesChanged(titles)
        }
        // Audio CD: auto-select tracks after scan
        .onChange(of: coordinator.audioCDRipper.tracks) { tracks in
            coordinator.handleTracksChanged(tracks)
        }
        // DVD fallback: auto-select and auto-rip after scan
        .onChange(of: coordinator.fallbackRipper.titleSets) { sets in
            coordinator.handleFallbackTitleSetsChanged(sets)
        }
        // Data CD: auto-copy after scan
        .onChange(of: coordinator.dataCDCopier.fileCount) { count in
            coordinator.handleFileCountChanged(count)
        }
        .alert("Error", isPresented: .constant(coordinator.activeError != nil)) {
            Button("OK") { coordinator.clearErrors() }
        } message: {
            Text(coordinator.activeError ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 30))
                .foregroundStyle(coordinator.discDetected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                if coordinator.discDetected {
                    Text(coordinator.currentDiscName)
                        .font(.headline)
                    Text(coordinator.currentStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Disc Copier")
                        .font(.headline)
                    Text(coordinator.currentStatusMessage.isEmpty ? "Insert a disc to get started" : coordinator.currentStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if coordinator.isScanning {
                ProgressView()
                    .scaleEffect(0.75)
                    .padding(.trailing, 4)
            }

            if !coordinator.isBusy {
                Button {
                    coordinator.rescan()
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

    // MARK: - DVD Body (existing flow)

    @ViewBuilder
    private var dvdBody: some View {
        if coordinator.ripper.isComplete && !coordinator.ripper.discDetected {
            completionView
        } else if coordinator.ripper.discDetected && !coordinator.ripper.titles.isEmpty {
            dvdTitlesSection
            Divider()
            dvdOutputSection
        } else if coordinator.ripper.discDetected && coordinator.ripper.titles.isEmpty && !coordinator.ripper.isScanning {
            discUnreadableView
        } else if coordinator.ripper.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    // MARK: - Audio CD Body

    @ViewBuilder
    private var audioCDBody: some View {
        if coordinator.audioCDRipper.isComplete {
            completionView
        } else if !coordinator.audioCDRipper.tracks.isEmpty {
            audioTracksSection
            Divider()
            audioOutputSection
        } else if coordinator.audioCDRipper.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    // MARK: - DVD Fallback Body (ffmpeg)

    @ViewBuilder
    private var dvdFallbackBody: some View {
        if coordinator.fallbackRipper.isComplete {
            completionView
        } else if !coordinator.fallbackRipper.titleSets.isEmpty {
            fallbackTitlesSection
            Divider()
            fallbackOutputSection
        } else if coordinator.fallbackRipper.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    private var fallbackTitlesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Title Sets")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List(selection: $coordinator.selectedFallbackIDs) {
                ForEach(coordinator.fallbackRipper.titleSets) { ts in
                    HStack {
                        Text("Title \(ts.id)")
                            .font(.body)
                        Spacer()
                        Text(ts.sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(ts.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 80, maxHeight: 200)
        }
    }

    private var fallbackOutputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            folderPickerRow
            autoRipToggle

            // Progress
            if coordinator.fallbackRipper.isRipping {
                VStack(spacing: 6) {
                    ProgressView(value: coordinator.fallbackRipper.progress)
                    Text(coordinator.fallbackRipper.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons
            HStack {
                if coordinator.fallbackRipper.isRipping {
                    Spacer()
                    Button("Cancel") { coordinator.fallbackRipper.cancel() }
                        .buttonStyle(.bordered)
                } else if coordinator.fallbackRipper.isComplete {
                    Spacer()
                    Button("Show in Finder") { coordinator.revealOutput() }
                        .buttonStyle(.bordered)
                } else {
                    Spacer()
                    let count = coordinator.selectedFallbackIDs.count
                    Button("Rip \(count) Title\(count == 1 ? "" : "s") to Video") { coordinator.startFallbackRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.canRipFallback)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data CD Body

    @ViewBuilder
    private var dataCDBody: some View {
        if coordinator.dataCDCopier.isComplete {
            completionView
        } else if coordinator.dataCDCopier.fileCount > 0 {
            dataCDInfoSection
            Divider()
            dataOutputSection
        } else if coordinator.dataCDCopier.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    // MARK: - Shared Views

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

    private var completionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text(coordinator.discType == .dataCD ? "Copy Complete" : "Rip Complete")
                .font(.title3)
            Text(coordinator.currentStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Show in Finder") { coordinator.revealOutput() }
                    .buttonStyle(.bordered)
                Button("Done") { coordinator.resetCompletion() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    private var discUnreadableView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Can't Read Disc")
                .font(.title3)
            Text(coordinator.ripper.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Eject Disc") { coordinator.ejectDisc() }
                    .buttonStyle(.bordered)
                if coordinator.findDVDVolume() != nil {
                    Button("Copy Files Instead") { coordinator.fallbackToCopy() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    private var noDiscView: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 60))
                .foregroundStyle(.quaternary)
            Text("No disc detected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Insert a disc — it will be detected automatically")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Toggle("Auto-rip on insert", isOn: $autoRip)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if autoRip && outputFolder == nil {
                    Text("Choose an output folder first")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if autoRip && outputFolder != nil {
                    Text("Ready — insert a disc and walk away")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.top, 8)

            if outputFolder == nil {
                Button("Choose Output Folder…") { pickFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(outputFolder!.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        pickFolder()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - DVD Titles List

    private var dvdTitlesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TITLES")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if coordinator.ripper.titles.isEmpty {
                Text("No titles found on disc")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(coordinator.ripper.titles) { title in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { coordinator.selectedTitleIDs.contains(title.id) },
                                    set: { isOn in
                                        if isOn {
                                            coordinator.selectedTitleIDs.insert(title.id)
                                        } else {
                                            coordinator.selectedTitleIDs.remove(title.id)
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
                                        if title.id == coordinator.ripper.titles.first?.id {
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

                            if title.id != coordinator.ripper.titles.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - DVD Output + Actions

    private var dvdOutputSection: some View {
        VStack(spacing: 12) {
            folderPickerRow
            autoRipToggle

            if coordinator.ripper.isRipping || coordinator.ripper.isComplete {
                progressSection(progress: coordinator.ripper.progress, status: coordinator.ripper.statusMessage, complete: coordinator.ripper.isComplete)
            }

            HStack {
                if coordinator.ripper.isRipping {
                    Spacer()
                    Button("Cancel") { coordinator.ripper.cancel() }
                        .buttonStyle(.bordered)
                } else if coordinator.ripper.isComplete {
                    Button("Show in Finder") { coordinator.revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { coordinator.ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    let count = coordinator.selectedTitleIDs.count
                    Button("Rip \(count) Title\(count == 1 ? "" : "s") to MKV") { coordinator.startDVDRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.canRipDVD)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
    }

    // MARK: - Audio CD Tracks List

    private var audioTracksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRACKS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(coordinator.audioCDRipper.tracks) { track in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { coordinator.selectedTrackIDs.contains(track.id) },
                                set: { isOn in
                                    if isOn {
                                        coordinator.selectedTrackIDs.insert(track.id)
                                    } else {
                                        coordinator.selectedTrackIDs.remove(track.id)
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Track \(track.id)")
                                    .fontWeight(.medium)
                                HStack(spacing: 8) {
                                    Text(track.duration)
                                    Text("\u{00B7}")
                                    Text(track.sizeLabel)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        if track.id != coordinator.audioCDRipper.tracks.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: - Audio CD Output + Actions

    private var audioOutputSection: some View {
        VStack(spacing: 12) {
            folderPickerRow
            autoRipToggle

            if coordinator.audioCDRipper.isRipping || coordinator.audioCDRipper.isComplete {
                progressSection(progress: coordinator.audioCDRipper.progress, status: coordinator.audioCDRipper.statusMessage, complete: coordinator.audioCDRipper.isComplete)
            }

            HStack {
                if coordinator.audioCDRipper.isRipping {
                    Spacer()
                    Button("Cancel") { coordinator.audioCDRipper.cancel() }
                        .buttonStyle(.bordered)
                } else if coordinator.audioCDRipper.isComplete {
                    Button("Show in Finder") { coordinator.revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { coordinator.ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    let count = coordinator.selectedTrackIDs.count
                    Button("Rip \(count) Track\(count == 1 ? "" : "s") to WAV") { coordinator.startAudioRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.canRipAudio)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
    }

    // MARK: - Data CD Info

    private var dataCDInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONTENTS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(coordinator.dataCDCopier.fileCount) file\(coordinator.dataCDCopier.fileCount == 1 ? "" : "s")")
                        .fontWeight(.medium)
                    Text(coordinator.dataCDCopier.totalSizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Data CD Output + Actions

    private var dataOutputSection: some View {
        VStack(spacing: 12) {
            folderPickerRow
            autoRipToggle

            if coordinator.dataCDCopier.isCopying || coordinator.dataCDCopier.isComplete {
                progressSection(progress: coordinator.dataCDCopier.progress, status: coordinator.dataCDCopier.statusMessage, complete: coordinator.dataCDCopier.isComplete)
            }

            HStack {
                if coordinator.dataCDCopier.isCopying {
                    Spacer()
                    Button("Cancel") { coordinator.dataCDCopier.cancel() }
                        .buttonStyle(.bordered)
                } else if coordinator.dataCDCopier.isComplete {
                    Button("Show in Finder") { coordinator.revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { coordinator.ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button("Copy Files") { coordinator.startDataCopy() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.canCopyData)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
    }

    // MARK: - Shared Output Components

    private var folderPickerRow: some View {
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
    }

    private var autoRipToggle: some View {
        HStack {
            Toggle("Auto-rip on insert", isOn: $autoRip)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func progressSection(progress: Double, status: String, complete: Bool) -> some View {
        VStack(spacing: 5) {
            ProgressView(value: progress)
                .padding(.horizontal, 16)
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if complete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose where to save files"
        if let folder = outputFolder {
            panel.directoryURL = folder
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            saveOutputFolder(url)
        }
    }

    // MARK: - Folder Persistence

    private func saveOutputFolder(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            outputFolderBookmark = bookmark
        }
    }

    private func restoreOutputFolder() {
        // Migrate bookmark from old "DVD Copier" bundle ID if needed
        if outputFolderBookmark.isEmpty {
            if let oldDefaults = UserDefaults(suiteName: "com.northwoodschurch.dvdcopier"),
               let oldBookmark = oldDefaults.data(forKey: "outputFolderBookmark") {
                outputFolderBookmark = oldBookmark
            }
        }

        guard !outputFolderBookmark.isEmpty else { return }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: outputFolderBookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            outputFolder = url
            // Refresh stale bookmark
            if isStale {
                saveOutputFolder(url)
            }
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
