import AppKit
import SwiftUI
import RitrovoCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    let source: RecoverySource
    @State private var showAdvanced = SelfTest.outDir != nil
    @State private var customBlock = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                section(loc("Partition"), trailing: partitionTrailing) { partitionContent }
                if model.selectedPartition != nil {
                    section(loc("What to recover"), trailing: loc("\(Format.number(model.options.enabledFormats.count)) of \(Format.number(model.catalog.count)) formats")) { categories }
                    section(loc("Where to search")) { searchSpace }
                    section(loc("Image filter")) { filters }
                    section(loc("Destination")) { destination }
                    advanced.id("advanced")
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ritrovoShowAdvanced)) { _ in
            showAdvanced = true
            proxy.scrollTo("advanced", anchor: .top)
        }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $model.showingFormats) {
            FormatsSheet(enabled: $model.options.enabledFormats, catalog: model.catalog)
        }
        .onAppear {
            if case .idle = model.probe, !source.needsAdmin { model.runProbe() }
            customBlock = model.options.blockSize > 0 && !Self.blockSizes.contains(model.options.blockSize)
        }
        .navigationTitle(source.name)
    }

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title, trailing: trailing)
            content()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: source.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.ink2)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(source.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(verbatim: "\(Format.bytes(source.size)) · \(kindText) · \(source.target)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Read only: the source is never modified", systemImage: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ok)
            }
            Spacer()
            if canClone {
                Button("Copy into an image…") { model.startClone() }
                    .help("Reads the disk only once and saves it to an .img file to recover from. Recommended for slow or damaged disks.")
                    .disabled(model.isBusy)
            }
        }
    }

    private var canClone: Bool {
        if case .disk = source.kind { return true }
        return ProcessInfo.processInfo.environment["RITROVO_ALLOW_IMAGE_CLONE"] == "1"
    }

    private var kindText: String {
        switch source.kind {
        case .disk(let isInternal): return isInternal ? loc("internal disk") : loc("external disk")
        case .image: return loc("disk image")
        }
    }

    // MARK: Partition

    private var partitionTrailing: String? {
        if case .loaded(let parts) = model.probe { return Count.items(parts.count) }
        return nil
    }

    @ViewBuilder private var partitionContent: some View {
        switch model.probe {
        case .idle where source.needsAdmin:
            Panel(padding: 16) {
                HStack(spacing: 14) {
                    Text("To read a physical disk macOS asks for the administrator password. Access stays read only.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Read the partitions") { model.runProbe() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        case .idle:
            ProgressTrack(fraction: 0, indeterminate: true).frame(maxWidth: 240)
        case .loading(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                let clock = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ProgressTrack(fraction: 0, indeterminate: true).frame(width: 160)
                        Text("Reading the partition table  \(clock)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Button("Cancel") { model.cancelProbe() }
                    }
                    if seconds >= 20 {
                        Notice(kind: .warning, text: loc("The disk is answering slowly"),
                               detail: loc("This happens with damaged disks or disks already being read by another program. It may take a few minutes."))
                    }
                }
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Notice(kind: .danger, text: loc("Could not read the partitions"), detail: message)
                Button("Try again") { model.runProbe() }
            }
        case .loaded(let parts):
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        if index > 0 { Hairline() }
                        ChoiceRow(title: partitionTitle(part), subtitle: partitionSubtitle(part),
                                  symbol: part.isWholeDisk ? "internaldrive" : "square.split.2x1",
                                  selected: model.partitionOrder == part.order) {
                            model.partitionOrder = part.order
                            model.applyPartitionDefaults()
                        } trailing: {
                            Text(Format.bytes(part.size))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
        }
    }

    private func partitionTitle(_ part: EnginePartition) -> String {
        if part.isWholeDisk { return loc("Whole disk") }
        let name = part.label.isEmpty ? loc("Partition \(String(part.order))") : part.label
        return part.fileSystem.isEmpty ? name : "\(name)  ·  \(part.fileSystem)"
    }

    private func partitionSubtitle(_ part: EnginePartition) -> String {
        if part.isWholeDisk { return loc("Ignores the partitions: useful if the table is damaged or after a reformat.") }
        return part.info.isEmpty ? loc("Partition \(String(part.order))") : part.info
    }

    // MARK: What

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(FileCategory.allCases) { cat in
                    CategoryToggle(category: cat, state: model.state(of: cat), formats: model.formats(in: cat).count) {
                        model.toggle(cat)
                    }
                }
            }
            Button { model.showingFormats = true } label: {
                Text("Choose individual formats…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    // MARK: Where

    private var searchSpace: some View {
        let freeOK = model.selectedPartition?.supportsFreeSpace ?? false
        return Panel {
            VStack(spacing: 0) {
                ChoiceRow(title: loc("Whole space"), subtitle: loc("Analyzes every sector. Needed after a format or with a damaged file system."),
                          selected: model.options.searchSpace == .whole) { model.options.searchSpace = .whole }
                Hairline()
                ChoiceRow(title: loc("Free space only"),
                          subtitle: freeOK ? loc("Only the blocks not used by the file system: faster, finds deleted files.")
                                           : loc("Available on recognized FAT, exFAT, NTFS and ext2/3/4 partitions."),
                          selected: model.options.searchSpace == .free, enabled: freeOK) { model.options.searchSpace = .free }
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(FilterPreset.allCases.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 { Hairline() }
                        ChoiceRow(title: preset.title, subtitle: preset.detail, selected: model.filterPreset == preset) {
                            model.filterPreset = preset
                        }
                    }
                }
            }
            if model.filterPreset == .custom {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        NumberField(title: loc("Minimum width"), unit: "px", value: binding(\.filters.minWidth))
                        NumberField(title: loc("Minimum height"), unit: "px", value: binding(\.filters.minHeight))
                    }
                    GridRow {
                        NumberField(title: loc("Minimum megapixels"), unit: "MP", value: megapixelBinding, fractional: true)
                        NumberField(title: loc("Minimum size"), unit: "KB", value: kilobyteBinding)
                    }
                }
                .padding(.leading, 2)
            }
            Text("Dimensions read from JPG, PNG, GIF, BMP, ICO, WebP, PSD and PCX; for RAW and TIFF the file size applies. An image with unreadable dimensions is always recovered.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Destination

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Panel(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(Theme.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.destination?.lastPathComponent ?? loc("No folder")).font(.system(size: 13, weight: .medium))
                        Text(model.destination?.path ?? "").font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let free = model.destinationFree {
                        Text("\(Format.bytes(free)) free")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(model.destinationTooFull ? Theme.bad : Theme.ink2)
                    }
                    Button("Change…", action: model.chooseDestination)
                }
            }
            if model.destinationOnSource {
                Notice(kind: .danger, text: loc("The folder is on the disk being recovered"),
                       detail: loc("The saved files would overwrite the ones to recover. Choose a folder on another disk."))
            } else if model.destinationTooFull {
                Notice(kind: .danger, text: loc("Less than 1 GB free"), detail: loc("The destination would fill up in a few minutes."))
            }
        }
    }

    // MARK: Advanced: every other engine option

    static let blockSizes: [UInt32] = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 22) {
                option(loc("File check")) {
                    Picker("", selection: $model.options.validation) {
                        Text("Normal").tag(Validation.standard)
                        Text("Off").tag(Validation.off)
                        Text("Deep").tag(Validation.bruteForce)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 330)
                } hint: {
                    switch model.options.validation {
                    case .standard: return loc("Checks every file and discards the invalid ones.")
                    case .off: return loc("Keeps everything it finds, incomplete files too. Faster, more files to browse.")
                    case .bruteForce: return loc("Also tries to rebuild fragmented JPEGs. Much slower.")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep corrupted files", isOn: $model.options.keepCorrupted)
                    Toggle("Low memory mode, for very large or fragmented disks", isOn: $model.options.lowMemory)
                    Toggle("Detailed log", isOn: $model.options.verboseLog)
                }
                .toggleStyle(.checkbox)

                option(loc("Linux file system")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("ext2, ext3 or ext4 partition", isOn: $model.options.ext2Mode).toggleStyle(.checkbox)
                        if model.options.ext2Mode {
                            HStack(spacing: 20) {
                                NumberField(title: loc("Start from group"), unit: "", value: binding(\.ext2Group))
                                NumberField(title: loc("or from inode"), unit: "", value: binding(\.ext2Inode))
                            }
                        }
                    }
                } hint: { loc("Starting group or inode: 0 analyzes everything.") }

                option(loc("Formatted FAT partition")) {
                    Toggle("Rebuild the formatted FAT first", isOn: $model.options.unformatFAT)
                        .toggleStyle(.checkbox)
                        .disabled(!(model.selectedPartition?.isFAT ?? false))
                } hint: { loc("After a quick format it also finds names and folders. FAT partitions only.") }

                option(loc("Block size")) {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(
                            get: { customBlock ? UInt32.max : model.options.blockSize },
                            set: { v in
                                customBlock = (v == .max)
                                if v != .max { model.options.blockSize = v }
                            })) {
                            Text("Automatic").tag(UInt32(0))
                            ForEach(Self.blockSizes, id: \.self) { Text(Format.bytes(Int64($0))).tag($0) }
                            Text("Custom").tag(UInt32.max)
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        if customBlock { NumberField(title: loc("Bytes"), unit: "", value: binding(\.blockSize)) }
                    }
                } hint: { loc("Automatic is usually right. Set it only if you know the file system cluster size.") }

                option(loc("Partition table")) {
                    Picker("", selection: Binding(get: { model.options.partitionTable }, set: { model.setPartitionTable($0) })) {
                        Text("Detected automatically").tag(PartitionTable.auto)
                        Divider()
                        Text(verbatim: "Intel / MBR").tag(PartitionTable.intel)
                        Text(verbatim: "EFI GPT").tag(PartitionTable.gpt)
                        Text(verbatim: "Apple").tag(PartitionTable.mac)
                        Text("None").tag(PartitionTable.none)
                        Text(verbatim: "Sun").tag(PartitionTable.sun)
                        Text(verbatim: "Xbox").tag(PartitionTable.xbox)
                        Text(verbatim: "Humax").tag(PartitionTable.humax)
                    }
                    .labelsHidden()
                    .frame(width: 230)
                } hint: { loc("Changing it reads the partition list again.") }

                option(loc("Disk geometry")) {
                    HStack(spacing: 16) {
                        NumberField(title: loc("Cylinders"), unit: "", value: binding(\.geometry.cylinders), labelWidth: 60)
                        NumberField(title: loc("Heads"), unit: "", value: binding(\.geometry.heads), labelWidth: 56)
                        NumberField(title: loc("Sectors"), unit: "", value: binding(\.geometry.sectors), labelWidth: 50)
                        NumberField(title: loc("Bytes/sector"), unit: "", value: binding(\.geometry.sectorSize), labelWidth: 80)
                    }
                } hint: { loc("Only for very old disks or images without information. 0 keeps the detected value.") }
            }
            .padding(.top, 14)
        } label: {
            SectionLabel(text: loc("Advanced options"))
        }
    }

    private func option<C: View>(_ title: String, @ViewBuilder control: () -> C, hint: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            control()
            Text(hint()).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Spacer()
            Button(action: model.startRecovery) {
                Text("Start recovery")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canStart)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Hairline() }
    }

    private var summary: String {
        guard let part = model.selectedPartition else { return loc("Choose a partition to continue.") }
        let name = part.isWholeDisk ? loc("Whole disk") : (part.label.isEmpty ? loc("Partition \(String(part.order))") : part.label)
        let states = FileCategory.allCases.map { ($0, model.state(of: $0)) }
        let what: String
        if model.options.enabledFormats.count == model.catalog.count {
            what = loc("all formats")
        } else if states.allSatisfy({ $0.1 == .none }) {
            what = loc("no formats")
        } else {
            what = states.filter { $0.1 != .none }.map { $0.0.title.lowercased() + ($0.1 == .some ? " " + loc("(partly)") : "") }.joined(separator: ", ")
        }
        return "\(name) · \(what) · \(model.filterPreset.title.lowercased())"
    }

    // MARK: Bindings

    private func binding<T: BinaryInteger>(_ path: WritableKeyPath<RecoveryOptions, T>) -> Binding<Double> {
        Binding(get: { Double(model.options[keyPath: path]) },
                set: { model.options[keyPath: path] = T(clamping: Int64(max(0, min($0, 9_000_000_000_000)))) })
    }
    private var megapixelBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minPixels) / 1_000_000 },
                set: { model.options.filters.minPixels = UInt64(max(0, $0 * 1_000_000).rounded()) })
    }
    private var kilobyteBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minBytes) / 1000 },
                set: { model.options.filters.minBytes = UInt64(max(0, $0 * 1000).rounded()) })
    }
}

/// Category checkbox with a mixed state.
struct CategoryToggle: View {
    let category: FileCategory
    let state: AppModel.CategoryState
    let formats: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(state == .none ? Color.clear : Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(state == .none ? Theme.ink3 : Theme.accent, lineWidth: 1.2))
                        .frame(width: 15, height: 15)
                    if state != .none {
                        Image(systemName: state == .all ? "checkmark" : "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    }
                }
                Image(systemName: category.outline).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(state == .some ? loc("some formats") : Count.formats(formats)).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(state == .none ? Theme.hairline : Theme.accent.opacity(0.55)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title + ", " + (state == .all ? loc("all") : state == .some ? loc("some") : loc("none")))
        .animation(.easeOut(duration: 0.15), value: state == .none)
    }
}

struct NumberField: View {
    let title: String
    let unit: String
    @Binding var value: Double
    var fractional = false
    var labelWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2).frame(width: labelWidth, alignment: .leading)
            TextField(title, value: $value, format: fractional ? .number.precision(.fractionLength(0...1)) : .number.precision(.fractionLength(0)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 76)
            if !unit.isEmpty { Text(unit).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
        }
    }
}

/// Every format, grouped by category, with search.
struct FormatsSheet: View {
    @Binding var enabled: Set<String>
    let catalog: [FileFormat]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [FileFormat] { catalog.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Formats to recover").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text(verbatim: loc("\(Format.number(enabled.count)) of \(Format.number(catalog.count))")).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink2)
                }
                HStack(spacing: 10) {
                    TextField("Search by extension or description", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Menu("Quick selection") {
                        Button("Default formats") { enabled = Set(catalog.filter(\.enabledByDefault).map(\.ext)) }
                        Button("Photos only") { enabled = set(of: [.photo]) }
                        Button("Photos and videos") { enabled = set(of: [.photo, .video]) }
                        Button("Documents") { enabled = set(of: [.document]) }
                        Divider()
                        Button("All") { enabled = Set(catalog.map(\.ext)) }
                        Button("None") { enabled = [] }
                    }
                    .fixedSize()
                }
            }
            .padding(18)
            Hairline()
            List {
                ForEach(FileCategory.allCases) { cat in
                    let items = filtered.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { format in
                                Toggle(isOn: Binding(get: { enabled.contains(format.ext) },
                                                     set: { if $0 { enabled.insert(format.ext) } else { enabled.remove(format.ext) } })) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(format.ext).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .leading)
                                        Text(format.description).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        } header: {
                            HStack {
                                Label(cat.title, systemImage: cat.outline)
                                Spacer()
                                Button("All") { enabled.formUnion(items.map(\.ext)) }.buttonStyle(.link)
                                Button("None") { enabled.subtract(items.map(\.ext)) }.buttonStyle(.link)
                            }
                            .font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    Text("No format matches “\(query)”.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Hairline()
            HStack {
                Text("Files are recognized by their content: one more format does not slow the recovery down.")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
        .background(Theme.canvas)
    }

    private func set(of cats: Set<FileCategory>) -> Set<String> {
        Set(catalog.filter { cats.contains($0.category) }.map(\.ext))
    }
}

extension Notification.Name {
    /// Scrolls the settings to the advanced options (self test snapshots).
    static let ritrovoShowAdvanced = Notification.Name("ritrovoShowAdvanced")
}
