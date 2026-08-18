import Foundation

enum LibrarySection: String, CaseIterable, Identifiable {
    case today = "今日更新"
    case unread = "未读内容"
    case sources = "订阅来源"
    case processing = "处理状态"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .unread: "circle"
        case .sources: "books.vertical"
        case .processing: "clock.arrow.circlepath"
        }
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case reading = "结构化提炼"
    case transcript = "原文与翻译"
    var id: String { rawValue }
}

enum TranscriptMode: String, CaseIterable, Identifiable {
    case original = "只看原文"
    case chinese = "只看中文"
    case bilingual = "左右对照"
    var id: String { rawValue }
}

struct Source: Identifiable, Hashable {
    let id: String
    var name: String
    var handle: String
    var kind: String
    var category: String
    var minDuration: Int
    var enabled: Bool
    var health: String
    var lastCheckedAt: String?
    var lastError: String?
    var unreadCount: Int
    var profileVersion: String
    var profilePrompt: String
}

struct Episode: Identifiable, Hashable {
    let id: String
    let sourceID: String
    let sourceName: String
    var title: String
    var url: String
    var thumbnailURL: String
    var description: String
    var publishedAt: String
    var organizedAt: String?
    var createdAt: String
    var durationSeconds: Int?
    var status: String
    var isRead: Bool
    var transcriptError: String?
    var error: String?

    var statusLabel: String {
        switch status {
        case "complete": "已整理"
        case "analyzing": "提炼中"
        case "transcript_fetching": "取字幕"
        case "transcript_ready": "字幕就绪"
        case "no_transcript": isFreshCaptionPending ? "字幕生成中" : "暂无字幕"
        case "failed": "需重试"
        default: "待处理"
        }
    }

    var publishedDate: Date? { Self.parseDate(publishedAt) }
    var organizedDate: Date? { organizedAt.flatMap(Self.parseDate) }
    var createdDate: Date? { Self.parseDate(createdAt) }

    var publishedDayLabel: String { publishedDate.map(Self.preciseFormatter.string) ?? "未知" }
    var organizedDayLabel: String { organizedDate.map(Self.preciseFormatter.string) ?? "尚未整理" }

    var publishedFreshnessLabel: String {
        guard let publishedDate else { return "发布时间未知" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: publishedDate, relativeTo: .now)
    }

    var hasOfficialPreview: Bool {
        status == "no_transcript" && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isFreshCaptionPending: Bool {
        guard status == "no_transcript", let publishedDate else { return false }
        let age = Date().timeIntervalSince(publishedDate)
        return age >= 0 && age <= 72 * 60 * 60
    }

    var transcriptAvailabilityMessage: String {
        if isFreshCaptionPending {
            return "这期刚发布，YouTube 尚未生成可用字幕。官方简介与章节已经保留；每日更新会自动重试，字幕出现后会替换为完整提炼。"
        }
        return transcriptError ?? "YouTube 尚未提供可用 Transcript；后续更新仍会自动重试。"
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return sqliteDateFormatter.date(from: value)
    }

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let preciseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
        return formatter
    }()

    var durationLabel: String {
        guard let durationSeconds else { return "" }
        let minutes = max(1, durationSeconds / 60)
        return "\(minutes) 分钟"
    }
}

struct TranscriptSegment: Identifiable, Hashable {
    let id: Int64
    let position: Int
    let timestamp: String
    let startSeconds: Double?
    let originalText: String
    let translatedText: String?
}

struct EpisodeAnalysis: Codable, Hashable {
    struct Participant: Codable, Hashable, Identifiable {
        var id: String { role + name }
        let name: String
        let role: String
        let background: String
        let relevance: String
        let verification: String
        let sourceUrls: [String]
    }

    struct Topic: Codable, Hashable, Identifiable {
        var id: String { title }
        let title: String
        let summary: String
        let keyPoints: [String]
        let timestamps: [String]
    }

    struct Insight: Codable, Hashable, Identifiable {
        var id: String { title + timestamp }
        let title: String
        let explanation: String
        let timestamp: String
        let speaker: String
        let confidence: String
    }

    struct GuestSource: Codable, Hashable, Identifiable {
        var id: String { url }
        let title: String
        let url: String
        let relevance: String
    }

    let priority: String
    let oneSentence: String
    let coreSummary: String?
    let participants: [Participant]
    let topics: [Topic]
    let keyInsights: [Insight]
    let extensions: [String]
    let evidenceLimits: [String]
    let nextQuestions: [String]
    let guestSources: [GuestSource]

    var displayedCoreSummary: String {
        if let coreSummary = coreSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !coreSummary.isEmpty {
            return coreSummary
        }
        let legacySummary = topics
            .map(\.summary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return legacySummary.isEmpty ? oneSentence : legacySummary
    }
}

struct PipelineRun: Identifiable, Hashable {
    let id: Int64
    let trigger: String
    let startedAt: String
    let finishedAt: String?
    let status: String
    let discoveredCount: Int
    let completedCount: Int
    let noTranscriptCount: Int
    let failedCount: Int
    let currentDetail: String?
    let error: String?

    var startedDate: Date? { Self.parseDate(startedAt) }
    var finishedDate: Date? { finishedAt.flatMap(Self.parseDate) }

    var statusLabel: String {
        switch status {
        case "running": "正在更新"
        case "complete" where failedCount == 0: "更新完成"
        case "complete": "完成，有失败"
        default: "更新失败"
        }
    }

    var scheduleLabel: String {
        trigger == "codex_schedule" ? "每日自动更新" : trigger == "manual" ? "手动检查" : "来源更新"
    }

    var startedTimeLabel: String { startedDate.map(Self.preciseFormatter.string) ?? startedAt }
    var finishedTimeLabel: String { finishedDate.map(Self.preciseFormatter.string) ?? "尚未完成" }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return sqliteDateFormatter.date(from: value)
    }

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let preciseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM.dd HH:mm:ss"
        return formatter
    }()
}
