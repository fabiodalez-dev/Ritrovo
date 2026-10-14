// 50 test della review (ottobre 2026) e test di regressione delle correzioni
// della 0.3.0. Ogni test ha un nome. `knownIssue` marca un difetto noto non
// ancora corretto: il test fallisce e viene contato a parte; quando il difetto
// è corretto il runner segnala "UNEXPECTED PASS" e il flag va tolto.
// Avvio: swift run RitrovoCoreTests
import Foundation
import ImageIO
import RitrovoCore
import UniformTypeIdentifiers

struct Expectation: Error { let message: String; let line: Int }

func expect(_ condition: Bool, _ message: String, line: Int = #line) throws {
    if !condition { throw Expectation(message: message, line: line) }
}

enum Review {
    static var passed = 0
    static var failed = 0
    static var known = 0
    static var total = 0

    static func test(_ name: String, knownIssue: String? = nil, _ body: () throws -> Void) {
        total += 1
        var error: Error?
        do { try body() } catch let e { error = e }
        switch (error, knownIssue) {
        case (nil, nil):
            passed += 1
        case (nil, let issue?):
            failed += 1
            print("UNEXPECTED PASS \(total). \(name) — il problema noto sembra risolto, togliere knownIssue: \(issue)")
        case (let e?, nil):
            failed += 1
            print("FAIL \(total). \(name) — \(describe(e))")
        case (let e?, let issue?):
            known += 1
            print("KNOWN \(total). \(name) — \(issue) [\(describe(e))]")
        }
    }

    private static func describe(_ e: Error) -> String {
        if let x = e as? Expectation { return "riga \(x.line): \(x.message)" }
        return "\(e)"
    }

    static func tempDir(_ tag: String) -> URL {
        // Not resolved on purpose: /var is a link to /private/var, like any
        // destination reached through a symbolic link.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-rt-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    /// JPEG 40x30 con data di scatto opzionale (EXIF DateTimeOriginal).
    static func writeJPEG(_ url: URL, date: String?) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func writePNG(_ url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    static func sh(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try! p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    static func file(_ path: String, size: Int64 = 1, modified: Date = Date()) -> RecoveredFile {
        RecoveredFile(url: URL(fileURLWithPath: path), size: size, modified: modified)
    }

    static func partition(_ description: String, info: String = "", order: Int = 1, label: String = "") -> EnginePartition {
        let line = """
        {"type":"partition","order":\(order),"part_offset":512,"part_size":4096,"description":"\(description)","info":"\(info)","label":"\(label)"}
        """
        guard case .partition(let p)? = EventParser.parse(line: Substring(line)) else { fatalError("partition line") }
        return p
    }
}

/// Parole chiave della modalità batch del motore (src/phcli.c, poptions.c,
/// geometry.c, part*.c). Tutto ciò che CommandBuilder emette deve stare qui,
/// oltre a numeri ed estensioni del catalogo.
let engineKeywords: Set<String> = [
    "C", "H", "N", "S", "blocksize", "disable", "enable", "everything", "expert", "ext2_group", "ext2_inode",
    "fileopt", "freespace", "geometry", "inter", "keep_corrupted_file", "keep_corrupted_file_no", "lowmem",
    "mode_ext2", "options", "paranoid", "paranoid_bf", "paranoid_no", "search", "status=unformat", "wholespace",
    "image_min_width", "image_min_height", "image_min_pixels", "image_min_filesize",
    "partition_i386", "partition_gpt", "partition_mac", "partition_none", "partition_sun", "partition_xbox", "partition_humax",
]

func runReviewTests() -> Int {
    let fm = FileManager.default
    let smallCatalog = FormatCatalog.merge([
        FormatEntry(id: "jpg", extension: "jpg", description: "JPG picture", enabledByDefault: true),
        FormatEntry(id: "png", extension: "png", description: "PNG", enabledByDefault: true),
        FormatEntry(id: "mov", extension: "mov", description: "QuickTime", enabledByDefault: true),
        FormatEntry(id: "7z", extension: "7z", description: "7zip archive", enabledByDefault: false),
    ])
    let defaults = Set(smallCatalog.filter(\.enabledByDefault).map(\.ext))

    // MARK: - A. Catalogo dei formati

    Review.test("A1 catalogo vuoto resta vuoto") {
        try expect(FormatCatalog.merge([]).isEmpty, "merge([]) non vuoto")
    }

    Review.test("A2 ordinamento naturale delle estensioni: i numeri prima delle lettere, senza distinzione di maiuscole") {
        let exts = smallCatalog.map(\.ext)
        try expect(exts == ["7z", "jpg", "mov", "png"], "ordine: \(exts)")
    }

    Review.test("A3 descrizioni unite con “ / ” senza ripetizioni") {
        let merged = FormatCatalog.merge([
            FormatEntry(id: "a", extension: "doc", description: "Word", enabledByDefault: false),
            FormatEntry(id: "b", extension: "doc", description: "Word", enabledByDefault: false),
            FormatEntry(id: "c", extension: "doc", description: "Office 97", enabledByDefault: true),
        ])
        try expect(merged.count == 1 && merged[0].description == "Word / Office 97", "descrizione: \(merged.map(\.description))")
        try expect(merged[0].enabledByDefault, "abilitato se almeno una voce lo è")
    }

    Review.test("A5 formats.json generato dai sorgenti: oltre 300 formati, jpg attivo, nessuna estensione vuota") {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build-macos/app/formats.json")
        guard fm.fileExists(atPath: url.path) else { print("      (A5 saltato: \(url.path) assente, serve macos/build-app.sh)"); return }
        let catalog = try FormatCatalog.load(from: url)
        try expect(catalog.count > 300, "solo \(catalog.count) formati")
        try expect(catalog.allSatisfy { !$0.ext.isEmpty }, "estensione vuota")
        try expect(catalog.first { $0.ext == "jpg" }?.enabledByDefault == true, "jpg non attivo")
        try expect(Set(catalog.map(\.ext)).count == catalog.count, "estensioni duplicate dopo il merge")
    }

    Review.test("A6 catalogo non valido: load lancia un errore invece di restituire un catalogo vuoto") {
        let bad = Review.tempDir("bad").appendingPathComponent("formats.json")
        Review.write("{not json", to: bad)
        defer { try? fm.removeItem(at: bad.deletingLastPathComponent()) }
        var thrown = false
        do { _ = try FormatCatalog.load(from: bad) } catch { thrown = true }
        try expect(thrown, "nessun errore")
    }

    Review.test("A7 ricerca: la stringa vuota o di soli spazi corrisponde a tutto, una parola estranea a niente") {
        let jpg = smallCatalog.first { $0.ext == "jpg" }!
        try expect(jpg.matches("") && jpg.matches("   "), "vuoto")
        try expect(!jpg.matches("zzz"), "estranea")
        try expect(jpg.matches(" PICTURE "), "spazi attorno e maiuscole")
    }

    // MARK: - B. Categorie

    Review.test("B1 categoria per estensione: senza distinzione di maiuscole, varianti note") {
        try expect(FileCategory.of(extension: "JPEG") == .photo && FileCategory.of(extension: "HEIC") == .photo, "foto")
        try expect(FileCategory.of(extension: "M4V") == .video && FileCategory.of(extension: "FLAC") == .audio, "video/audio")
        try expect(FileCategory.of(extension: "DOCX") == .document && FileCategory.of(extension: "7Z") == .archive, "documenti/archivi")
        try expect(FileCategory.of(extension: "") == .other && FileCategory.of(extension: "jpg ") == .other, "vuota o con spazio → Altro")
    }

    Review.test("B2 estensioni comuni del catalogo classificate (non in “Altro”)") {
        let expected: [(String, FileCategory)] = [
            ("exr", .photo), ("pnm", .photo), ("qkt", .photo),
            ("dwg", .document), ("dxf", .document), ("sav", .document),
            ("vmdk", .archive), ("vdi", .archive), ("e01", .archive), ("wim", .archive),
        ]
        let wrong = expected.filter { FileCategory.of(extension: $0.0) != $0.1 }.map(\.0)
        try expect(wrong.isEmpty, "in Altro: \(wrong)")
    }

    Review.test("B3 ogni immagine decodificabile per le miniature è una foto") {
        let notPhoto = FileCategory.decodableImages.filter { FileCategory.of(extension: $0) != .photo }
        try expect(notPhoto.isEmpty, "non foto: \(notPhoto)")
    }

    Review.test("B5 RecoveredFile: estensione in minuscolo, nome e categoria coerenti") {
        let f = Review.file("/r/IMG_0001.JPG", size: 10)
        try expect(f.ext == "jpg" && f.name == "IMG_0001.JPG" && f.category == .photo, "\(f.ext) \(f.name) \(f.category)")
        try expect(Review.file("/r/noext").ext == "" && Review.file("/r/noext").category == .other, "senza estensione")
    }

    // MARK: - C. Filtri e ordinamento dei risultati

    let now = Date()
    let sample = [
        Review.file("/x/f10.jpg", size: 500, modified: now.addingTimeInterval(-30)),
        Review.file("/x/f2.jpg", size: 9000, modified: now.addingTimeInterval(-20)),
        Review.file("/x/clip.MOV", size: 100, modified: now.addingTimeInterval(-10)),
        Review.file("/x/a4.pdf", size: 2000, modified: now),
    ]

    Review.test("C1 ricerca: per estensione esatta anche in maiuscolo, spazi attorno ignorati, per frammento di nome") {
        try expect(ResultFilter.apply(sample, category: nil, query: "MOV", sort: .name).map(\.name) == ["clip.MOV"], "ext maiuscola")
        try expect(ResultFilter.apply(sample, category: nil, query: "  pdf ", sort: .name).map(\.name) == ["a4.pdf"], "spazi")
        try expect(ResultFilter.apply(sample, category: nil, query: "f", sort: .name).count == 3, "frammento di nome (f10, f2, pdf)")
    }

    Review.test("C2 «Ultimi trovati» ordina per data di modifica decrescente") {
        let names = ResultFilter.apply(sample, category: nil, query: "", sort: .newest).map(\.name)
        try expect(names == ["a4.pdf", "clip.MOV", "f2.jpg", "f10.jpg"], "ordine: \(names)")
    }

    Review.test("C3 «Più piccoli» crescente, «Più grandi» decrescente") {
        try expect(ResultFilter.apply(sample, category: nil, query: "", sort: .smallest).map(\.size) == [100, 500, 2000, 9000], "crescente")
        try expect(ResultFilter.apply(sample, category: nil, query: "", sort: .largest).map(\.size) == [9000, 2000, 500, 100], "decrescente")
    }

    Review.test("C4 «Nome» usa l'ordine naturale: f2 prima di f10") {
        let names = ResultFilter.apply(sample, category: .photo, query: "", sort: .name).map(\.name)
        try expect(names == ["f2.jpg", "f10.jpg"], "ordine: \(names)")
    }

    // MARK: - D. Partizioni viste dal motore

    Review.test("D1 disco intero: nessun file system, niente spazio libero, non FAT") {
        let p = Review.partition("     No partition             0   0  1     5  25 20      81920 [Whole disk]", order: 255, label: "Whole disk")
        try expect(p.isWholeDisk && p.fileSystem == "" && !p.supportsFreeSpace && !p.isFAT && !p.isExtFamily, "\(p)")
    }

    Review.test("D2 NTFS: il file system mostrato è NTFS, non il primo token della descrizione") {
        let p = Review.partition(" 1 * HPFS - NTFS                 0   1  1  1023 254 63   16434495", info: "NTFS, blocksize=4096")
        try expect(p.fileSystem == "NTFS", "fileSystem = “\(p.fileSystem)”")
        try expect(p.supportsFreeSpace && !p.isFAT, "spazio libero/FAT")
    }

    Review.test("D3 exFAT: spazio libero sì, unformat FAT no") {
        let p = Review.partition(" 1 P exFAT                    0   0  2     5  25 20      81919 [CARD]", info: "exFAT, blocksize=131072", label: "CARD")
        try expect(p.supportsFreeSpace, "spazio libero")
        try expect(!p.isFAT, "exFAT presa per FAT")
    }

    Review.test("D4 ext4 riconosciuto dalle informazioni, anche se la descrizione dice solo Linux") {
        let p = Review.partition(" 1 P Linux                    0   0  2     5  25 20      81919", info: "ext4 blocksize=4096 Large_file Sparse_SB")
        try expect(p.isExtFamily && p.supportsFreeSpace && !p.isFAT, "\(p.isExtFamily) \(p.supportsFreeSpace)")
    }

    // MARK: - E. Riga /cmd per il motore

    Review.test("E1 ogni parola emessa è una parola chiave del motore, un numero o un'estensione del catalogo") {
        var o = RecoveryOptions(enabledFormats: ["jpg", "7z"])
        o.filters = ImageFilters(minWidth: 1, minHeight: 2, minPixels: 3, minBytes: 4)
        o.searchSpace = .free; o.ext2Mode = true; o.validation = .bruteForce; o.keepCorrupted = true; o.lowMemory = true
        o.blockSize = 4096; o.geometry = Geometry(cylinders: 1, heads: 2, sectors: 3, sectorSize: 512)
        o.partitionTable = .humax; o.ext2Group = 7; o.unformatFAT = true; o.verboseLog = true
        let tokens = CommandBuilder.command(partitionOrder: 3, options: o, catalog: smallCatalog).split(separator: ",").map(String.init)
        let exts = Set(smallCatalog.map(\.ext))
        let unknown = tokens.filter { !engineKeywords.contains($0) && Int($0) == nil && !exts.contains($0) }
        try expect(unknown.isEmpty, "sconosciute al motore: \(unknown)")
    }

    Review.test("E2 geometria parziale: solo le parti impostate, nell'ordine C H S N") {
        var o = RecoveryOptions(enabledFormats: defaults)
        o.geometry = Geometry(cylinders: 1024)
        try expect(CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog).hasPrefix("1,geometry,C,1024,options,"), "solo C")
        o.geometry = Geometry(sectors: 63, sectorSize: 512)
        try expect(CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog).hasPrefix("1,geometry,S,63,N,512,options,"), "S poi N")
    }

    Review.test("E3 gruppo e inode ext2 insieme: vince il gruppo, l'inode non viene inviato (comportamento documentato)") {
        var o = RecoveryOptions(enabledFormats: defaults)
        o.ext2Group = 5; o.ext2Inode = 99
        let cmd = CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog)
        try expect(cmd.contains("ext2_group,5") && !cmd.contains("ext2_inode"), cmd)
        o.ext2Group = 0
        try expect(CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog).contains("ext2_inode,99"), "solo inode")
    }

    Review.test("E4 formati: nessun fileopt con i predefiniti; altrimenti disable di tutto e enable nell'ordine del catalogo") {
        var o = RecoveryOptions(enabledFormats: defaults)
        try expect(!CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog).contains("fileopt"), "fileopt con i predefiniti")
        o.enabledFormats = ["png", "7z"]
        let cmd = CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog)
        try expect(cmd.contains("fileopt,everything,disable,7z,enable,png,enable,"), cmd)
    }

    Review.test("E5 formato sconosciuto al catalogo: ignorato, non inviato al motore") {
        var o = RecoveryOptions(enabledFormats: ["jpg", "xyz"])
        let cmd = CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog)
        try expect(!cmd.contains("xyz") && cmd.contains("jpg,enable"), cmd)
        o.enabledFormats = []
        let none = CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog)
        try expect(none.contains("fileopt,everything,disable,wholespace"), "nessun formato: \(none)")
    }

    Review.test("E6 tabella delle partizioni: una parola chiave per ogni tipo, nessuna per auto, uguale nel probe e nel comando") {
        for table in PartitionTable.allCases {
            var o = RecoveryOptions(enabledFormats: defaults)
            o.partitionTable = table
            let probe = CommandBuilder.probeCommand(options: o)
            let cmd = CommandBuilder.command(partitionOrder: 1, options: o, catalog: smallCatalog)
            if table == .auto {
                try expect(probe == "" && cmd.hasPrefix("1,"), "auto: \(probe) / \(cmd)")
            } else {
                try expect(probe == table.keyword && engineKeywords.contains(probe) && cmd.hasPrefix(probe + ",1,"), "\(table): \(probe) / \(cmd)")
            }
        }
    }

    Review.test("E7 nessuno spazio, virgoletta o a capo nel comando, qualunque opzione") {
        var o = RecoveryOptions(enabledFormats: ["jpg"])
        o.filters = ImageFilters(minPixels: 12_000_000)
        o.geometry = Geometry(heads: 255)
        for v in Validation.allCases {
            o.validation = v
            let cmd = CommandBuilder.command(partitionOrder: 255, options: o, catalog: smallCatalog)
            try expect(!cmd.contains(where: { $0 == " " || $0 == "\n" || $0 == "'" || $0 == "\"" }), cmd)
            try expect(cmd.hasSuffix(",search"), "non termina con search: \(cmd)")
        }
    }

    // MARK: - F. Eventi JSON del motore

    Review.test("F1 evento partizione con campi mancanti: valori di riserva, nessun crash") {
        guard case .partition(let p)? = EventParser.parse(line: "{\"type\":\"partition\"}") else { throw Expectation(message: "non è una partizione", line: #line) }
        try expect(p.order == 0 && p.offset == 0 && p.size == 0 && p.description == "" && p.info == "" && p.label == "", "\(p)")
    }

    Review.test("F2 avanzamento: totale zero → 0, settore oltre il totale → 1 (mai oltre)") {
        guard case .progress(let a)? = EventParser.parse(line: "{\"type\":\"progress\",\"current_sector\":5,\"total_sectors\":0}") else { throw Expectation(message: "a", line: #line) }
        guard case .progress(let b)? = EventParser.parse(line: "{\"type\":\"progress\",\"current_sector\":50,\"total_sectors\":10}") else { throw Expectation(message: "b", line: #line) }
        try expect(a.fraction == 0 && b.fraction == 1, "\(a.fraction) \(b.fraction)")
    }

    Review.test("F3 righe non valide: tipo sconosciuto → other, senza tipo o JSON rotto → nil, righe vuote saltate") {
        try expect(EventParser.parse(line: "{\"type\":\"session_start\"}") == .other, "sconosciuto")
        try expect(EventParser.parse(line: "{\"pass\":1}") == nil, "senza tipo")
        try expect(EventParser.parse(line: "{oops") == nil, "rotto")
        try expect(EventParser.parse(text: "\n\n{\"type\":\"log\",\"level\":\"info\",\"message\":\"x\"}\n\n").count == 1, "righe vuote")
    }

    Review.test("F4 disk_info: readonly vero se assente, dimensione settore mai zero") {
        guard case .diskInfo(let ro, let size, let ss)? = EventParser.parse(line: "{\"type\":\"disk_info\",\"size_bytes\":1024,\"sector_size\":0}") else { throw Expectation(message: "disk_info", line: #line) }
        try expect(ro && size == 1024 && ss == 1, "\(ro) \(size) \(ss)")
        guard case .diskInfo(let ro2, _, _)? = EventParser.parse(line: "{\"type\":\"disk_info\",\"readonly\":false}") else { throw Expectation(message: "disk_info 2", line: #line) }
        try expect(!ro2, "readonly falso non letto")
    }

    Review.test("F6 avanzamento: tempi trascorso e stimato conservati, statistiche con valori non numerici scartate") {
        let line = "{\"type\":\"progress\",\"pass\":2,\"current_sector\":1,\"total_sectors\":2,\"files_found\":3,\"elapsed_time\":\"0h01m02s\",\"estimated_time\":\"1h00m00s\",\"file_stats\":{\"jpg\":4,\"png\":\"molti\"}}"
        guard case .progress(let p)? = EventParser.parse(line: Substring(line)) else { throw Expectation(message: "progress", line: #line) }
        try expect(p.pass == 2 && p.elapsed == "0h01m02s" && p.estimated == "1h00m00s", "tempi")
        try expect(p.stats == ["jpg": 4], "stats: \(p.stats)")
    }

    // MARK: - G. Lettura incrementale del registro JSON

    Review.test("G1 file assente o vuoto: nessun evento, nessun errore") {
        let dir = Review.tempDir("tail")
        defer { try? fm.removeItem(at: dir) }
        let missing = JSONLTail(url: dir.appendingPathComponent("no.jsonl"))
        try expect(missing.readNew().isEmpty, "assente")
        let empty = dir.appendingPathComponent("empty.jsonl")
        Review.write("", to: empty)
        try expect(JSONLTail(url: empty).readNew().isEmpty, "vuoto")
    }

    Review.test("G2 più righe in una scrittura, riga spezzata in tre scritture") {
        let dir = Review.tempDir("tail2")
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.jsonl")
        Review.write("{\"type\":\"log\"}\n{\"type\":\"log\"}\n{\"ty", to: url)
        let tail = JSONLTail(url: url)
        try expect(tail.readNew().count == 2, "due righe complete")
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile(); h.write(Data("pe\":\"comp".utf8)); try h.close()
        try expect(tail.readNew().isEmpty, "ancora incompleta")
        let h2 = try FileHandle(forWritingTo: url)
        h2.seekToEndOfFile(); h2.write(Data("letion\",\"total_files\":1}\n".utf8)); try h2.close()
        let events = tail.readNew()
        try expect(events.count == 1, "completata: \(events.count)")
        if case .completion(let n, _, _)? = events.first { try expect(n == 1, "totale") } else { throw Expectation(message: "non completion", line: #line) }
        try expect(tail.readNew().isEmpty, "niente di nuovo")
    }

    // MARK: - H. Scansione delle cartelle recup_dir

    Review.test("H2 ignorati: file nascosti, report.xml, sottocartelle; ordine naturale recup_dir.2 prima di recup_dir.10") {
        let dir = Review.tempDir("scan1")
        defer { try? fm.removeItem(at: dir) }
        Review.write("a", to: dir.appendingPathComponent("recup_dir.10/f10.txt"))
        Review.write("b", to: dir.appendingPathComponent("recup_dir.2/f2.txt"))
        Review.write("h", to: dir.appendingPathComponent("recup_dir.2/.hidden"))
        Review.write("r", to: dir.appendingPathComponent("recup_dir.2/report.xml"))
        try fm.createDirectory(at: dir.appendingPathComponent("recup_dir.2/sub"), withIntermediateDirectories: true)
        let names = RecoveryScanner(sessionDir: dir).scanNew().map(\.name)
        try expect(names == ["f2.txt", "f10.txt"], "trovati: \(names)")
    }

    Review.test("H3 solo le ultime due cartelle vengono rilette: un file aggiunto a una cartella chiusa non compare (limite documentato)") {
        let dir = Review.tempDir("scan2")
        defer { try? fm.removeItem(at: dir) }
        for i in 1...3 { Review.write("x", to: dir.appendingPathComponent("recup_dir.\(i)/f\(i).txt")) }
        let scanner = RecoveryScanner(sessionDir: dir)
        try expect(scanner.scanNew().count == 3, "prima lettura")
        Review.write("y", to: dir.appendingPathComponent("recup_dir.1/late.txt"))
        Review.write("z", to: dir.appendingPathComponent("recup_dir.3/new.txt"))
        let names = scanner.scanNew().map(\.name)
        try expect(names == ["new.txt"], "seconda lettura: \(names)")
    }

    Review.test("H4 allFiles: salta i file nascosti dell'app, include le sottocartelle organizzate, ordina per percorso") {
        let dir = Review.tempDir("all")
        defer { try? fm.removeItem(at: dir) }
        Review.write("s", to: dir.appendingPathComponent(".ritrovo.ses"))
        Review.write("l", to: dir.appendingPathComponent(".ritrovo-progress.jsonl"))
        Review.write("1", to: dir.appendingPathComponent("By type/Photos/jpg/b.jpg"))
        Review.write("2", to: dir.appendingPathComponent("recup_dir.1/a.txt"))
        Review.write("3", to: dir.appendingPathComponent("report-recup_dir.1.xml"))
        let all = RecoveryScanner.allFiles(in: dir).map { $0.url.path.replacingOccurrences(of: dir.path + "/", with: "") }
        try expect(all == ["By type/Photos/jpg/b.jpg", "recup_dir.1/a.txt"], "\(all)")
    }

    // MARK: - I. Strumenti sui risultati

    Review.test("I1 nome unico senza estensione e progressione oltre (2)") {
        let dir = Review.tempDir("uniq")
        defer { try? fm.removeItem(at: dir) }
        Review.write("x", to: dir.appendingPathComponent("nota"))
        try expect(Organizer.uniqueURL(dir.appendingPathComponent("nota")).lastPathComponent == "nota (2)", "senza estensione")
        Review.write("x", to: dir.appendingPathComponent("a.txt"))
        Review.write("x", to: dir.appendingPathComponent("a (2).txt"))
        try expect(Organizer.uniqueURL(dir.appendingPathComponent("a.txt")).lastPathComponent == "a (3).txt", "(3)")
        try expect(Organizer.uniqueURL(dir.appendingPathComponent("libero.txt")).lastPathComponent == "libero.txt", "libero")
    }

    Review.test("I2 organizza senza rinominare: nomi conservati, file senza estensione in “senza estensione”, report.xml spostato") {
        let dir = Review.tempDir("org1")
        defer { try? fm.removeItem(at: dir) }
        Review.writeJPEG(dir.appendingPathComponent("recup_dir.1/f1.jpg"), date: "2020:01:02 03:04:05")
        Review.write("t", to: dir.appendingPathComponent("recup_dir.1/f2"))
        Review.write("<xml/>", to: dir.appendingPathComponent("recup_dir.1/report.xml"))
        let r = try Organizer.organizeByType(sessionDir: dir, renameByDate: false)
        try expect(r.moved == 2 && r.renamedByDate == 0, "\(r)")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("By type/Photos/jpg/f1.jpg").path), "f1 non rinominato")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("By type/Other/no extension/f2").path), "senza estensione")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("report-recup_dir.1.xml").path), "report")
        try expect(!fm.fileExists(atPath: dir.appendingPathComponent("recup_dir.1").path), "cartella vuota rimossa")
    }

    Review.test("I3 organizza due volte: la seconda non sposta nulla e non fallisce") {
        let dir = Review.tempDir("org2")
        defer { try? fm.removeItem(at: dir) }
        Review.write("a", to: dir.appendingPathComponent("recup_dir.1/a.pdf"))
        _ = try Organizer.organizeByType(sessionDir: dir, renameByDate: true)
        let again = try Organizer.organizeByType(sessionDir: dir, renameByDate: true)
        try expect(again.moved == 0 && again.renamedByDate == 0, "seconda: \(again)")
        try expect(RecoveryScanner.allFiles(in: dir).count == 1, "file perso")
    }

    Review.test("I4 due foto con la stessa data di scatto: entrambe conservate con suffisso") {
        let dir = Review.tempDir("org3")
        defer { try? fm.removeItem(at: dir) }
        Review.writeJPEG(dir.appendingPathComponent("recup_dir.1/f1.jpg"), date: "2021:07:14 18:30:05")
        Review.writeJPEG(dir.appendingPathComponent("recup_dir.1/f2.jpg"), date: "2021:07:14 18:30:05")
        let r = try Organizer.organizeByType(sessionDir: dir, renameByDate: true)
        let names = (try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("By type/Photos/jpg").path)).sorted()
        try expect(r.renamedByDate == 2 && names == ["2021-07-14 18.30.05 (2).jpg", "2021-07-14 18.30.05.jpg"], "\(names)")
    }

    Review.test("I5 duplicati: tre copie → due spostate; contenuto diverso → nessuna; vuoti ignorati; seconda passata → 0") {
        let dir = Review.tempDir("dup")
        defer { try? fm.removeItem(at: dir) }
        for n in 1...3 { Review.write("identico", to: dir.appendingPathComponent("recup_dir.1/c\(n).txt")) }
        Review.write("abcdefgh", to: dir.appendingPathComponent("recup_dir.1/d1.txt"))
        Review.write("hgfedcba", to: dir.appendingPathComponent("recup_dir.1/d2.txt"))
        Review.write("", to: dir.appendingPathComponent("recup_dir.1/e1.txt"))
        Review.write("", to: dir.appendingPathComponent("recup_dir.1/e2.txt"))
        try expect(try Organizer.moveDuplicates(sessionDir: dir) == 2, "prima passata")
        let dups = (try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Duplicates").path)).sorted()
        try expect(dups == ["c2.txt", "c3.txt"], "spostati: \(dups)")
        try expect(fm.fileExists(atPath: dir.appendingPathComponent("recup_dir.1/d2.txt").path), "d2 spostato per errore")
        try expect(try Organizer.moveDuplicates(sessionDir: dir) == 0, "seconda passata")
    }

    Review.test("I6 CSV: solo intestazione se vuoto, percorsi relativi o assoluti fuori base, a capo nel nome citato") {
        let base = URL(fileURLWithPath: "/base")
        let empty = Organizer.csvReport(files: [], relativeTo: base)
        try expect(empty == "file,path,category,extension,bytes,width,height,capture_date\n", "vuoto: \(empty)")
        let rows = Organizer.csvReport(files: [Review.file("/base/recup_dir.1/a.txt", size: 3), Review.file("/altrove/b.txt", size: 4)], relativeTo: base)
        try expect(rows.contains("a.txt,recup_dir.1/a.txt,Documents,txt,3,,,") && rows.contains("b.txt,/altrove/b.txt,Documents,txt,4,,,"), rows)
        let nl = Organizer.csvReport(files: [Review.file("/base/a\nb.txt")], relativeTo: base)
        try expect(nl.contains("\"a\nb.txt\""), "a capo non citato: \(nl)")
    }

    Review.test("I7 metadati immagine: file non immagine → vuoto; PNG senza EXIF → dimensioni sì, data no") {
        let dir = Review.tempDir("meta")
        defer { try? fm.removeItem(at: dir) }
        Review.write("non è un'immagine", to: dir.appendingPathComponent("x.jpg"))
        let none = ImageMetadata.read(dir.appendingPathComponent("x.jpg"))
        try expect(none.width == nil && none.height == nil && none.captureDate == nil, "non immagine: \(none)")
        Review.writePNG(dir.appendingPathComponent("p.png"))
        let info = ImageMetadata.read(dir.appendingPathComponent("p.png"))
        try expect(info.width == 12 && info.height == 8 && info.captureDate == nil, "\(info)")
    }

    // MARK: - J. Velocità, cronologia, opzioni salvate

    Review.test("J1 velocità: campioni più vicini di 0,25 s ignorati, poi contati") {
        var m = SpeedMeter()
        let t0 = Date()
        m.add(sector: 0, sectorSize: 512, at: t0)
        m.add(sector: 1000, sectorSize: 512, at: t0.addingTimeInterval(0.1))
        try expect(m.bytesPerSecond == 0, "campione troppo vicino contato")
        m.add(sector: 2048, sectorSize: 512, at: t0.addingTimeInterval(1))
        try expect(abs(m.bytesPerSecond - 2048 * 512) < 1, "\(m.bytesPerSecond)")
    }

    Review.test("J2 velocità: media mobile con peso 0,3 sul nuovo campione, dimensione settore 4096 rispettata") {
        var m = SpeedMeter()
        let t0 = Date()
        m.add(sector: 0, sectorSize: 4096, at: t0)
        m.add(sector: 100, sectorSize: 4096, at: t0.addingTimeInterval(1))      // 409600 B/s
        m.add(sector: 300, sectorSize: 4096, at: t0.addingTimeInterval(2))      // 819200 B/s
        let expected = 0.3 * 819_200 + 0.7 * 409_600
        try expect(abs(m.bytesPerSecond - expected) < 1, "\(m.bytesPerSecond) vs \(expected)")
    }

    Review.test("J3 cronologia: massimo 30 voci, la più recente in testa, stessa cartella sostituita") {
        var list: [HistoryEntry] = []
        for i in 0..<35 {
            list = HistoryEntry.upsert(HistoryEntry(path: "/r/\(i)", sourceName: "S", date: now, totalFiles: i, completed: true), into: list)
        }
        try expect(list.count == 30 && list.first?.path == "/r/34" && list.last?.path == "/r/5", "\(list.count) \(list.first?.path ?? "") \(list.last?.path ?? "")")
        list = HistoryEntry.upsert(HistoryEntry(path: "/r/10", sourceName: "S", date: now, totalFiles: 99, completed: false), into: list)
        try expect(list.count == 30 && list.first?.path == "/r/10" && list.filter { $0.path == "/r/10" }.count == 1, "sostituzione")
    }

    Review.test("J4 opzioni: andata e ritorno Codable con ogni campo non predefinito") {
        var o = RecoveryOptions(enabledFormats: ["jpg"])
        o.filters = ImageFilters(minWidth: 1, minHeight: 2, minPixels: 3, minBytes: 4)
        o.searchSpace = .free; o.ext2Mode = true; o.validation = .off; o.keepCorrupted = true; o.lowMemory = true
        o.blockSize = 8192; o.geometry = Geometry(cylinders: 5, heads: 6, sectors: 7, sectorSize: 8)
        o.partitionTable = .sun; o.ext2Group = 9; o.ext2Inode = 10; o.unformatFAT = true; o.verboseLog = true
        let back = try JSONDecoder().decode(RecoveryOptions.self, from: try JSONEncoder().encode(o))
        try expect(back == o, "differenze dopo il giro")
    }

    Review.test("J5 opzioni salvate da una versione precedente (chiave mancante) si leggono con il valore predefinito") {
        let o = RecoveryOptions(enabledFormats: ["jpg"])
        var dict = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(o)) as! [String: Any]
        dict.removeValue(forKey: "verboseLog")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSONDecoder().decode(RecoveryOptions.self, from: data)
        try expect(back.verboseLog == false && back.enabledFormats == ["jpg"], "valori")
    }

    // MARK: - K. Privilegi e shell

    Review.test("K1 dispositivo grezzo: accettati disk0, rdisk12s3; rifiutati forme incomplete, a capo, barra finale, relativi, maiuscole") {
        for ok in ["/dev/disk0", "/dev/rdisk12s3", "/dev/disk3s1"] { try expect(PrivilegePolicy.mayRunAsRoot(ok), "rifiutato \(ok)") }
        for bad in ["/dev/disk", "/dev/rdisk1s", "/dev/rdisk1\n", "/dev/rdisk1/", "dev/rdisk1", "/DEV/RDISK1", "/dev/disk3s1s1", " /dev/disk1"] {
            try expect(!PrivilegePolicy.mayRunAsRoot(bad), "accettato \(bad.debugDescription)")
        }
    }

    Review.test("K2 quote: stringa vuota → '', a capo e caratteri speciali conservati, AppleScript con a capo") {
        try expect(Shell.quote("") == "''", "vuota")
        try expect(Shell.quote("a\nb") == "'a\nb'", "a capo")
        try expect(Shell.quote("$HOME `x` \\") == "'$HOME `x` \\'", "speciali")
        try expect(Shell.appleScriptString("a\nb") == "\"a\nb\"", "applescript")
    }

    Review.test("K3 quote verificato con /bin/sh: la stringa torna identica, anche con apici, spazi e $") {
        for s in ["semplice", "con spazio", "l'apice", "$(id) `id` $HOME", "fine con \\", "doppio \"apice\"", "Ritrovo disco (ripresa) 2026-10-13T23.59.00"] {
            let (code, out) = Review.sh(["/bin/sh", "-c", "printf '%s' " + Shell.quote(s)])
            try expect(code == 0 && out == s, "\(s.debugDescription) → \(out.debugDescription)")
        }
    }


    // MARK: - M. Regressione: correzioni della 0.3.0

    Review.test("M1 sessione: dispositivo con spazi letto per intero fino alla parola chiave della tabella") {
        let line = "/Users/f/Ritrovo/Immagine Card 2026-10-14T01.02.03/disco.img partition_none,255,blocksize,512,fileopt,everything,enable,search,inter"
        try expect(SessionFile.device(inLine: line) == "/Users/f/Ritrovo/Immagine Card 2026-10-14T01.02.03/disco.img", "\(String(describing: SessionFile.device(inLine: line)))")
        try expect(SessionFile.device(inLine: "/dev/rdisk4 partition_i386,1,fileopt,search,inter") == "/dev/rdisk4", "disco fisico")
    }

    Review.test("M2 sessione: “inter” tolto, dispositivo sostituito dal collegamento, settori conservati") {
        let text = "#1760400000\n/a b/disco.img partition_none,255,fileopt,search,inter\n0-99\n"
        guard let r = SessionFile.prepare(text, alias: { _ in "/tmp/ctl/sorgente" }) else { throw Expectation(message: "nil", line: #line) }
        try expect(r.device == "/a b/disco.img", "device \(r.device)")
        try expect(r.text == "#1760400000\n/tmp/ctl/sorgente partition_none,255,fileopt,search\n0-99\n", r.text.debugDescription)
        guard let plain = SessionFile.prepare(text) else { throw Expectation(message: "nil 2", line: #line) }
        try expect(plain.text.contains("\n/a b/disco.img partition_none,255,fileopt,search\n"), "senza alias")
    }

    Review.test("M3 sessione non valida: testo vuoto, senza intestazione o senza settori → nil") {
        try expect(SessionFile.prepare("") == nil, "vuoto")
        try expect(SessionFile.prepare("/dev/rdisk1 partition_i386,1,search\n0-1\n") == nil, "senza #")
        try expect(SessionFile.prepare("#1\n/dev/rdisk1 partition_i386,1,search") == nil, "senza settori")
    }

    Review.test("M4 galleria: ⇧ seleziona dall'ancora, in entrambe le direzioni; ⌘ aggiunge e toglie") {
        let urls = (0..<6).map { URL(fileURLWithPath: "/g/\($0).jpg") }
        var sel = GallerySelection.click(urls[1], in: urls, selection: [], anchor: nil, command: false, shift: false)
        try expect(sel == [urls[1]], "click semplice")
        sel = GallerySelection.click(urls[4], in: urls, selection: sel, anchor: urls[1], command: false, shift: true)
        try expect(sel == Set(urls[1...4]), "⇧ in avanti: \(sel.count)")
        sel = GallerySelection.click(urls[0], in: urls, selection: sel, anchor: urls[1], command: false, shift: true)
        try expect(sel == Set(urls[0...1]), "⇧ all'indietro dalla stessa ancora: \(sel.count)")
        sel = GallerySelection.click(urls[5], in: urls, selection: sel, anchor: urls[1], command: true, shift: false)
        sel = GallerySelection.click(urls[0], in: urls, selection: sel, anchor: urls[5], command: true, shift: false)
        try expect(sel == [urls[1], urls[5]], "⌘")
    }

    Review.test("M5 allFiles: un collegamento simbolico verso un file esterno non è un file recuperato") {
        let dir = Review.tempDir("link")
        let outside = Review.tempDir("outside")
        defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: outside) }
        Review.write("segreto", to: outside.appendingPathComponent("s.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("recup_dir.1"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("recup_dir.1/l.txt"), withDestinationURL: outside.appendingPathComponent("s.txt"))
        Review.write("vero", to: dir.appendingPathComponent("recup_dir.1/v.txt"))
        try expect(RecoveryScanner.allFiles(in: dir).map(\.name) == ["v.txt"], "\(RecoveryScanner.allFiles(in: dir).map(\.name))")
    }

    Review.test("M6 nome del file system: dal campo info per FAT, ext4, HFS+; FATX non è una FAT da ricostruire") {
        try expect(Review.partition(" 1 P FAT32 LBA 0 0 1", info: "FAT32, blocksize=4096").fileSystem == "FAT32", "FAT32")
        try expect(Review.partition(" 1 P Linux 0 0 1", info: "ext4 blocksize=4096").fileSystem == "ext4", "ext4")
        try expect(Review.partition(" 1 P Mac HFS 0 0 1", info: "HFS+ blocksize=4096").fileSystem == "HFS+", "HFS+")
        try expect(!Review.partition(" 1 P XBox FATX 0 0 1", info: "FATX").isFAT, "FATX")
    }

    Review.test("M7 CSV su una destinazione raggiunta da un collegamento: percorsi relativi, non assoluti") {
        let dir = Review.tempDir("csvlink")
        defer { try? fm.removeItem(at: dir) }
        Review.write("a", to: dir.appendingPathComponent("recup_dir.1/a.txt"))
        let csv = Organizer.csvReport(files: RecoveryScanner.allFiles(in: dir), relativeTo: dir)
        try expect(csv.contains("a.txt,recup_dir.1/a.txt,"), csv)
    }

    print("\nReview: \(Review.total) test — \(Review.passed) superati, \(Review.failed) falliti, \(Review.known) problemi noti")
    return Review.failed
}
