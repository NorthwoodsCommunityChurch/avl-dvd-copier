import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var ripper = DVDRipper()
    @StateObject private var audioCDRipper = AudioCDRipper()
    @StateObject private var dataCDCopier = DataCDCopier()

    @State private var discType: DiscType = .none
    @State private var selectedTitleIDs: Set<Int> = []
    @State private var selectedTrackIDs: Set<Int> = []
    @AppStorage("outputFolderBookmark") private var outputFolderBookmark: Data = Data()
    @AppStorage("autoRip") private var autoRip: Bool = false
    @State private var outputFolder: URL? = nil
    @State private var isEjecting = false

    @StateObject private var discWatcher = DiscWatcher()

    private var canRipDVD: Bool {
        !selectedTitleIDs.isEmpty && outputFolder != nil
            && !ripper.isScanning && !ripper.isRipping
    }

    private var canRipAudio: Bool {
        !selectedTrackIDs.isEmpty && outputFolder != nil
            && !audioCDRipper.isScanning && !audioCDRipper.isRipping
    }

    private var canCopyData: Bool {
        dataCDCopier.fileCount > 0 && outputFolder != nil
            && !dataCDCopier.isScanning && !dataCDCopier.isCopying
    }

    /// True when any handler is actively working
    private var isBusy: Bool {
        ripper.isScanning || ripper.isRipping
            || audioCDRipper.isScanning || audioCDRipper.isRipping
            || dataCDCopier.isScanning || dataCDCopier.isCopying
    }

    /// True when any handler reports completion
    private var isComplete: Bool {
        ripper.isComplete || audioCDRipper.isComplete || dataCDCopier.isComplete
    }

    /// True when a disc of any type is detected and ready
    private var discDetected: Bool {
        switch discType {
        case .dvd: return ripper.discDetected
        case .audioCD: return !audioCDRipper.tracks.isEmpty
        case .dataCD: return dataCDCopier.fileCount > 0
        case .none: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            switch discType {
            case .none:
                if isComplete {
                    completionView
                } else {
                    noDiscView
                }
            case .dvd:
                dvdBody
            case .audioCD:
                audioCDBody
            case .dataCD:
                dataCDBody
            }
        }
        .frame(width: 540)
        .onAppear {
            restoreOutputFolder()
            setupDiscWatcher()
            setupCompletionHandlers()
        }
        // DVD: auto-select titles after scan
        .onChange(of: ripper.titles) { titles in
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
        // Audio CD: auto-select tracks after scan
        .onChange(of: audioCDRipper.tracks) { tracks in
            selectedTrackIDs = Set(tracks.map(\.id))
            if autoRip && !tracks.isEmpty && outputFolder != nil && !audioCDRipper.isRipping {
                startAudioRip()
            }
        }
        // Data CD: auto-copy after scan
        .onChange(of: dataCDCopier.fileCount) { count in
            if autoRip && count > 0 && outputFolder != nil && !dataCDCopier.isCopying {
                startDataCopy()
            }
        }
        .alert("Error", isPresented: .constant(activeError != nil)) {
            Button("OK") { clearErrors() }
        } message: {
            Text(activeError ?? "")
        }
    }

    private var activeError: String? {
        ripper.errorMessage ?? audioCDRipper.errorMessage ?? dataCDCopier.errorMessage
    }

    private func clearErrors() {
        ripper.errorMessage = nil
        audioCDRipper.errorMessage = nil
        dataCDCopier.errorMessage = nil
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 30))
                .foregroundStyle(discDetected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                if discDetected {
                    Text(currentDiscName)
                        .font(.headline)
                    Text(currentStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Disc Copier")
                        .font(.headline)
                    Text(currentStatusMessage.isEmpty ? "Insert a disc to get started" : currentStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if ripper.isScanning || audioCDRipper.isScanning || dataCDCopier.isScanning {
                ProgressView()
                    .scaleEffect(0.75)
                    .padding(.trailing, 4)
            }

            if !isBusy {
                Button {
                    rescan()
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

    private var currentDiscName: String {
        switch discType {
        case .dvd: return ripper.discName.isEmpty ? "DVD" : ripper.discName
        case .audioCD: return audioCDRipper.discName.isEmpty ? "Audio CD" : audioCDRipper.discName
        case .dataCD: return dataCDCopier.discName.isEmpty ? "Data CD" : dataCDCopier.discName
        case .none: return ""
        }
    }

    private var currentStatusMessage: String {
        switch discType {
        case .dvd: return ripper.statusMessage
        case .audioCD: return audioCDRipper.statusMessage
        case .dataCD: return dataCDCopier.statusMessage
        case .none:
            if isComplete {
                return ripper.statusMessage.isEmpty
                    ? (audioCDRipper.statusMessage.isEmpty ? dataCDCopier.statusMessage : audioCDRipper.statusMessage)
                    : ripper.statusMessage
            }
            return ""
        }
    }

    // MARK: - DVD Body (existing flow)

    @ViewBuilder
    private var dvdBody: some View {
        if ripper.isComplete && !ripper.discDetected {
            completionView
        } else if ripper.discDetected && !ripper.titles.isEmpty {
            dvdTitlesSection
            Divider()
            dvdOutputSection
        } else if ripper.discDetected && ripper.titles.isEmpty && !ripper.isScanning {
            discUnreadableView
        } else if ripper.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    // MARK: - Audio CD Body

    @ViewBuilder
    private var audioCDBody: some View {
        if audioCDRipper.isComplete {
            completionView
        } else if !audioCDRipper.tracks.isEmpty {
            audioTracksSection
            Divider()
            audioOutputSection
        } else if audioCDRipper.isScanning {
            scanningView
        } else {
            noDiscView
        }
    }

    // MARK: - Data CD Body

    @ViewBuilder
    private var dataCDBody: some View {
        if dataCDCopier.isComplete {
            completionView
        } else if dataCDCopier.fileCount > 0 {
            dataCDInfoSection
            Divider()
            dataOutputSection
        } else if dataCDCopier.isScanning {
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
            Text(discType == .dataCD ? "Copy Complete" : "Rip Complete")
                .font(.title3)
            Text(currentStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Show in Finder") { revealOutput() }
                    .buttonStyle(.bordered)
                Button("Done") { resetCompletion() }
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
            Text(ripper.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Eject Disc") { ejectDisc() }
                .buttonStyle(.bordered)
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

    // MARK: - DVD Output + Actions

    private var dvdOutputSection: some View {
        VStack(spacing: 12) {
            folderPickerRow
            autoRipToggle

            if ripper.isRipping || ripper.isComplete {
                progressSection(progress: ripper.progress, status: ripper.statusMessage, complete: ripper.isComplete)
            }

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
                    Button("Rip \(count) Title\(count == 1 ? "" : "s") to MKV") { startDVDRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRipDVD)
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
                    ForEach(audioCDRipper.tracks) { track in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { selectedTrackIDs.contains(track.id) },
                                set: { isOn in
                                    if isOn {
                                        selectedTrackIDs.insert(track.id)
                                    } else {
                                        selectedTrackIDs.remove(track.id)
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

                        if track.id != audioCDRipper.tracks.last?.id {
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

            if audioCDRipper.isRipping || audioCDRipper.isComplete {
                progressSection(progress: audioCDRipper.progress, status: audioCDRipper.statusMessage, complete: audioCDRipper.isComplete)
            }

            HStack {
                if audioCDRipper.isRipping {
                    Spacer()
                    Button("Cancel") { audioCDRipper.cancel() }
                        .buttonStyle(.bordered)
                } else if audioCDRipper.isComplete {
                    Button("Show in Finder") { revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    let count = selectedTrackIDs.count
                    Button("Rip \(count) Track\(count == 1 ? "" : "s") to WAV") { startAudioRip() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRipAudio)
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
                    Text("\(dataCDCopier.fileCount) file\(dataCDCopier.fileCount == 1 ? "" : "s")")
                        .fontWeight(.medium)
                    Text(dataCDCopier.totalSizeLabel)
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

            if dataCDCopier.isCopying || dataCDCopier.isComplete {
                progressSection(progress: dataCDCopier.progress, status: dataCDCopier.statusMessage, complete: dataCDCopier.isComplete)
            }

            HStack {
                if dataCDCopier.isCopying {
                    Spacer()
                    Button("Cancel") { dataCDCopier.cancel() }
                        .buttonStyle(.bordered)
                } else if dataCDCopier.isComplete {
                    Button("Show in Finder") { revealOutput() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done — Eject Disc") { ejectDisc() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button("Copy Files") { startDataCopy() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCopyData)
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

    // MARK: - Disc Watcher Setup

    private func setupDiscWatcher() {
        discWatcher.onDiscInserted = { [self] mediaKind, volumePath in
            Task { @MainActor in
                guard !isEjecting else { return }

                // Fully reset all handlers for the new disc
                resetAll()

                if mediaKind.contains("DVD") {
                    discType = .dvd
                    ripper.discConfirmedByDA = true
                    ripper.statusMessage = "Disc detected, reading…"
                    ripper.discDetected = false
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !ripper.isRipping, !ripper.isScanning, !isEjecting else { return }
                    ripper.scan()
                } else if mediaKind.contains("CD") {
                    // Wait for the volume to mount
                    let mountPath = await waitForMount(volumePath: volumePath)
                    guard !isEjecting else { return }

                    if let mountPath {
                        if isAudioCD(at: mountPath) {
                            discType = .audioCD
                            audioCDRipper.scan(volumePath: mountPath)
                        } else {
                            discType = .dataCD
                            dataCDCopier.scan(volumePath: mountPath)
                        }
                    } else {
                        discType = .none
                    }
                }
            }
        }
        discWatcher.onDiscEjected = { [self] in
            Task { @MainActor in
                guard !isEjecting else { return }
                let wasComplete = isComplete
                ripper.discConfirmedByDA = false
                ripper.resetDisc()
                audioCDRipper.reset()
                dataCDCopier.reset()
                if !wasComplete {
                    discType = .none
                }
            }
        }
        discWatcher.start()
    }

    private func setupCompletionHandlers() {
        ripper.onRipComplete = { [self] in ejectAfterRip() }
        audioCDRipper.onRipComplete = { [self] in ejectAfterRip() }
        dataCDCopier.onCopyComplete = { [self] in ejectAfterRip() }
    }

    /// Wait for the CD volume to appear at the given path (or discover it in /Volumes).
    private func waitForMount(volumePath: URL?) async -> URL? {
        let fm = FileManager.default

        // If DA gave us a path and it exists, use it
        if let volumePath, fm.fileExists(atPath: volumePath.path) {
            return volumePath
        }

        // Snapshot current volumes so we can detect new ones
        let volumesBefore = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])

        // Poll for up to 10 seconds
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Check if DA-provided path appeared
            if let volumePath, fm.fileExists(atPath: volumePath.path) {
                return volumePath
            }

            // Discover any new volume that appeared since we started waiting
            let volumesNow = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            let newVolumes = volumesNow.subtracting(volumesBefore)
            if let newVolume = newVolumes.first {
                return URL(fileURLWithPath: "/Volumes/\(newVolume)")
            }
        }
        return volumePath
    }

    /// Check if a mounted volume is an audio CD (contains only .aiff files).
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

    private func startDVDRip() {
        guard !selectedTitleIDs.isEmpty, let folder = outputFolder else { return }
        let sortedIndices = selectedTitleIDs.sorted()
        ripper.ripMultiple(titleIndices: sortedIndices, outputDir: folder)
    }

    private func startAudioRip() {
        guard !selectedTrackIDs.isEmpty, let folder = outputFolder else { return }
        audioCDRipper.rip(trackIDs: selectedTrackIDs.sorted(), outputDir: folder)
    }

    private func startDataCopy() {
        guard let folder = outputFolder else { return }
        dataCDCopier.copy(outputDir: folder)
    }

    private func rescan() {
        switch discType {
        case .dvd: ripper.scan()
        case .audioCD:
            if let vol = audioCDRipper.tracks.isEmpty ? nil : URL(fileURLWithPath: "/Volumes/\(audioCDRipper.discName)") {
                audioCDRipper.scan(volumePath: vol)
            }
        case .dataCD:
            if let vol = dataCDCopier.discName.isEmpty ? nil : URL(fileURLWithPath: "/Volumes/\(dataCDCopier.discName)") {
                dataCDCopier.scan(volumePath: vol)
            }
        case .none: break
        }
    }

    private func revealOutput() {
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

    private func ejectDisc() {
        _ = Process.run("/usr/bin/drutil", args: ["eject"])
        ripper.resetDisc()
        audioCDRipper.reset()
        dataCDCopier.reset()
        discType = .none
    }

    private func ejectAfterRip() {
        isEjecting = true
        ripper.isEjecting = true

        let discLabel: String
        switch discType {
        case .dvd: discLabel = "DVD"
        case .audioCD: discLabel = "CD"
        case .dataCD: discLabel = "CD"
        case .none: discLabel = "disc"
        }

        // Set status on the active handler
        switch discType {
        case .dvd: ripper.statusMessage = "Rip complete — ejecting disc…"
        case .audioCD: audioCDRipper.statusMessage = "Rip complete — ejecting disc…"
        case .dataCD: dataCDCopier.statusMessage = "Copy complete — ejecting disc…"
        case .none: break
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            _ = Process.run("/usr/bin/drutil", args: ["eject"])

            switch self.discType {
            case .dvd: self.ripper.statusMessage = "Rip complete — disc ejected. Insert another \(discLabel)."
            case .audioCD: self.audioCDRipper.statusMessage = "Rip complete — disc ejected. Insert another disc."
            case .dataCD: self.dataCDCopier.statusMessage = "Copy complete — disc ejected. Insert another disc."
            case .none: break
            }

            self.discType = .none

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.isEjecting = false
                self.ripper.isEjecting = false
            }
        }
    }

    /// Reset just the completion flags (for "Done" button).
    private func resetCompletion() {
        ripper.isComplete = false
        ripper.progress = 0
        ripper.statusMessage = ""
        audioCDRipper.isComplete = false
        audioCDRipper.progress = 0
        audioCDRipper.statusMessage = ""
        dataCDCopier.isComplete = false
        dataCDCopier.progress = 0
        dataCDCopier.statusMessage = ""
    }

    /// Full reset for all handlers when a new disc is inserted.
    private func resetAll() {
        ripper.resetDisc()
        ripper.isComplete = false
        ripper.progress = 0
        audioCDRipper.reset()
        audioCDRipper.isComplete = false
        audioCDRipper.progress = 0
        dataCDCopier.reset()
        dataCDCopier.isComplete = false
        dataCDCopier.progress = 0
        selectedTitleIDs = []
        selectedTrackIDs = []
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
