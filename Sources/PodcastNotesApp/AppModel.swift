import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [Source] = []
    @Published var episodes: [Episode] = []
    @Published var segments: [TranscriptSegment] = []
    @Published var selectedAnalysis: EpisodeAnalysis?
    @Published var runs: [PipelineRun] = []
    @Published var selectedSection: LibrarySection = .today
    @Published var selectedEpisodeID: String?
    @Published var selectedSourceID: String?
    @Published var selectedCategory: String?
    @Published var readerMode: ReaderMode = .reading
    @Published var transcriptMode: TranscriptMode = .bilingual
    @Published var readerFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(readerFontSize), forKey: "readerFontSize") }
    }
    @Published var isUpdating = false
    @Published var updateMessage = "准备就绪"
    @Published var errorMessage: String?
    @Published var isShowingAddSheet = false

    private let decoder = JSONDecoder()
    private var ownsUpdateTask = false

    init() {
        let storedFontSize = UserDefaults.standard.double(forKey: "readerFontSize")
        readerFontSize = storedFontSize >= 15 && storedFontSize <= 22 ? storedFontSize : 17
        do {
            _ = try PipelineRunner.runSync(["init"])
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedEpisode: Episode? {
        guard let selectedEpisodeID else { return filteredEpisodes.first }
        return episodes.first(where: { $0.id == selectedEpisodeID })
    }

    var filteredEpisodes: [Episode] {
        let calendar = Calendar.current
        let sourceCategories = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.category) })
        return episodes.filter { episode in
            if let selectedSourceID, episode.sourceID != selectedSourceID { return false }
            if let selectedCategory, sourceCategories[episode.sourceID] != selectedCategory { return false }
            if selectedSourceID != nil || selectedCategory != nil { return true }
            switch selectedSection {
            case .today:
                guard let date = episode.createdDate ?? episode.organizedDate ?? episode.publishedDate else { return true }
                return calendar.isDateInToday(date)
            case .unread: return !episode.isRead
            case .sources: return true
            case .processing: return !["complete", "no_transcript"].contains(episode.status)
            }
        }
    }

    var unreadCount: Int { episodes.filter { !$0.isRead }.count }
    var todayCount: Int {
        episodes.filter { episode in
            guard let date = episode.createdDate ?? episode.organizedDate ?? episode.publishedDate else { return false }
            return Calendar.current.isDateInToday(date)
        }.count
    }

    var processingCount: Int { episodes.filter { ["discovered", "transcript_fetching", "transcript_ready", "analyzing"].contains($0.status) }.count }
    var noTranscriptCount: Int { episodes.filter { $0.status == "no_transcript" }.count }

    func reload() {
        refreshLibrary(forceDetail: true)
    }

    func refreshLibrary() {
        refreshLibrary(forceDetail: false)
    }

    private func refreshLibrary(forceDetail: Bool) {
        do {
            let previousEpisodeID = selectedEpisodeID
            let previousStatus = episodes.first(where: { $0.id == previousEpisodeID })?.status
            sources = try PodcastDatabase.shared.loadSources()
            episodes = try PodcastDatabase.shared.loadEpisodes()
            runs = try PodcastDatabase.shared.loadRuns()
            if selectedEpisodeID == nil || !episodes.contains(where: { $0.id == selectedEpisodeID }) {
                selectedEpisodeID = filteredEpisodes.first?.id ?? episodes.first?.id
            }
            let currentStatus = episodes.first(where: { $0.id == selectedEpisodeID })?.status
            let hasRunningPipeline = runs.contains(where: { $0.status == "running" })
            if forceDetail || previousEpisodeID != selectedEpisodeID || previousStatus != currentStatus
                || (readerMode == .transcript && hasRunningPipeline) {
                loadSelectedDetail()
            }
            if let running = runs.first(where: { $0.status == "running" }) {
                isUpdating = true
                updateMessage = running.currentDetail ?? "正在更新…"
            } else if !ownsUpdateTask {
                isUpdating = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectEpisode(_ episode: Episode) {
        selectedEpisodeID = episode.id
        loadSelectedDetail()
        if !episode.isRead { markRead(true) }
    }

    func selectSource(_ source: Source?) {
        selectedSourceID = source?.id
        selectedCategory = nil
        selectedSection = .today
        selectedEpisodeID = filteredEpisodes.first?.id
        loadSelectedDetail()
    }

    func loadSelectedDetail() {
        guard let id = selectedEpisode?.id else {
            segments = []
            selectedAnalysis = nil
            return
        }
        segments = (try? PodcastDatabase.shared.loadSegments(episodeID: id)) ?? []
        if let json = try? PodcastDatabase.shared.loadAnalysisJSON(episodeID: id),
           let data = json.data(using: .utf8) {
            selectedAnalysis = try? decoder.decode(EpisodeAnalysis.self, from: data)
        } else {
            selectedAnalysis = nil
        }
    }

    func checkForUpdates() {
        // Scheduled runs write SQLite outside the App process. Refresh first so
        // completed content appears immediately, before starting any new scan.
        refreshLibrary()
        guard !isUpdating else { return }
        ownsUpdateTask = true
        isUpdating = true
        updateMessage = "正在检查 \(sources.filter(\.enabled).count) 个订阅源…"
        errorMessage = nil
        Task {
            do {
                _ = try await PipelineRunner.run([
                    "update", "--trigger", "manual", "--lookback-days", "30",
                    "--per-source", "5", "--retry-failed"
                ])
                reload()
                let last = runs.first
                updateMessage = "更新完成：新增 \(last?.discoveredCount ?? 0) · 完成 \(last?.completedCount ?? 0) · 无字幕 \(last?.noTranscriptCount ?? 0) · 失败 \(last?.failedCount ?? 0)"
            } catch {
                errorMessage = error.localizedDescription
                updateMessage = "更新失败"
                reload()
            }
            ownsUpdateTask = false
            isUpdating = false
        }
    }

    func addURL(_ url: String) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        ownsUpdateTask = true
        isUpdating = true
        updateMessage = "正在添加链接…"
        Task {
            do {
                let output = try await PipelineRunner.run(["add", value])
                if let data = output.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let episodeID = object["id"] as? String, object["kind"] as? String == "episode" {
                        _ = try await PipelineRunner.run(["process", episodeID])
                        _ = try await PipelineRunner.run(["translate", episodeID])
                    } else if let sourceID = object["id"] as? String {
                        _ = try await PipelineRunner.run([
                            "update", "--trigger", "new_source", "--lookback-days", "3650",
                            "--per-source", "1", "--source-id", sourceID, "--retry-failed"
                        ])
                    }
                }
                reload()
                updateMessage = "链接已添加"
                isShowingAddSheet = false
            } catch {
                errorMessage = error.localizedDescription
                updateMessage = "添加失败"
            }
            ownsUpdateTask = false
            isUpdating = false
        }
    }

    func retrySelected() {
        guard let id = selectedEpisode?.id else { return }
        ownsUpdateTask = true
        isUpdating = true
        updateMessage = "正在重新处理本期…"
        Task {
            do {
                _ = try await PipelineRunner.run(["process", id])
                _ = try await PipelineRunner.run(["translate", id])
                reload()
                updateMessage = "本期处理完成"
            } catch {
                errorMessage = error.localizedDescription
                updateMessage = "重试失败"
            }
            ownsUpdateTask = false
            isUpdating = false
        }
    }

    func translateSelected() {
        guard let id = selectedEpisode?.id else { return }
        ownsUpdateTask = true
        isUpdating = true
        updateMessage = "正在翻译完整 Transcript…"
        Task {
            do {
                _ = try await PipelineRunner.run(["translate", id])
                loadSelectedDetail()
                updateMessage = "翻译已缓存"
            } catch {
                errorMessage = error.localizedDescription
                updateMessage = "翻译失败"
            }
            ownsUpdateTask = false
            isUpdating = false
        }
    }

    func markRead(_ read: Bool) {
        guard let id = selectedEpisode?.id else { return }
        try? PodcastDatabase.shared.markRead(id, read: read)
        if let index = episodes.firstIndex(where: { $0.id == id }) { episodes[index].isRead = read }
    }

    func setSourceEnabled(_ source: Source, enabled: Bool) {
        Task {
            do {
                _ = try await PipelineRunner.run(["source-enable", source.id, enabled ? "1" : "0"])
                reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeSource(_ source: Source) {
        Task {
            do {
                _ = try await PipelineRunner.run(["source-remove", source.id])
                reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
