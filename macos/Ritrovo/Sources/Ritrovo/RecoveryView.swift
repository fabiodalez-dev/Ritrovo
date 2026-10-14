import AppKit
import SwiftUI
import RitrovoCore

struct RecoveryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RecoverySession
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            status
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)
            Hairline()
            ResultsGallery(files: session.files)
        }
        .navigationTitle(session.sourceName)
        .toolbar {
            ToolbarItem {
                Button { showingLog.toggle() } label: { Label("Log", systemImage: "list.bullet.rectangle") }
                    .help("Messages from the recovery engine")
                    .popover(isPresented: $showingLog, arrowEdge: .bottom) { LogView(lines: session.logLines) }
            }
        }
    }

    private var running: Bool { session.isActive }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                if let passText { Text(passText).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
                Spacer()
                actions
            }
            if running {
                ProgressTrack(fraction: session.progress?.fraction ?? 0, indeterminate: session.progress == nil)
            }
            Text(facts)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            if session.readErrors > 0 {
                Notice(kind: .warning, text: Count.readErrors(session.readErrors),
                       detail: loc("The disk has unreadable sectors. Better to stop, copy it into an image and recover from the copy: this way the disk is read only once."))
            }
            if case .failed(let message) = session.state {
                Notice(kind: .danger, text: loc("The recovery stopped"), detail: message)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.sessionDir]) }
            if session.state == .stopping, let since = session.stopRequestedAt {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    if context.date.timeIntervalSince(since) > 20 {
                        Button("The disk is not answering: go back") {
                            session.abandon()
                            model.closeSession()
                        }
                    }
                }
            }
            if running {
                Button(session.state == .stopping ? loc("Stopping…") : loc("Stop")) { session.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(session.state == .stopping)
            } else {
                Button("New recovery") { model.closeSession() }
                Button("Open the results") {
                    let path = session.sessionDir.path
                    model.closeSession()
                    model.select(.history(path))
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var title: String {
        switch session.state {
        case .running: return loc("Recovery in progress")
        case .stopping: return loc("Stopping")
        case .finished: return session.stoppedByUser ? loc("Recovery stopped") : loc("Recovery completed")
        case .failed: return loc("Recovery stopped")
        }
    }

    private var passText: String? {
        guard running, let p = session.progress else { return nil }
        return loc("pass \(String(p.pass + 1))")
    }

    private var facts: String {
        var parts: [String] = []
        if running, let p = session.progress {
            parts.append(String(Int(p.fraction * 100)) + "%")
            if session.partitionSize > 0 {
                let done = UInt64(Double(session.partitionSize) * p.fraction)
                parts.append(loc("\(Format.bytes(done)) of \(Format.bytes(session.partitionSize))"))
            }
        }
        parts.append(Count.filesFound(session.totalFiles))
        if running {
            let speed = Format.speed(session.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            if let t = Format.engineDuration(session.progress?.estimated), t > 0 { parts.append(loc("about \(Format.duration(t)) left")) }
        } else if let t = Format.engineDuration(session.progress?.elapsed) {
            parts.append(loc("took \(Format.duration(t))"))
        }
        if !running && session.stoppedByUser { parts.append(loc("can be resumed from the sidebar")) }
        if running && session.progress == nil { return loc("Starting the recovery…") }
        return parts.joined(separator: "  ·  ")
    }
}

struct LogView: View {
    let lines: [RecoverySession.LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log").font(.system(size: 13, weight: .semibold)).padding(12)
            Hairline()
            if lines.isEmpty {
                Text("No messages.").font(.system(size: 12)).foregroundStyle(Theme.ink2).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(color(line.level)).frame(width: 5, height: 5)
                                    Text(line.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 540, height: 340)
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "critical", "error": return Theme.bad
        case "warning": return Theme.warn
        default: return Theme.ink3
        }
    }
}

/// A recovery from the list: browse and tidy the results, or resume it.
struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    let entry: HistoryEntry
    @State private var files: [RecoveredFile] = []
    @State private var loading = true
    @State private var working: String?
    @State private var message: String?
    @State private var organizing = false
    @State private var renameByDate = true

    private var dir: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.sourceName).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(verbatim: [entry.completed ? loc("Completed on \(entry.date.formatted(date: .long, time: .shortened))")
                                                       : loc("Stopped on \(entry.date.formatted(date: .long, time: .shortened))"),
                                       Count.files(files.count), Format.bytes(files.reduce(0) { $0 + $1.size })].joined(separator: "  ·  "))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    if model.canResume(entry) {
                        Button("Resume recovery") { model.resume(entry) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.isBusy)
                    }
                }
                HStack(spacing: 8) {
                    Button("Organize by type…") { organizing = true }
                    Button("Set duplicates aside") {
                        run(loc("Looking for duplicates…")) {
                            let n = try Organizer.moveDuplicates(sessionDir: dir)
                            return n == 0 ? loc("No duplicates.") : Count.duplicatesMoved(n)
                        }
                    }
                    Button("Export CSV list…") { exportCSV() }
                    Spacer()
                    if let working {
                        ProgressView().controlSize(.small)
                        Text(working).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    } else if let message {
                        Label(message, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok)
                    }
                }
                .disabled(working != nil || files.isEmpty)
                if organizing {
                    Panel(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Files are moved into folders by type, such as “By type/Photos/jpg”, inside the recovery folder. No file is deleted.")
                                .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                            Toggle("Rename photos after their capture date (2021-07-14 18.30.05.jpg)", isOn: $renameByDate)
                                .toggleStyle(.checkbox)
                            HStack {
                                Spacer()
                                Button("Cancel") { organizing = false }
                                Button("Organize") {
                                    organizing = false
                                    let rename = renameByDate
                                    run(loc("Organizing…")) {
                                        let r = try Organizer.organizeByType(sessionDir: dir, renameByDate: rename)
                                        return Count.filesOrganized(r.moved) + (r.renamedByDate > 0 ? ", " + Count.photosRenamed(r.renamedByDate) : "") + "."
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Hairline()
            if loading {
                ProgressTrack(fraction: 0, indeterminate: true).frame(width: 200).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultsGallery(files: files, emptyText: loc("The folder holds no recovered files."))
            }
        }
        .navigationTitle(entry.sourceName)
        .task { await reload() }
    }

    private func reload() async {
        let dir = self.dir
        let found = await Task.detached { RecoveryScanner.allFiles(in: dir) }.value
        files = found
        loading = false
    }

    private func run(_ label: String, _ work: @escaping @Sendable () throws -> String) {
        working = label
        message = nil
        Task {
            let result = await Task.detached { () -> String in
                do { return try work() } catch { return loc("Error: \(error.localizedDescription)") }
            }.value
            working = nil
            message = result
            await reload()
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ritrovo \(entry.sourceName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = dir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let files = self.files, dir = self.dir
        run(loc("Creating the list…")) {
            try Organizer.csvReport(files: files, relativeTo: dir).write(to: url, atomically: true, encoding: .utf8)
            return loc("List saved: \(url.lastPathComponent)")
        }
    }
}

/// Copy of a whole disk into disco.img.
struct CloneView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var clone: CloneSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            ProgressTrack(fraction: clone.state == .finished ? 1 : clone.fraction)
            Text(facts).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink2)
            if case .failed(let message) = clone.state { Notice(kind: .danger, text: loc("Copy stopped"), detail: message) }
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clone.workDir]) }
                Spacer()
                switch clone.state {
                case .running, .stopping:
                    Button(clone.state == .stopping ? loc("Stopping…") : loc("Stop")) { clone.stop() }
                        .disabled(clone.state == .stopping)
                case .finished:
                    Button("Close") { model.closeClone(openImage: false) }
                    Button("Recover from the image") { model.closeClone(openImage: true) }
                        .buttonStyle(PrimaryButtonStyle())
                case .failed:
                    Button("Close") { model.closeClone(openImage: false) }
                }
            }
            .padding(.top, 6)
        }
        .padding(48)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(loc("Copy of \(clone.sourceName)"))
    }

    private var title: String {
        switch clone.state {
        case .running: return loc("Copying the disk")
        case .stopping: return loc("Stopping")
        case .finished: return loc("Image ready")
        case .failed: return loc("Copy stopped")
        }
    }

    private var detail: String {
        switch clone.state {
        case .running, .stopping:
            return loc("\(clone.sourceName) is read only once. Unreadable blocks are filled with zeros, so everything else stays in place.")
        case .finished:
            return loc("You can now recover from the image without touching the disk again.")
        case .failed:
            return loc("The image holds the part of the disk already read.")
        }
    }

    private var facts: String {
        var parts = [String(Int((clone.state == .finished ? 1 : clone.fraction) * 100)) + "%",
                     loc("\(Format.bytes(clone.copiedBytes)) of \(Format.bytes(clone.totalBytes))")]
        if clone.state == .running {
            let speed = Format.speed(clone.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            if clone.bytesPerSecond > 0 {
                parts.append(loc("about \(Format.duration(Double(clone.totalBytes - clone.copiedBytes) / clone.bytesPerSecond)) left"))
            }
        }
        return parts.joined(separator: "  ·  ")
    }
}
