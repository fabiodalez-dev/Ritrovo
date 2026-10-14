// End-to-end self test of the real app, without clicks: started only with
// RITROVO_SELFTEST=<output folder> and RITROVO_SELFTEST_IMAGE=<disk image>.
// It drives the AppModel through every feature, checks the results, saves
// a PNG of the window at each step and writes report.txt, then quits.
import AppKit
import SwiftUI
import Foundation
import RitrovoCore

extension NSView {
    /// Largest scroll view of the window, for snapshots of long screens.
    var firstScrollView: NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, (best == nil || s.frame.height > best!.frame.height) { best = s }
            v.subviews.forEach(walk)
        }
        walk(self)
        return best
    }
}

@MainActor
enum SelfTest {
    static var outDir: URL? {
        ProcessInfo.processInfo.environment["RITROVO_SELFTEST"].map { URL(fileURLWithPath: $0) }
    }

    private static var lines: [String] = []
    private static var settingsWindow: NSWindow?
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        lines.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    private static func wait(_ seconds: Double = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await wait(0.3)
        }
        return condition()
    }

    /// PNG of every visible window (main window, sheets, popovers).
    private static func snapshot(_ name: String) async {
        await wait(0.8)
        guard let outDir else { return }
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let suffix = i == 0 ? "" : "-\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("\(name)\(suffix).png"))
        }
    }

    static func run(_ model: AppModel) async {
        guard let outDir, let imagePath = ProcessInfo.processInfo.environment["RITROVO_SELFTEST_IMAGE"] else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let work = outDir.appendingPathComponent("work")
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        NSApp.windows.first?.setContentSize(NSSize(width: 1180, height: 820))

        // 1. Start: catalog, disks, welcome screen
        check(model.catalog.count > 300, "format catalog loaded (\(model.catalog.count))")
        _ = await waitUntil(10) { !model.disks.isEmpty }
        check(!model.disks.isEmpty, "physical disk list (\(model.disks.map(\.name).joined(separator: ", ")))")
        await snapshot("01-benvenuto")

        model.options = RecoveryOptions(enabledFormats: Set(model.catalog.filter(\.enabledByDefault).map(\.ext)))

        // 2. Disk image, partitions read by the engine
        model.destination = work
        model.addImage(URL(fileURLWithPath: imagePath))
        check(model.selectedSource?.kind == .image, "image added and selected")
        _ = await waitUntil(30) { model.selectedPartition != nil }
        check(model.selectedPartition != nil, "partitions read by the engine")
        await snapshot("02-impostazioni")

        // 3. Categories, formats, filters, saved settings
        let defaults = model.options.enabledFormats
        model.toggle(.archive)
        check(model.state(of: .archive) == .none, "Archives category off")
        model.toggle(.archive)
        check(model.state(of: .archive) == .all, "Archives category back on")
        model.options.enabledFormats = defaults
        model.filterPreset = .noThumbnails
        check(model.options.filters == ImageFilters(minWidth: 300, minHeight: 300), "No thumbnails filter")
        let saved = UserDefaults.standard.data(forKey: "options").flatMap { try? JSONDecoder().decode(RecoveryOptions.self, from: $0) }
        check(saved?.filters.minWidth == 300, "settings saved for the next launch")
        check(UserDefaults.standard.string(forKey: "destination") == work.path, "destination saved")
        check(model.destinationFree ?? 0 > 0, "destination free space (\(Format.bytes(model.destinationFree ?? 0)))")
        model.showingFormats = true
        await snapshot("03-formati")
        model.showingFormats = false
        await wait()

        // 4. Recovery
        check(model.canStart, "Start button enabled")
        model.startRecovery()
        guard let session = model.session else {
            check(false, "session started")
            return finish()
        }
        await wait(1.5)
        await snapshot("04-recupero-in-corso")
        let ok = await waitUntil(120) { !session.isActive }
        check(ok, "recovery finished")
        await snapshot("05-recupero-finito")
        if case .finished = session.state { check(true, "completed state") } else { check(false, "completed state: \(session.state)") }
        let names = Set(session.files.map(\.ext))
        check(session.files.count == 10, "10 files recovered with the filter (\(session.files.count): \(session.files.map(\.name).sorted().joined(separator: " ")))")
        check(["jpg", "png", "gif", "bmp", "webp", "pdf", "mp4", "mp3"].allSatisfy(names.contains), "every category present: \(names.sorted())")
        check(!session.files.contains { $0.ext == "jpg" && $0.size < 10_000 }, "JPEG thumbnail discarded by the filter")
        check(model.history.first?.path == session.sessionDir.path && model.history.first?.completed == true, "history updated")
        check(model.history.first?.totalFiles == session.totalFiles, "history with the file count")
        let counts = ResultFilter.counts(session.files)
        check(counts[.photo] == 7 && counts[.video] == 1 && counts[.audio] == 1 && counts[.document] == 1, "counts by category \(counts.map { "\($0.key.title)=\($0.value)" }.sorted())")

        // 5. Results: duplicates, organize, CSV
        let dir = session.sessionDir
        model.closeSession()
        model.select(.history(dir.path))
        await wait(1.5)
        await snapshot("06-risultati")
        let dups = (try? Organizer.moveDuplicates(sessionDir: dir)) ?? -1
        check(dups == 1, "duplicate moved (\(dups))")
        let org = try? Organizer.organizeByType(sessionDir: dir, renameByDate: true)
        check(org?.moved == 9 && org?.renamedByDate == 2, "organized by type: \(String(describing: org))")
        let fm = FileManager.default
        check(fm.fileExists(atPath: dir.appendingPathComponent(Organizer.byTypeFolder).appendingPathComponent(FileCategory.photo.title).appendingPathComponent("jpg/2021-07-14 18.30.05.jpg").path), "photo renamed after its capture date")
        check(fm.fileExists(atPath: dir.appendingPathComponent(Organizer.byTypeFolder).appendingPathComponent(FileCategory.video.title).appendingPathComponent("mp4").path), "Videos/mp4 folder")
        let all = RecoveryScanner.allFiles(in: dir)
        let csv = Organizer.csvReport(files: all, relativeTo: dir)
        check(csv.split(separator: "\n").count == 11, "CSV report with 10 rows")
        try? csv.write(to: outDir.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
        model.select(nil)
        await wait(0.3)
        model.select(.history(dir.path))
        await snapshot("07-risultati-organizzati")

        // 6. Disk image copy (non privileged, on the image file)
        model.select(.source(model.images.first!.id))
        _ = await waitUntil(30) { model.selectedPartition != nil }
        model.startClone()
        guard let clone = model.clone else {
            check(false, "copy started")
            return finish()
        }
        await wait(1)
        await snapshot("08-copia")
        _ = await waitUntil(60) { clone.state != .running }
        check(clone.state == .finished, "copy completed")
        let same = fm.contentsEqual(atPath: imagePath, andPath: clone.imageURL.path)
        check(same, "image identical to the source, byte for byte")
        await snapshot("09-copia-finita")
        model.closeClone(openImage: true)
        check(model.selectedSource?.target == clone.imageURL.path, "the copied image opens in Ritrovo")

        // 7. Stop with session save
        let big = work.appendingPathComponent("vuoto.img")
        fm.createFile(atPath: big.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: big) { try? h.truncate(atOffset: 20_000_000_000); try? h.close() }
        model.addImage(big)
        _ = await waitUntil(30) { model.selectedPartition != nil }
        model.startRecovery()
        guard let long = model.session else {
            check(false, "second session")
            return finish()
        }
        _ = await waitUntil(15) { long.progress != nil }
        _ = await waitUntil(8) { long.bytesPerSecond > 0 }
        check(long.bytesPerSecond > 0, "read speed measured (\(Format.speed(long.bytesPerSecond)))")
        await snapshot("10-velocita")
        model.stopActive()
        check(long.state == .stopping, "Stopping state")
        let stopped = await waitUntil(40) { !long.isActive }
        check(stopped && long.stoppedByUser, "engine stopped")
        check(fm.fileExists(atPath: long.sessionDir.appendingPathComponent(".ritrovo.ses").path), "session saved (.ritrovo.ses)")
        check(model.history.first?.completed == false, "history: recovery stopped")
        await snapshot("11-interrotto")

        // 8. Resume the stopped recovery in a new folder
        let stoppedEntry = model.history.first!
        model.closeSession()
        check(model.canResume(stoppedEntry), "stopped recovery can be resumed")
        model.select(.history(stoppedEntry.path))
        await snapshot("12-riprendi")
        model.resume(stoppedEntry)
        guard let resumed = model.session else {
            check(false, "resume started")
            return finish()
        }
        _ = await waitUntil(20) { resumed.progress != nil }
        let resumedJSON = (try? String(contentsOf: resumed.jsonFile, encoding: .utf8)) ?? ""
        check(resumedJSON.contains("session_resume") && resumed.progress != nil, "the engine resumes from the saved session")
        let firstSector = resumed.progress?.currentSector ?? 0
        check(firstSector > 0, "the resume does not start from zero (sector \(firstSector))")
        let resumedDone = await waitUntil(120) { !resumed.isActive }
        check(resumedDone, "the resume reaches the end without hanging")
        if case .finished = resumed.state { check(true, "resume completed") } else { check(false, "resume completed: \(resumed.state)") }
        model.closeSession()
        try? fm.removeItem(at: big)

        // 9. Every advanced option reaches the engine
        model.addImage(URL(fileURLWithPath: imagePath))
        _ = await waitUntil(30) { model.selectedPartition != nil }
        model.filterPreset = .none
        model.options.validation = .off
        model.options.lowMemory = true
        model.options.blockSize = 4096
        model.options.keepCorrupted = true
        model.options.verboseLog = true
        model.options.geometry = Geometry(heads: 16, sectors: 32)
        NotificationCenter.default.post(name: .ritrovoShowAdvanced, object: nil)
        await wait(1)
        await snapshot("13-avanzate")
        model.startRecovery()
        if let adv = model.session {
            _ = await waitUntil(120) { !adv.isActive }
            let log = (try? String(contentsOf: adv.sessionDir.appendingPathComponent(".ritrovo.log"), encoding: .utf8)) ?? ""
            check(log.contains("Paranoid : No"), "file check off applied")
            check(log.contains("Low memory: Yes") || log.contains("Low memory : Yes"), "low memory applied")
            check(log.contains("blocksize=4096"), "block size 4096 applied")
            check(log.contains("Keep corrupted files : Yes"), "keep corrupted files applied")
            check(log.contains("New geometry"), "geometry applied")
            check(adv.files.count >= 13, "no filter and no file check: \(adv.files.count) file")
            model.closeSession()
        } else { check(false, "recovery with advanced options") }
        model.options = RecoveryOptions(enabledFormats: Set(model.catalog.filter(\.enabledByDefault).map(\.ext)))

        // 10. Partition table type and FAT unformat
        if let fatPath = ProcessInfo.processInfo.environment["RITROVO_SELFTEST_FAT"] {
            model.addImage(URL(fileURLWithPath: fatPath))
            _ = await waitUntil(30) { model.selectedPartition != nil }
            check(model.selectedPartition?.isFAT == true, "FAT partition recognized (\(model.selectedPartition?.info ?? "-"))")
            model.setPartitionTable(.none)
            _ = await waitUntil(30) { if case .loaded(let p) = model.probe { return p.count == 1 } else { return false } }
            if case .loaded(let p) = model.probe { check(p.count == 1 && p[0].isWholeDisk, "table None: whole disk only") } else { check(false, "partitions read again") }
            model.setPartitionTable(.intel)
            _ = await waitUntil(30) { model.selectedPartition?.isFAT == true }
            check(model.selectedPartition?.isFAT == true, "table Intel: FAT partition")
            model.options.unformatFAT = true
            await snapshot("14-fat")
            model.startRecovery()
            if let unf = model.session {
                let done = await waitUntil(90) { !unf.isActive }
                check(done, "unformat finished (no endless loop)")
                let names = Set(unf.files.map(\.name))
                check(names.contains("IMG_0001.JPG") && names.contains("CLIP.MP4"), "unformat: original names found \(names.sorted().prefix(6))")
                model.closeSession()
            } else { check(false, "unformat started") }
            model.options.unformatFAT = false
            model.setPartitionTable(.auto)
        }

        // 11. The engine's name never shows in the output or the bundle
        var leaked: [String] = []
        for name in (try? fm.subpathsOfDirectory(atPath: work.path)) ?? [] where name.lowercased().contains("photorec") {
            leaked.append(name)
        }
        check(leaked.isEmpty, "no file named after the engine in the output folders \(leaked.prefix(3))")
        let bundleNames = (try? fm.contentsOfDirectory(atPath: Bundle.main.bundlePath + "/Contents/MacOS")) ?? []
        check(!bundleNames.contains { $0.lowercased().contains("photorec") }, "no executable named after the engine: \(bundleNames)")

        // 11b. A tampered session pointing to a protected file is refused
        let evil = work.appendingPathComponent("sessione alterata")
        try? fm.createDirectory(at: evil, withIntermediateDirectories: true)
        try? "#1\n/etc/master.passwd partition_none,255,options,paranoid,search\n0-100\n".write(
            to: evil.appendingPathComponent(".ritrovo.ses"), atomically: true, encoding: .utf8)
        let evilEntry = HistoryEntry(path: evil.path, sourceName: "alterata", date: Date(), totalFiles: 0, completed: false)
        model.history.insert(evilEntry, at: 0)
        model.alert = nil
        model.resume(evilEntry)
        check(model.session == nil && model.alert == EngineError.notAllowed.errorDescription, "tampered session pointing to a protected file: refused")
        model.alert = nil
        model.forget(evilEntry)

        // 12. Dark appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.select(nil)
        await snapshot("15-scuro-benvenuto")
        model.addImage(URL(fileURLWithPath: imagePath))
        _ = await waitUntil(30) { model.selectedPartition != nil }
        await snapshot("16-scuro-impostazioni")
        model.select(.history(dir.path))
        await wait(1.5)
        await snapshot("17-scuro-risultati")
        NSApp.appearance = nil

        // 13. Settings: language. With RITROVO_SELFTEST_RELAUNCH=1 the language
        // is switched to Italian and the app starts again by itself.
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        func settingsOpen() -> Bool { NSApp.windows.contains { $0.isVisible && !before.contains(ObjectIdentifier($0)) } }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !(await waitUntil(3, settingsOpen)) {
            // The menu action needs a key window: show the same view directly.
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
            window.title = loc("Language")
            window.makeKeyAndOrderFront(nil)
            settingsWindow = window
        }
        check(await waitUntil(3, settingsOpen), "settings window shown")
        check(AppLanguage.atLaunch == AppLanguage.saved, "language at launch: \(AppLanguage.atLaunch.rawValue)")
        await snapshot("18-settings")
        if ProcessInfo.processInfo.environment["RITROVO_SELFTEST_RELAUNCH"] == "1" {
            AppLanguage.save(.italian)
            check(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == ["it"], "Italian saved for the next launch")
            writeReport()
            AppLanguage.relaunch()
            return
        }
        finish()
    }

    private static func writeReport() {
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if let outDir {
            try? lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static func finish() {
        writeReport()
        NSApp.terminate(nil)
    }
}
