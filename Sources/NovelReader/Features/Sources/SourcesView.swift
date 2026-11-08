#if canImport(SwiftUI)
import SwiftUI
import NovelKit
#if canImport(UIKit)
import UIKit
#endif

struct SourcesView: View {
    @EnvironmentObject private var app: AppModel

    @State private var showImport = false
    @State private var showURLImport = false
    @State private var showCollections = false
    @State private var editingSource: BookSource?
    @State private var lastWarnings: [String] = []
    @State private var showWarnings = false
    @State private var pendingDelete: BookSource?
    /// What the reader typed into the source list's search field.
    @State private var query = ""
    /// Which half of the list to show: everything, only what is switched on,
    /// or only what is switched off.
    @State private var filter: SourceFilter = .all
    /// Groups the reader opened. Everything not in here is collapsed.
    @State private var expandedGroups: Set<String> = []
    /// Whether the collapsed groups are being recomputed after a filter change.
    @State private var groupsPrepared = false
    /// Whether drag-to-select is active.
    @State private var isBatchSelecting = false
    @State private var selection: Set<UUID> = []
    /// The action waiting behind the confirmation dialog.
    @State private var pendingBatchAction: BatchAction?
    @State private var showBatchResult = false
    @State private var batchResultText = ""

    /// What a batch confirmation will do once the reader agrees.
    private enum BatchAction {
        case disable
        case delete
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The three ways to narrow the list before searching it.
    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case disabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .enabled: return "已启用"
            case .disabled: return "已停用"
            }
        }

        func matches(_ source: BookSource) -> Bool {
            switch self {
            case .all: return true
            case .enabled: return source.enabled
            case .disabled: return !source.enabled
            }
        }
    }

    /// Pinned sources, in the order the reader put them.
    ///
    /// Kept out of the groups below: a pinned source is shown once, at the top,
    /// and not repeated in its own group, or the point of pinning — reaching it
    /// without scrolling — is lost.
    private var pinnedSources: [BookSource] {
        let byID = Dictionary(uniqueKeysWithValues: app.sources.map { ($0.id, $0) })
        return app.settings.pinnedSourceIDs.compactMap { byID[$0] }
            .filter { trimmedQuery.isEmpty || matchesQuery($0) }
            .filter { filter.matches($0) }
    }

    private func matchesQuery(_ source: BookSource) -> Bool {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        return source.name.localizedCaseInsensitiveContains(needle)
            || source.baseURL.localizedCaseInsensitiveContains(needle)
            || source.group.localizedCaseInsensitiveContains(needle)
    }

    /// Sources matching the search field and the filter, grouped the way the
    /// list shows them, with pinned sources removed.
    ///
    /// Matches the name, the host and the group: a hundred imported sources
    /// share prefixes like `🎉` and many names repeat, so the host is often the
    /// only thing that tells two entries apart, and the group is how someone
    /// who never renamed anything finds their way around.
    private var grouped: [(String, [BookSource])] {
        let pinned = Set(pinnedSources.map(\.id))
        let matching = app.sources.filter { source in
            !pinned.contains(source.id) && filter.matches(source) && matchesQuery(source)
        }
        let dictionary = Dictionary(grouping: matching) { source in
            source.group.isEmpty ? "未分组" : source.group
        }
        return dictionary
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    /// Groups with more rows than this start folded.
    ///
    /// Six rows fit on one screen; anything past that is a group the reader has
    /// to scroll through anyway, so starting it open just hides the groups
    /// below it. Smaller groups are shown in full — folding three rows away
    /// costs a tap and reveals nothing.
    private static let foldingThreshold = 6

    private func isExpanded(_ group: String) -> Bool {
        expandedGroups.contains(group)
    }

    /// Folds the big groups the first time the list is built, and again when
    /// the filter changes.
    ///
    /// A group the reader opened stays open until they switch filters; at that
    /// point the set of groups on screen is different enough that keeping old
    /// open/closed state would leave "已停用" showing four rows and a thousand
    /// closed ones.
    private func prepareGroups() {
        guard !groupsPrepared else { return }
        groupsPrepared = true
        let groups = grouped
        expandedGroups = Set(groups.filter { $0.1.count <= Self.foldingThreshold }.map(\.0))
    }

    /// Every source currently on screen, flat, for the select-all control.
    ///
    /// Includes folded and pinned sources: the list is a view of the setting,
    /// and "全选" meaning "the forty rows I can see" when a filter is on would
    /// silently skip everything the filter kept but the fold hid.
    private var visibleSources: [BookSource] {
        pinnedSources + grouped.flatMap(\.1)
    }

    private var allVisibleSelected: Bool {
        !visibleSources.isEmpty && visibleSources.allSatisfy { selection.contains($0.id) }
    }

    /// Shelf books whose source is among the selected ones.
    private var affectedBooks: [Book] {
        app.booksOnShelf(from: selection)
    }

    /// One section's rows, in the plain-row shape the selection drag measures.
    ///
    /// A `LazyVStack` of plain rows instead of `List` rows: a `List` decides
    /// for itself when a drag is a scroll and when it belongs to a row, and a
    /// sideways row gesture made it stop scrolling for a while afterwards.
    /// Plain rows have plain frames, so the selection drag can be measured
    /// against them and the list keeps scrolling.
    @ViewBuilder
    private func sourceRows(_ sources: [BookSource], pinned: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(sources) { source in
                SourceRow(
                    source: source,
                    isSelecting: isBatchSelecting,
                    isSelected: selection.contains(source.id),
                    isPinned: pinned,
                    onToggle: {
                        if isBatchSelecting {
                            toggleSelection(source)
                        } else {
                            app.toggleSourceEnabled(source)
                        }
                    },
                    onOpen: {
                        guard !isBatchSelecting else {
                            toggleSelection(source)
                            return
                        }
                        editingSource = source
                    },
                    onSelect: {
                        selection = [source.id]
                        isBatchSelecting = true
                    },
                    onMoveToggle: { toggleSelection(source) }
                )
                .modifier(
                    SourceRowChrome(
                        isBatchSelecting: isBatchSelecting,
                        isPinned: pinned,
                        onDelete: { pendingDelete = source },
                        onEdit: { editingSource = source },
                        onBatch: {
                            selection = [source.id]
                            isBatchSelecting = true
                        },
                        onTogglePin: { app.togglePin(source) },
                        onMovePinUp: { app.movePinned(source, by: -1) },
                        onMovePinDown: { app.movePinned(source, by: 1) }
                    )
                )
                if source.id != sources.last?.id {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func count(of option: SourceFilter) -> Int {
        switch option {
        case .all: return app.sources.count
        case .enabled: return app.sources.filter(\.enabled).count
        case .disabled: return app.sources.filter { !$0.enabled }.count
        }
    }

    /// A few names, for a dialog that should read as a sentence.
    private func bookSummary(_ books: [Book]) -> String {
        let names = books.prefix(3).map(\.name).joined(separator: "、")
        return books.count > 3 ? "\(names) 等 \(books.count) 本" : names
    }

    var body: some View {
        NavigationStack {
            List {
                if app.sources.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有书源").font(.headline)
                            Text("导入「阅读 / legado」书源 JSON 后即可搜索、阅读网络小说。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                if !app.sources.isEmpty && !isBatchSelecting {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("搜索书名、网址或分组", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("清除搜索")
                            }
                        }

                        Picker("筛选", selection: $filter) {
                            ForEach(SourceFilter.allCases) { option in
                                Text("\(option.title) \(count(of: option))").tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    } footer: {
                        Text("分组超过 \(Self.foldingThreshold) 个书源时默认折叠，点分组名展开或收起。长按书源可以置顶，置顶的会排在最上面。")
                    }
                }

                if !pinnedSources.isEmpty {
                    Section {
                        sourceRows(pinnedSources, pinned: true)
                    } header: {
                        Label("置顶", systemImage: "pin.fill")
                    }
                }

                ForEach(grouped, id: \.0) { group, sources in
                    Section {
                        if isExpanded(group) {
                            sourceRows(sources)
                        }
                    } header: {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                if isExpanded(group) {
                                    expandedGroups.remove(group)
                                } else {
                                    expandedGroups.insert(group)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: isExpanded(group) ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                Text(group)
                                Spacer()
                                Text("\(sources.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !app.sources.isEmpty && grouped.isEmpty && pinnedSources.isEmpty {
                    ContentUnavailableView {
                        Label(filter == .all ? "没有匹配的书源" : "这个筛选下没有书源", systemImage: "magnifyingglass")
                    } description: {
                        Text(filter == .all
                             ? "试试书源名、网址或分组名的一部分。"
                             : "切到「全部」，或先启用一些书源。")
                    }
                }

                Section {
                    Button {
                        showCollections = true
                    } label: {
                        Label("浏览在线书源合集", systemImage: "square.grid.2x2")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("粘贴书源 JSON", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showURLImport = true
                    } label: {
                        Label("从链接导入", systemImage: "link")
                    }
                    Button {
                        useClipboard()
                    } label: {
                        Label("直接读取剪贴板", systemImage: "clipboard")
                    }
                    Button {
                        _ = app.importSources(fromJSON: BuiltinContent.exampleLegadoJSON)
                        app.showBanner("已导入示例书源（默认关闭）", isError: false)
                    } label: {
                        Label("查看 / 导入示例书源", systemImage: "book.pages")
                    }
                } header: {
                    Text("导入")
                } footer: {
                    Text("支持 legado 规则子集：CSS、XPath、JSONPath、@@ 回退、## 正则替换。用到 JavaScript 的书源会标出影响范围。")
                }

                if !app.sources.isEmpty && !isBatchSelecting {
                    Section {
                        Button {
                            checkExploreHealth()
                        } label: {
                            if isCheckingHealth {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在检测发现页…")
                                }
                            } else {
                                Label("检测发现页", systemImage: "waveform.path.ecg")
                            }
                        }
                        .disabled(isCheckingHealth)
                    } footer: {
                        Text("逐个打开书源的发现页：能打开的取消选中，打不开的会被选中，之后由你决定停用还是删除。发现页打不开不代表书源不能用——搜索和阅读可能是好的，所以默认建议先停用。")
                    }
                }
            }
            .onChange(of: filter) { _, _ in
                groupsPrepared = false
            }
            .onChange(of: app.sources.count) { _, _ in
                // A new import adds groups; fold the big ones rather than
                // dropping a hundred new rows onto the reader at once.
                groupsPrepared = false
            }
            .onChange(of: grouped.count) { _, _ in
                prepareGroups()
            }
            .onAppear {
                prepareGroups()
            }
            .coordinateSpace(name: SourceRowLayout.space)
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
            .simultaneousGesture(slideSelectionGesture)
            .navigationTitle(isBatchSelecting ? (selection.isEmpty ? "选择书源" : "已选 \(selection.count) 个") : "书源")
            .toolbar {
                if isBatchSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(allVisibleSelected ? "全不选" : "全选") {
                            toggleSelectAll()
                        }
                        .disabled(visibleSources.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Two presets that match the two reasons people prune a
                        // source list, instead of another menu to open first.
                        Button {
                            selectDeadSources()
                        } label: {
                            Image(systemName: "waveform.path.badge.minus")
                        }
                        .accessibilityLabel("选中无搜索规则的书源")
                        .disabled(visibleSources.allSatisfy(\.canSearch))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            selectDisabledSources()
                        } label: {
                            Image(systemName: "pause.circle")
                        }
                        .accessibilityLabel("选中已停用的书源")
                        .disabled(visibleSources.allSatisfy(\.enabled))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            endBatchSelection()
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showImport = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            selection = []
                            isBatchSelecting = true
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("批量管理")
                        .disabled(app.sources.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isBatchSelecting {
                    batchActionBar
                }
            }
            .sheet(isPresented: $showImport) {
                ImportSourcesSheet { text in
                    let result = app.importSources(fromJSON: text)
                    report(result)
                    return result
                }
            }
            .sheet(isPresented: $showCollections) {
                SourceCollectionsView()
            }
            .sheet(isPresented: $showURLImport) {
                ImportFromURLSheet { data in
                    let result = app.importSources(from: data)
                    report(result)
                    return result
                }
            }
            .sheet(item: $editingSource) { source in
                SourceEditorView(source: source)
            }
            .alert("导入结果", isPresented: $showWarnings) {
                Button("好", role: .cancel) {}
            } message: {
                Text(lastWarnings.joined(separator: "\n"))
            }
            .confirmationDialog(
                "删除书源「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let source = pendingDelete {
                        app.deleteSource(source)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("只会删除书源配置，已加入书架的书不受影响。")
            }
            .confirmationDialog(
                pendingBatchAction == .delete
                    ? "删除 \(selection.count) 个书源？"
                    : "停用 \(selection.count) 个书源？",
                isPresented: Binding(
                    get: { pendingBatchAction != nil },
                    set: { if !$0 { pendingBatchAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if pendingBatchAction == .delete {
                    Button("删除", role: .destructive) { confirmBatch(.delete) }
                } else {
                    Button("停用") { confirmBatch(.disable) }
                }
                Button("取消", role: .cancel) { pendingBatchAction = nil }
            } message: {
                Text(batchConfirmationMessage)
            }
            .alert("批量操作完成", isPresented: $showBatchResult) {
                Button("好", role: .cancel) {}
            } message: {
                Text(batchResultText)
            }
        }
    }

    // MARK: - Slide to select

    /// Which rows this drag has already touched.
    @State private var dragVisits: Set<UUID> = []
    /// What this drag does to every row it reaches, fixed by the first one.
    @State private var dragDirection: DragDirection?
    /// Set once a drag has gone clearly sideways, so a vertical drag stays a
    /// scroll.
    @State private var dragIsHorizontal = false
    /// Where each visible row sits, reported by the rows themselves.
    @State private var rowFrames: [UUID: CGRect] = [:]

    private enum DragDirection { case select, deselect }

    /// Slides sideways across rows to select or deselect a run.
    ///
    /// One gesture for the whole list, `simultaneousGesture` so the list keeps
    /// its own scroll: a vertical drag is left completely alone, and only a
    /// sideways one is claimed. Nothing is attached per row, which is what made
    /// the list stop scrolling after a sideways swipe.
    private var slideSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isBatchSelecting else { return }
                if !dragIsHorizontal {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard dx > 12, dx > dy * 1.5 else { return }
                    dragIsHorizontal = true
                }
                if let id = rowHit(by: value.location) {
                    applyDrag(to: id)
                }
            }
            .onEnded { _ in
                dragVisits.removeAll()
                dragDirection = nil
                dragIsHorizontal = false
            }
    }

    /// Finds the row whose frame contains `point`, in the list's coordinates.
    ///
    /// Read from the rows' own reports rather than guessed from row heights,
    /// section headers and the scroll offset — none of which this screen would
    /// otherwise know.
    private func rowHit(by point: CGPoint) -> UUID? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// Touching a row once per drag sets it to the drag's direction.
    ///
    /// The first row decides: if it was unselected the rest of the drag selects,
    /// otherwise it deselects — the same rule as the photo app — so sliding over
    /// a mixed run does not flicker against whatever it happens to find.
    private func applyDrag(to id: UUID) {
        if dragDirection == nil {
            dragDirection = selection.contains(id) ? .deselect : .select
        }
        guard dragVisits.insert(id).inserted else { return }
        if dragDirection == .select {
            selection.insert(id)
        } else {
            selection.remove(id)
        }
    }

    // MARK: - Batch selection

    /// The bar that replaces the row taps while selecting.
    ///
    /// Two verbs only:停用 keeps every rule and can be undone by flipping a
    /// switch, 删除 removes the configuration. Both are blocked until something
    /// is selected, so a stray tap cannot empty the shelf's sources.
    private var batchActionBar: some View {
        VStack(spacing: 10) {
            // The same list filter, one tap away: two hundred imported sources
            // are mostly dead ones, and "only what I searched for" is the
            // fastest way to put the useful ones in one place.
            if let scoped = scopeHint {
                Text(scoped)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if !selection.isEmpty, !affectedBooks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "books.vertical")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text("书架里有 \(affectedBooks.count) 本书记得在所选书源：\(bookSummary(affectedBooks))")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Removing them from the batch is the one action that has to
                    // be one tap: hunting for them by hand across two hundred
                    // rows is exactly what the reader was trying to avoid.
                    Button {
                        deselectShelvedSources()
                    } label: {
                        Label("去掉书架书籍的来源", systemImage: "minus.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            }
            HStack(spacing: 12) {
                // 停用 first and promoted: it is reversible, and the only
                // certain thing this screen knows is that a source's discover
                // page did not answer — not that the source is broken.
                Button {
                    pendingBatchAction = .disable
                } label: {
                    Label("停用", systemImage: "pause.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)

                Button(role: .destructive) {
                    pendingBatchAction = .delete
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// "全选" acts on what is on screen, so the bar says what that is.
    ///
    /// Selecting a hundred sources and then finding out the search field had
    /// narrowed the list is the kind of surprise a label prevents.
    private var scopeHint: String? {
        guard !trimmedQuery.isEmpty else { return nil }
        return "全选只作用于当前搜索的 \(visibleSources.count) 个书源"
    }

    /// Explains what will happen, including what it means for the shelf.
    private var batchConfirmationMessage: String {
        let count = selection.count
        let books = affectedBooks
        switch pendingBatchAction {
        case .delete:
            let scope = "注意：检测只看过发现页，打不开不代表书源不能用，删除前请确认。"
            if books.isEmpty {
                return scope + "\n将移除 \(count) 个书源的配置，它们不再出现在找书和发现页。"
            }
            return scope + "\n将移除 \(count) 个书源的配置。书架上的 \(books.count) 本书（\(bookSummary(books))）会保留，但之后无法更新目录或继续下载章节。只想先关掉的话，可以选「停用」。"
        case .disable:
            if books.isEmpty {
                return "停用后不再出现在找书和发现页，规则保留，随时可以重新启用。"
            }
            return "停用后不再出现在找书和发现页。书架上的 \(books.count) 本书（\(bookSummary(books))）暂时无法刷新目录或下载新章节，重新启用即可恢复。"
        case nil:
            return ""
        }
    }

    private func toggleSelection(_ source: BookSource) {
        if selection.contains(source.id) {
            selection.remove(source.id)
        } else {
            selection.insert(source.id)
        }
    }

    private func toggleSelectAll() {
        if allVisibleSelected {
            selection.subtract(visibleSources.map(\.id))
        } else {
            selection.formUnion(visibleSources.map(\.id))
        }
    }

    /// Selects the sources that cannot search at all.
    ///
    /// Without a search rule a source can only be opened through its discover
    /// page, and most of those are dead — these are the safest ones to clear
    /// out in bulk.
    private func selectDeadSources() {
        selection.formUnion(visibleSources.filter { !$0.canSearch }.map(\.id))
    }

    /// Selects what was switched off earlier, for deleting it for good.
    private func selectDisabledSources() {
        selection.formUnion(visibleSources.filter { !$0.enabled }.map(\.id))
    }

    // MARK: - Health check

    @State private var isCheckingHealth = false

    /// Opens every source's discover page and selects the ones that answered.
    ///
    /// Only the discover page is checked — a source whose listing happens to
    /// break may still search and read perfectly — so this is offered as
    /// "检测发现页", not as a verdict on whether a source works. Nothing is
    /// deleted here: the sources that failed are selected so the reader sees
    /// the count and decides, and 停用 is the first action in the bar.
    private func checkExploreHealth() {
        guard !isCheckingHealth else { return }
        let queue = visibleSources
        guard !queue.isEmpty else { return }
        isCheckingHealth = true
        selection = []
        isBatchSelecting = true
        let client = HTTPClient(settings: app.settings.network)

        Task {
            let coordinator = ExploreProbeCoordinator()
            var ok: Set<UUID> = []
            var failed: Set<UUID> = []
            var done = 0

            await withTaskGroup(of: (BookSource, ExploreCategory?).self) { group in
                var next = 0
                func enqueue(_ source: BookSource) {
                    group.addTask {
                        let verdict = await AppModel.probeSource(
                            source,
                            categories: source.openableExploreCategories,
                            client: client,
                            coordinator: coordinator
                        )
                        return (source, verdict.working)
                    }
                }
                for _ in 0..<min(6, queue.count) {
                    enqueue(queue[next])
                    next += 1
                }
                for await (source, working) in group {
                    done += 1
                    if working != nil {
                        ok.insert(source.id)
                    } else {
                        failed.insert(source.id)
                    }
                    if next < queue.count {
                        enqueue(queue[next])
                        next += 1
                    }
                }
            }

            selection = failed
            isCheckingHealth = false
            batchResultText = "发现页检测完成：\(done) 个书源里 \(ok.count) 个能打开。"
                + (failed.isEmpty ? "" : "\n已选中 \(failed.count) 个打不开的。它们可能仍能搜索，建议先停用。")
            showBatchResult = true
        }
    }

    /// Drops the sources whose books are already on the shelf.
    ///
    /// Those are the ones worth keeping whatever their state, so a batch that
    /// started from "everything failed" can be reduced to "everything failed
    /// that I am not reading".
    private func deselectShelvedSources() {
        let kept = Set(affectedBooks.map(\.sourceID))
        selection.subtract(kept)
    }

    private func endBatchSelection() {
        isBatchSelecting = false
        selection = []
    }

    private func confirmBatch(_ action: BatchAction) {
        let ids = selection
        let books = affectedBooks
        pendingBatchAction = nil
        guard !ids.isEmpty else { return }

        switch action {
        case .disable:
            app.setSources(ids, enabled: false)
            batchResultText = books.isEmpty
                ? "已停用 \(ids.count) 个书源。"
                : "已停用 \(ids.count) 个书源。书架上的 \(books.count) 本书还在，需要时可重新启用。"
        case .delete:
            app.deleteSources(withIDs: ids)
            batchResultText = books.isEmpty
                ? "已删除 \(ids.count) 个书源。"
                : "已删除 \(ids.count) 个书源。书架上的 \(books.count) 本书已保留，但暂时无法更新。"
        }
        endBatchSelection()
        showBatchResult = true
    }

    private func report(_ result: (added: Int, warnings: [String])) {
        showImport = false
        showURLImport = false
        var messages: [String] = []
        if result.added > 0 {
            messages.append("新增 \(result.added) 个书源")
        } else if result.warnings.isEmpty {
            messages.append("没有新增书源（可能已存在）")
        }
        messages.append(contentsOf: result.warnings)
        lastWarnings = messages
        showWarnings = true
    }

    private func useClipboard() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            app.showBanner("剪贴板里没有文本", isError: true)
            return
        }
        report(app.importSources(fromJSON: text))
        #else
        app.showBanner("当前平台不支持剪贴板", isError: true)
        #endif
    }
}

private struct SourceRow: View {
    let source: BookSource
    /// Batch mode: the row shows a checkmark instead of a switch and tapping
    /// it toggles the selection.
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// Drawn in the pinned block rather than in its own group.
    var isPinned: Bool = false
    var onToggle: () -> Void
    /// Opens the source's detail screen. Deliberately bound to the text block
    /// rather than the whole row: a row-wide gesture also fires when the switch
    /// is tapped, which would open the editor on every enable/disable.
    var onOpen: () -> Void
    /// Starts batch selection with this row included, from the context menu.
    var onSelect: () -> Void = {}
    /// Adds or removes this row when the selection drag reaches it.
    var onMoveToggle: () -> Void = {}

    /// Computed once per render from the parsed rules. Cheap (14 string scans)
    /// and it cannot go stale, unlike a value cached at import time.
    private var compatibility: SourceCompatibility { source.compatibility }

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Palette.accent : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if source.isBuiltIn {
                        Text("内置")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if !source.enabled {
                        Text("已停用")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    if let badge = compatibility.badge {
                        Text(badge.title)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .foregroundStyle(badge.color)
                            .background(badge.color.opacity(0.15), in: Capsule())
                    }
                }
                Text(source.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !isSelecting {
                    HStack(spacing: 8) {
                        if source.canSearch {
                            Label("可搜索", systemImage: "magnifyingglass")
                        } else {
                            Label("无搜索规则", systemImage: "exclamationmark.triangle")
                        }
                        if source.enabledExplore {
                            Label("发现", systemImage: "safari")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(source.canSearch ? Color.secondary : Color.orange)
                    if let note = compatibility.shortNote {
                        // Says what is missing rather than just that JS is involved:
                        // "封面用 JS" and "目录用 JS" need very different decisions,
                        // and only the second one means "pick another source".
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(compatibility.level == .unreadable ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                }
            }
            // The whole text column is the "open details" target, gaps included,
            // while the switch beside it keeps its own taps.
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // The gesture stays attached in both modes; only what it does
                // changes, so entering and leaving selection never rebuilds the
                // row into a different type underneath the list.
                if isSelecting {
                    onMoveToggle()
                } else {
                    onOpen()
                }
            }
            if !isSelecting {
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .contentShape(Rectangle())
                .onTapGesture {}
            }
        }
        // The checkmark is part of the row's tap target, not a stray icon.
        //
        // It sits outside the text column, so a tap on the circle used to fall
        // between the two hit areas and do nothing — the one place a reader
        // would naturally poke in a selection list.
        .onTapGesture {
            guard isSelecting else { return }
            onMoveToggle()
        }
        .opacity(source.enabled || isSelecting ? 1 : 0.55)
        // Where this row sits, in the list's own coordinates. The slide gesture
        // reads these instead of guessing row heights and scroll offsets.
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: RowFramesKey.self,
                value: [source.id: proxy.frame(in: .named(SourceRowLayout.space))]
            )
        })
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("批量选择", systemImage: "checklist")
            }
        }
    }
}

// MARK: - Row layout

/// Shared numbers for the source rows and the slide gesture that reads them.
private enum SourceRowLayout {
    /// Rows report their frames in this space, which is the list's own.
    static let space = "source-list"
}

/// Where each visible row sits, in the list's coordinates.
private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The row chrome a plain row does not get from `List`.
///
/// `List` gives every row swipe actions for free; a row inside a `LazyVStack`
/// does not, so the same choices come back as a context menu: a short tap still
/// opens the details, a long press offers edit, delete and batch select.
private struct SourceRowChrome: ViewModifier {
    let isBatchSelecting: Bool
    /// The row is in the pinned block, so its menu offers "取消置顶" first.
    var isPinned: Bool = false
    var onDelete: () -> Void
    var onEdit: () -> Void
    var onBatch: () -> Void
    var onTogglePin: () -> Void = {}
    var onMovePinUp: () -> Void = {}
    var onMovePinDown: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .contextMenu {
                if !isBatchSelecting {
                    Button {
                        onTogglePin()
                    } label: {
                        Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    if isPinned {
                        Button {
                            onMovePinUp()
                        } label: {
                            Label("上移", systemImage: "arrow.up")
                        }
                        Button {
                            onMovePinDown()
                        } label: {
                            Label("下移", systemImage: "arrow.down")
                        }
                    }
                    Button {
                        onEdit()
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button {
                        onBatch()
                    } label: {
                        Label("批量选择", systemImage: "checklist")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
    }
}

// MARK: - Compatibility presentation

/// How a compatibility level looks in the list.
///
/// Kept in the view layer: `SourceCompatibility` lives in `NovelKit`, which also
/// builds on Linux where there is no SwiftUI to give it colours.
private struct CompatibilityBadge {
    var title: String
    var color: Color
}

private extension SourceCompatibility {
    var badge: CompatibilityBadge? {
        switch level {
        case .supported:
            return nil
        case .degraded:
            // Names the cause, not the symptom: "部分" alone would read as
            // "this source is half-broken", when in fact it reads fine and only
            // loses some metadata.
            return CompatibilityBadge(title: "JS 已跳过", color: .secondary)
        case .unreadable:
            return CompatibilityBadge(title: "JS 必需", color: .orange)
        }
    }

    /// One line naming what is lost, or `nil` when nothing is.
    var shortNote: String? {
        guard hasJavaScript else { return nil }
        if !blockingRoles.isEmpty {
            return "\(blockingRoles.joined(separator: "、"))规则必须用 JS，无法读取"
        }
        return "\(roles.joined(separator: "、"))用到 JS，已跳过，不影响阅读"
    }

    /// The full explanation shown on the source's detail page.
    var detail: String {
        var lines: [String] = []
        if !blockingRoles.isEmpty {
            lines.append("\(blockingRoles.joined(separator: "、"))的规则是纯 JavaScript，本应用不能执行，所以这个书源读不出章节。换一个书源即可。")
        }
        let soft = roles.filter { !blockingRoles.contains($0) }
        if !soft.isEmpty {
            lines.append("\(soft.joined(separator: "、"))的规则里带 JavaScript，已跳过。这些字段会缺失或保持原文，不影响阅读。")
        }
        if usesNetwork || usesDOM {
            var needs: [String] = []
            if usesDOM { needs.append("解析页面结构") }
            if usesNetwork { needs.append("再次请求页面") }
            lines.append("其中的 JavaScript 还需要\(needs.joined(separator: "、"))，执行环境更复杂。")
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Import

private struct ImportSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var onImport: (String) -> (added: Int, warnings: [String])

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("在这里粘贴书源 JSON（数组或单个对象）")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("粘贴") { paste() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            error = "请先粘贴书源 JSON"
                            return
                        }
                        let result = onImport(trimmed)
                        if result.added == 0 && result.warnings.isEmpty {
                            error = "没有解析到书源"
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if text.isEmpty { paste(silent: true) }
            }
        }
    }

    private func paste(silent: Bool = false) {
        #if canImport(UIKit)
        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
            text = clipboard
        } else if !silent {
            error = "剪贴板里没有文本"
        }
        #else
        error = "当前平台不支持剪贴板"
        #endif
    }
}

private struct ImportFromURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isLoading = false
    @State private var error: String?
    var onImport: (Data) -> (added: Int, warnings: [String])

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/sources.json", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("下载一个书源 JSON 文件并导入。链接需要能直接访问。")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await load() }
                    } label: {
                        if isLoading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("下载中…")
                            }
                        } else {
                            Label("下载并导入", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isLoading || trimmedURL.isEmpty)
                }
            }
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            error = "请输入以 http(s) 开头的链接"
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                error = "服务器返回 HTTP \(http.statusCode)"
                return
            }
            let result = onImport(data)
            if result.added > 0 || !result.warnings.isEmpty {
                dismiss()
            } else {
                error = "文件里没有可用的书源"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Editor

private struct SourceEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BookSource
    @State private var showRawJSON = false

    init(source: BookSource) {
        _draft = State(initialValue: source)
    }

    var body: some View {
        Form {
            let compatibility = draft.compatibility
            if compatibility.hasJavaScript {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: compatibility.level == .unreadable
                                  ? "exclamationmark.triangle.fill"
                                  : "info.circle")
                                .foregroundStyle(compatibility.level == .unreadable ? Color.orange : Color.secondary)
                            Text(compatibility.level == .unreadable ? "这个书源无法读取" : "部分规则已跳过")
                                .font(.footnote.weight(.medium))
                        }
                        Text(compatibility.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("基本信息") {
                LabeledContent("名称") {
                    TextField("书源名称", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("站点") {
                    TextField("https://…", text: $draft.baseURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                LabeledContent("分组") {
                    TextField("未分组", text: $draft.group)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("启用", isOn: $draft.enabled)
                if !draft.comment.isEmpty {
                    Text(draft.comment)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("搜索") {
                RuleField(title: "搜索地址", text: $draft.searchURL, placeholder: "/search?q={{key}}")
                RuleField(title: "结果列表", text: $draft.search.bookList, placeholder: "@css:.book-list li")
                RuleField(title: "书名", text: $draft.search.name, placeholder: "@css:.name@text")
                RuleField(title: "作者", text: $draft.search.author, placeholder: "@css:.author@text")
                RuleField(title: "详情链接", text: $draft.search.bookURL, placeholder: "@css:a@href")
                RuleField(title: "封面", text: $draft.search.coverURL, placeholder: "@css:img@src")
            }

            Section("详情") {
                RuleField(title: "书名", text: $draft.bookInfo.name)
                RuleField(title: "作者", text: $draft.bookInfo.author)
                RuleField(title: "简介", text: $draft.bookInfo.intro)
                RuleField(title: "目录地址", text: $draft.bookInfo.tocURL)
            }

            Section("目录") {
                RuleField(title: "章节列表", text: $draft.toc.chapterList, placeholder: "@css:#list dd a")
                RuleField(title: "章节名", text: $draft.toc.chapterName, placeholder: "@text")
                RuleField(title: "章节链接", text: $draft.toc.chapterURL, placeholder: "@href")
                RuleField(title: "下一页", text: $draft.toc.nextTOCURL)
            }

            Section("正文") {
                RuleField(title: "正文规则", text: $draft.content.content, placeholder: "@css:#content@html")
                RuleField(title: "下一页", text: $draft.content.nextContentURL)
                RuleField(title: "内容替换", text: $draft.content.replaceRegex, placeholder: "广告.*?##")
            }

            Section("高级") {
                DisclosureGroup("原始请求头") {
                    TextEditor(text: $draft.header)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                }
                Button {
                    showRawJSON = true
                } label: {
                    Label("查看原始 JSON", systemImage: "curlybraces")
                }
                .disabled(draft.originalJSON?.isEmpty ?? true)
                Button(role: .destructive) {
                    app.deleteSource(draft)
                    dismiss()
                } label: {
                    Label("删除这个书源", systemImage: "trash")
                }
            }
        }
        .navigationTitle("编辑书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    app.upsert(draft)
                    app.showBanner("已保存书源", isError: false)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheet(isPresented: $showRawJSON) {
            RawJSONView(text: draft.originalJSON ?? "{}")
        }
    }
}

private struct RuleField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

private struct RawJSONView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("原始 JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
#endif
