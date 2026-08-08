import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 178, ideal: 205, max: 245)
        } content: {
            EpisodeInbox()
                .navigationSplitViewColumnWidth(min: 310, ideal: 372, max: 430)
        } detail: {
            ReaderWorkspace()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(FieldNotesTheme.action)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("外观", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.symbol).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Label("外观", systemImage: AppearanceMode(rawValue: appearanceMode)?.symbol ?? "circle.lefthalf.filled")
                }
                .help("切换浅色、深色或跟随系统")

                if model.isUpdating { ProgressView().controlSize(.small).help(model.updateMessage) }
                Button {
                    model.checkForUpdates()
                } label: {
                    Label(model.isUpdating ? "正在更新" : "检查更新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isUpdating)

                Button {
                    model.isShowingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $model.isShowingAddSheet) { AddLinkSheet() }
        .onAppear { applyAppearance(appearanceMode) }
        .onChange(of: appearanceMode) { _, newValue in
            applyAppearance(newValue)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                model.refreshLibrary()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            applyAppearance(appearanceMode)
            model.refreshLibrary()
        }
        .alert("Podcast Reader", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func applyAppearance(_ rawValue: String) {
        let mode = AppearanceMode(rawValue: rawValue) ?? .system
        NSApplication.shared.appearance = mode.appKitAppearance
    }
}

struct LibrarySidebar: View {
    @EnvironmentObject private var model: AppModel

    private let categories = [
        "投资与市场", "AI 与基础设施", "创业与产品", "人物访谈",
        "工程实践", "科学与推理", "历史与宏观", "商业报道", "科技新闻"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarHeading("阅读")
                    sidebarButton(.today, count: model.todayCount)
                    sidebarButton(.unread, count: model.unreadCount)

                    SidebarHeading("Podcast 书架")
                    ForEach(categories, id: \.self) { category in
                        let matching = model.sources.filter { $0.category == category }
                        Button {
                            model.selectedSourceID = nil
                            model.selectedCategory = category
                            model.selectedSection = .today
                            model.selectedEpisodeID = model.filteredEpisodes.first?.id
                            model.loadSelectedDetail()
                        } label: {
                            HStack(spacing: 9) {
                                Circle().fill(categoryColor(category)).frame(width: 7, height: 7)
                                Text(category)
                                Spacer()
                                Text("\(matching.count)").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(SidebarRowStyle(selected: model.selectedCategory == category))
                    }
                    Button {
                        model.selectedSourceID = nil
                        model.selectedCategory = nil
                        model.selectedSection = .sources
                    } label: {
                        Label("管理 \(model.sources.count) 个来源", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(SidebarRowStyle(selected: model.selectedSection == .sources))
                }
                .padding(10)
            }
            Divider()
            DailyUpdateFooter()
        }
        .background(FieldNotesTheme.chrome)
    }

    private func sidebarButton(_ section: LibrarySection, count: Int) -> some View {
        Button {
            model.selectedSourceID = nil
            model.selectedCategory = nil
            model.selectedSection = section
            model.selectedEpisodeID = model.filteredEpisodes.first?.id
            model.loadSelectedDetail()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol).frame(width: 16)
                Text(section.rawValue)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(SidebarRowStyle(selected: model.selectedSection == section && model.selectedSourceID == nil && model.selectedCategory == nil))
    }

    private func categoryColor(_ name: String) -> Color {
        switch name {
        case "投资与市场": FieldNotesTheme.action
        case "AI 与基础设施": FieldNotesTheme.amber
        case "创业与产品": Color.indigo.opacity(0.72)
        case "人物访谈": Color.purple.opacity(0.68)
        case "工程实践": Color.teal.opacity(0.76)
        case "科学与推理": Color.blue.opacity(0.72)
        case "历史与宏观": Color.brown.opacity(0.72)
        case "商业报道": Color.orange.opacity(0.76)
        default: Color.pink.opacity(0.68)
        }
    }
}

private struct DailyUpdateFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.selectedSourceID = nil
            model.selectedCategory = nil
            model.selectedSection = .processing
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("每日更新")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(FieldNotesTheme.muted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Label("每天 07:30 自动执行", systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FieldNotesTheme.ink)

                if let run = model.dailyStatusRun {
                    HStack(spacing: 6) {
                        Image(systemName: statusSymbol(run))
                            .foregroundStyle(run.status == "complete" && run.failedCount == 0 ? FieldNotesTheme.action : FieldNotesTheme.amber)
                        Text(run.statusLabel).fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                    Text(run.status == "running" ? (run.currentDetail ?? "正在处理…") : "完成于 \(run.finishedTimeLabel)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(FieldNotesTheme.muted)
                        .lineLimit(1)
                    Text("发现 \(run.discoveredCount) · 整理 \(run.completedCount) · 失败 \(run.failedCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FieldNotesTheme.muted)
                } else {
                    Text("尚无更新记录")
                        .font(.system(size: 11))
                        .foregroundStyle(FieldNotesTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(model.selectedSection == .processing ? FieldNotesTheme.selected.opacity(0.72) : Color.clear)
    }

    private func statusSymbol(_ run: PipelineRun) -> String {
        if run.status == "running" { return "arrow.triangle.2.circlepath" }
        if run.status == "complete" && run.failedCount == 0 { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }
}

private struct SidebarHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(FieldNotesTheme.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .background(selected ? FieldNotesTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct EpisodeInbox: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold)).foregroundStyle(FieldNotesTheme.action)
                Text(headerTitle).font(.fieldTitle(29)).foregroundStyle(FieldNotesTheme.ink)
                Text(statusLine).font(.caption).foregroundStyle(FieldNotesTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 18)

            Divider()
            if model.selectedSection == .sources {
                SourceManagementView()
            } else if model.selectedSection == .processing {
                ProcessingView()
            } else if model.filteredEpisodes.isEmpty {
                ContentUnavailableView("这里还没有内容", systemImage: "waveform", description: Text("点击“检查更新”或添加 YouTube 链接。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredEpisodes) { episode in
                            Button { model.selectEpisode(episode) } label: {
                                EpisodeRow(episode: episode, selected: model.selectedEpisode?.id == episode.id)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(FieldNotesTheme.paper)
    }

    private var headerTitle: String {
        if model.selectedSection == .sources { return "订阅来源" }
        if model.selectedSection == .processing { return "处理状态" }
        if let sourceID = model.selectedSourceID,
           let source = model.sources.first(where: { $0.id == sourceID }) { return source.name }
        if let category = model.selectedCategory { return category }
        return Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private var eyebrow: String {
        if model.selectedSourceID != nil { return "订阅来源" }
        if model.selectedCategory != nil { return "专题阅读" }
        return "今日同步内容"
    }

    private var statusLine: String {
        if model.isUpdating { return model.updateMessage }
        if model.selectedSourceID != nil || model.selectedCategory != nil {
            return "共 \(model.filteredEpisodes.count) 期 · 点击节目即可阅读提炼与双语原文"
        }
        return "今天新增 \(model.todayCount) 期 · \(model.unreadCount) 期未读 · \(model.noTranscriptCount) 期无字幕"
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(episode.isRead ? Color.clear : FieldNotesTheme.unread)
                .frame(width: 7, height: 7).padding(.top, 7)
            EpisodeThumbnail(url: episode.thumbnailURL).frame(width: 94, height: 53)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.sourceName.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(FieldNotesTheme.action)
                    .lineLimit(1)
                Text(episode.title).font(.system(size: 13, weight: episode.isRead ? .medium : .bold))
                    .foregroundStyle(FieldNotesTheme.ink).lineLimit(3)
                VStack(alignment: .leading, spacing: 3) {
                    EpisodeDateLine(symbol: "play.rectangle", label: "原始发布", value: episode.publishedDayLabel, accent: FieldNotesTheme.amber)
                    EpisodeDateLine(symbol: "sparkles", label: "整理完成", value: episode.organizedDayLabel, accent: FieldNotesTheme.action)
                }
                HStack(spacing: 6) {
                    Text(episode.durationLabel)
                    Spacer(minLength: 3)
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(episode.statusLabel)
                }
                .font(.caption2).foregroundStyle(FieldNotesTheme.muted)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? FieldNotesTheme.selected : Color.clear)
        .animation(.easeOut(duration: 0.16), value: selected)
    }

    private var statusColor: Color {
        switch episode.status {
        case "complete": FieldNotesTheme.action
        case "analyzing", "transcript_fetching": FieldNotesTheme.amber
        case "no_transcript", "failed": FieldNotesTheme.muted
        default: Color.blue.opacity(0.7)
        }
    }
}

private struct EpisodeDateLine: View {
    let symbol: String
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(label).font(.system(size: 9, weight: .semibold))
            Text(value).font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(accent)
    }
}

struct EpisodeThumbnail: View {
    let url: String

    private var candidates: [URL] {
        guard let marker = url.range(of: "/vi/") else { return [URL(string: url)].compactMap { $0 } }
        let tail = url[marker.upperBound...]
        guard let videoID = tail.split(separator: "/").first, !videoID.isEmpty else {
            return [URL(string: url)].compactMap { $0 }
        }
        return ["maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(videoID)/\($0)")
        }
    }

    var body: some View {
        ThumbnailCandidateView(candidates: candidates, index: 0)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct ThumbnailCandidateView: View {
    let candidates: [URL]
    let index: Int

    var body: some View {
        if index < candidates.count {
            AsyncImage(url: candidates[index]) { phase in
            switch phase {
            case .success(let image): image.resizable().interpolation(.high).scaledToFill()
            case .failure:
                ThumbnailCandidateView(candidates: candidates, index: index + 1)
            case .empty:
                ZStack {
                    FieldNotesTheme.selected
                    ProgressView().controlSize(.small)
                }
            @unknown default: EmptyView()
            }
            }
        } else {
            ZStack {
                FieldNotesTheme.selected
                Image(systemName: "waveform").foregroundStyle(FieldNotesTheme.action.opacity(0.55))
            }
        }
    }
}

struct ReaderWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let episode = model.selectedEpisode {
            VStack(spacing: 0) {
                ZStack {
                    Picker("阅读模式", selection: $model.readerMode) {
                        ForEach(ReaderMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 410)

                    HStack(spacing: 7) {
                        Spacer()
                        Button { model.readerFontSize = max(15, model.readerFontSize - 1) } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .disabled(model.readerFontSize <= 15)
                        .help("缩小正文")
                        Text("\(Int(model.readerFontSize))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(FieldNotesTheme.muted)
                            .frame(width: 22)
                        Button { model.readerFontSize = min(22, model.readerFontSize + 1) } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .disabled(model.readerFontSize >= 22)
                        .help("放大正文")
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                }
                .padding(.vertical, 10)

                Divider()
                Group {
                    switch model.readerMode {
                    case .reading: ReadingView(episode: episode)
                    case .transcript: TranscriptView(episode: episode)
                    }
                }
                // Separate identities prevent positions leaking across episodes;
                // each page restores its own persisted offset inside the view.
                .id("\(episode.id)-\(model.readerMode.rawValue)")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .background(FieldNotesTheme.paper)
            .animation(.easeOut(duration: 0.18), value: model.readerMode)
        } else {
            ContentUnavailableView("开始今天的阅读", systemImage: "book.pages", description: Text("检查订阅源后，新的 Podcast 会出现在这里。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FieldNotesTheme.paper)
        }
    }
}

struct ReadingView: View {
    @EnvironmentObject private var model: AppModel
    let episode: Episode

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ScrollPositionMemory(key: "\(episode.id).reading")
                    .frame(height: 0)
                VStack(alignment: .leading, spacing: 0) {
                    EpisodeThumbnail(url: episode.thumbnailURL)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 7, contentMode: .fill)
                        .clipped()
                    VStack(alignment: .leading, spacing: 9) {
                        Text(episode.sourceName.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.9)
                            .foregroundStyle(FieldNotesTheme.action)
                        Text(episode.title)
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                            .foregroundStyle(FieldNotesTheme.bodyText)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([episode.durationLabel, episode.statusLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FieldNotesTheme.muted)

                        HStack(spacing: 0) {
                            EpisodeDateBlock(
                                symbol: "play.rectangle.fill",
                                title: "YOUTUBE 原始发布",
                                date: episode.publishedDayLabel,
                                detail: episode.publishedFreshnessLabel,
                                accent: FieldNotesTheme.amber
                            )
                            Divider().frame(height: 46).padding(.horizontal, 22)
                            EpisodeDateBlock(
                                symbol: "sparkles",
                                title: "本地整理完成",
                                date: episode.organizedDayLabel,
                                detail: episode.organizedDate == nil ? "等待整理" : "结构化内容已保存",
                                accent: FieldNotesTheme.action
                            )
                        }
                        .padding(.top, 7)
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 20)
                }
                .background(FieldNotesTheme.surface.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(FieldNotesTheme.divider.opacity(0.8), lineWidth: 1))
                .padding(20)

                HStack(spacing: 8) {
                    Button { model.markRead(!episode.isRead) } label: { Label(episode.isRead ? "标记未读" : "标记已读", systemImage: episode.isRead ? "circle" : "checkmark") }
                    Button { if let url = URL(string: episode.url) { NSWorkspace.shared.open(url) } } label: { Label("打开原节目", systemImage: "arrow.up.right") }
                    Spacer()
                    if ["failed", "no_transcript"].contains(episode.status) { Button("重新尝试") { model.retrySelected() } }
                }
                .padding(.horizontal, 28).padding(.bottom, 8)

                if let analysis = model.selectedAnalysis {
                    AnalysisArticle(analysis: analysis)
                } else {
                    PendingAnalysisView(episode: episode)
                }
            }
        }
    }
}

private struct EpisodeDateBlock: View {
    let symbol: String
    let title: String
    let date: String
    let detail: String
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(FieldNotesTheme.muted)
                Text(date).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(FieldNotesTheme.bodyText)
                Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
            }
        }
    }
}

struct AnalysisArticle: View {
    @EnvironmentObject private var model: AppModel
    let analysis: EpisodeAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("一句话读懂", systemImage: "sparkles")
                    .font(.readerBodySemibold(13))
                    .foregroundStyle(FieldNotesTheme.action)
                Text(analysis.oneSentence)
                    .font(.readerDisplay(model.readerFontSize + 7))
                    .lineSpacing(9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FieldNotesTheme.selected.opacity(0.64), in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .leading) {
                Capsule().fill(FieldNotesTheme.action).frame(width: 4).padding(.vertical, 18)
            }

            ArticleLabel("核心摘要", symbol: "text.alignleft")
            Text(analysis.displayedCoreSummary.readerEditorialText)
                .font(.readerBody(model.readerFontSize))
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            ArticleLabel("主持人与嘉宾", symbol: "person.2")
            ForEach(analysis.participants) { participant in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(participant.name).font(.readerBodySemibold(model.readerFontSize + 1))
                        Text(participant.role == "guest" ? "嘉宾" : participant.role == "host" ? "主持人" : "参与者")
                            .font(.readerBodySemibold(11)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(FieldNotesTheme.selected, in: Capsule())
                        Spacer()
                        Text(participant.verification == "verified" ? "已核验" : "部分核验")
                            .font(.readerBody(11)).foregroundStyle(FieldNotesTheme.muted)
                    }
                    Text(participant.background)
                        .font(.readerBody(model.readerFontSize)).lineSpacing(6)
                    Text(participant.relevance)
                        .font(.readerBody(max(14, model.readerFontSize - 2)))
                        .foregroundStyle(FieldNotesTheme.muted).lineSpacing(5)
                }
                .padding(18)
                .background(FieldNotesTheme.surface.opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(FieldNotesTheme.divider.opacity(0.72), lineWidth: 1))
                .padding(.bottom, 10)
            }

            ArticleLabel("本期话题地图", symbol: "map")
            ForEach(Array(analysis.topics.enumerated()), id: \.element.id) { index, topic in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(FieldNotesTheme.action, in: Capsule())
                        Text(topic.title).font(.readerBodySemibold(model.readerFontSize + 2))
                        Spacer()
                        Text(topic.timestamps.joined(separator: " · "))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(FieldNotesTheme.action)
                    }
                    Text(topic.summary.readerEditorialText).font(.readerBody(model.readerFontSize)).lineSpacing(6)
                    BulletList(items: topic.keyPoints)
                }
                .padding(20)
                .background(FieldNotesTheme.surface.opacity(0.64), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(FieldNotesTheme.divider.opacity(0.65), lineWidth: 1))
                .padding(.bottom, 12)
            }

            ArticleLabel("核心洞察", symbol: "lightbulb.max")
            ForEach(Array(analysis.keyInsights.enumerated()), id: \.element.id) { index, insight in
                HStack(alignment: .top, spacing: 16) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FieldNotesTheme.action)
                        .frame(width: 32, height: 32)
                        .background(FieldNotesTheme.selected, in: Circle())
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(insight.title).font(.readerBodySemibold(model.readerFontSize + 1))
                            Spacer()
                            Text(insight.timestamp).font(.system(size: 11, design: .monospaced)).foregroundStyle(FieldNotesTheme.action)
                        }
                        Text(insight.explanation.readerEditorialText).font(.readerBody(model.readerFontSize)).lineSpacing(7)
                        Text(insight.speaker)
                            .font(.readerBody(11)).foregroundStyle(FieldNotesTheme.muted)
                    }
                }
                .padding(.vertical, 17)
                if index < analysis.keyInsights.count - 1 { Divider().padding(.leading, 48) }
            }

            if !analysis.extensions.isEmpty {
                ArticleLabel("值得继续追踪", symbol: "scope")
                BulletList(items: analysis.extensions)
            }
            if !analysis.evidenceLimits.isEmpty {
                ArticleLabel("证据与限制", symbol: "checkmark.shield")
                BulletList(items: analysis.evidenceLimits)
            }
            if !analysis.nextQuestions.isEmpty {
                ArticleLabel("下一步验证", symbol: "arrow.right.circle")
                BulletList(items: analysis.nextQuestions)
            }
            if !analysis.guestSources.isEmpty {
                ArticleLabel("背景核验来源", symbol: "link")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(analysis.guestSources) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).font(.readerBodySemibold(model.readerFontSize))
                                    Text(source.relevance).font(.readerBody(max(13, model.readerFontSize - 3))).foregroundStyle(FieldNotesTheme.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .foregroundStyle(FieldNotesTheme.bodyText)
        .padding(.horizontal, 42).padding(.top, 24).padding(.bottom, 96)
        .frame(maxWidth: .infinity)
    }
}

private struct ArticleLabel: View {
    let text: String
    let symbol: String
    init(_ text: String, symbol: String) { self.text = text; self.symbol = symbol }
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(text).font(.readerBodySemibold(19))
        }
        .foregroundStyle(FieldNotesTheme.action)
        .padding(.top, 38).padding(.bottom, 14)
    }
}

private struct BulletList: View {
    @EnvironmentObject private var model: AppModel
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 11) {
                    Circle().fill(FieldNotesTheme.action).frame(width: 5, height: 5).padding(.top, 9)
                    Text(item.readerEditorialText).font(.readerBody(model.readerFontSize)).lineSpacing(6)
                }
            }
        }
    }
}

private extension String {
    var readerEditorialText: String {
        let labels = [
            "[字幕事实]", "[字幕转述]", "[主持人判断]", "[主持人保留意见]",
            "[嘉宾判断]", "[我的归纳]", "[我的推断]", "[反方解释]", "[限定]",
            "[关键限定]", "[可验证命题]", "字幕事实：", "字幕转述：", "主持人判断：",
            "主持人同时限定：", "主持人保留意见：", "嘉宾判断：", "我的归纳：",
            "我的推断：", "反方解释：", "关键限定：", "可验证命题："
        ]
        let withoutLabels = labels.reduce(self) { partial, label in
            partial.replacingOccurrences(of: label, with: "")
        }
        let editorialRewrites = [
            ("关键时间限制：", ""),
            ("主持人转述称，", ""),
            ("主持人转述", ""),
            ("主持人同时", ""),
            ("主持人明确表示", "节目指出"),
            ("主持人进一步", "节目进一步"),
            ("主持人据此推断", "由此推断"),
            ("主持人认为", "节目认为"),
            ("被主持人视为", "被视为"),
            ("字幕没有提供", "本期未提供"),
            ("字幕未披露", "本期未披露")
        ]
        return editorialRewrites.reduce(withoutLabels) { partial, rewrite in
            partial.replacingOccurrences(of: rewrite.0, with: rewrite.1)
        }
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PendingAnalysisView: View {
    @EnvironmentObject private var model: AppModel
    let episode: Episode
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: episode.status == "no_transcript" ? "captions.bubble" : "text.magnifyingglass")
                .font(.system(size: 30)).foregroundStyle(FieldNotesTheme.action)
            Text(episode.status == "no_transcript" ? "YouTube 暂无可用 Transcript" : "本期尚未完成整理")
                .font(.fieldTitle(22))
            Text(episode.transcriptError ?? episode.error ?? "下一次更新会按来源专属 Profile 获取字幕并使用 Luna 分析。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("现在处理") { model.retrySelected() }.buttonStyle(.borderedProminent).tint(FieldNotesTheme.action)
        }
        .frame(maxWidth: .infinity).padding(60)
    }
}

struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    let episode: Episode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Transcript 显示", selection: $model.transcriptMode) {
                    ForEach(TranscriptMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                if model.segments.contains(where: { $0.translatedText == nil }) {
                    Button("翻译本期") { model.translateSelected() }.disabled(model.isUpdating || model.segments.isEmpty)
                } else if !model.segments.isEmpty {
                    Label("原文与翻译已保存在本机", systemImage: "internaldrive").foregroundStyle(FieldNotesTheme.action)
                }
            }
            .padding(14)
            Divider()
            if model.segments.isEmpty {
                ContentUnavailableView("没有 Transcript", systemImage: "captions.bubble", description: Text(episode.transcriptError ?? "等待字幕获取。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.segments) { segment in
                            TranscriptRow(segment: segment, mode: model.transcriptMode)
                            Divider()
                        }
                    }
                    .background {
                        ScrollPositionMemory(key: "\(episode.id).transcript")
                            .frame(width: 0, height: 0)
                    }
                    .frame(maxWidth: 980).padding(.horizontal, 28).padding(.bottom, 80)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct TranscriptRow: View {
    @EnvironmentObject private var model: AppModel
    let segment: TranscriptSegment
    let mode: TranscriptMode
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(segment.timestamp).font(.system(.caption, design: .monospaced)).foregroundStyle(FieldNotesTheme.action).frame(width: 56, alignment: .leading)
            if mode != .chinese {
                Text(segment.originalText)
                    .font(.system(size: model.readerFontSize, weight: .regular, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if mode != .original {
                Text(segment.translatedText ?? "尚未翻译")
                    .font(.readerBody(model.readerFontSize))
                    .foregroundStyle(segment.translatedText == nil ? FieldNotesTheme.muted : FieldNotesTheme.ink.opacity(0.86))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .foregroundStyle(FieldNotesTheme.bodyText)
        .lineSpacing(7).padding(.vertical, 20)
    }
}

struct SourceManagementView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sources) { source in
                    HStack(spacing: 10) {
                        Button { model.selectSource(source) } label: {
                            HStack(spacing: 10) {
                            Circle().fill(source.health == "error" ? Color.red.opacity(0.7) : FieldNotesTheme.action).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).fontWeight(.semibold)
                                Text("\(source.category) · 自动提炼").font(.caption).foregroundStyle(.secondary)
                                if source.health == "error", let error = source.lastError, !error.isEmpty {
                                    Text(error).font(.caption2).foregroundStyle(Color.red.opacity(0.82)).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text("\(source.unreadCount)").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Toggle("启用", isOn: Binding(
                            get: { source.enabled },
                            set: { model.setSourceEnabled(source, enabled: $0) }
                        )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button(role: .destructive) { model.removeSource(source) } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless).help("移出订阅，保留历史内容")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    Divider()
                }
            }
        }
    }
}

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(run.statusLabel,
                                  systemImage: run.status == "complete" && run.failedCount == 0 ? "checkmark.circle" : run.status == "running" ? "arrow.clockwise" : "exclamationmark.triangle")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(run.scheduleLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("开始 \(run.startedTimeLabel)").font(.caption).foregroundStyle(.secondary)
                        Text(run.status == "running" ? (run.currentDetail ?? "正在处理…") : "完成 \(run.finishedTimeLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("新增 \(run.discoveredCount) · 完成 \(run.completedCount) · 无字幕 \(run.noTranscriptCount) · 失败 \(run.failedCount)")
                            .font(.caption2).foregroundStyle(FieldNotesTheme.muted)
                    }
                    .padding(15)
                    Divider()
                }
            }
        }
    }
}

struct AddLinkSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 Podcast 来源或单集").font(.fieldTitle(24))
            Text("支持 YouTube 频道、播放列表或单集链接。单集会立即尝试获取 Transcript；没有字幕时只保留条目和失败原因。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://www.youtube.com/…", text: $url).textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加并检查") { model.addURL(url) }
                    .buttonStyle(.borderedProminent).tint(FieldNotesTheme.action)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isUpdating)
            }
        }
        .padding(24).frame(width: 520)
    }
}
