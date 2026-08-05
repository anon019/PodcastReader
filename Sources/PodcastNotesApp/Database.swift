import CSQLite
import Foundation

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .prepare(let message), .step(let message): message
        }
    }
}

@MainActor
final class PodcastDatabase {
    static let shared = PodcastDatabase()
    let path: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        path = base.appendingPathComponent("PodcastNotes/podcast_notes.sqlite3")
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 3000)
        return try body(handle)
    }

    private func rows(_ db: OpaquePointer, sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws -> [[String: Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var result: [[String: Any?]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw DatabaseError.step(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Any?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
                case SQLITE_NULL: row[name] = nil
                default: row[name] = nil
                }
            }
            result.append(row)
        }
        return result
    }

    private func execute(_ db: OpaquePointer, sql: String, values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.step(String(cString: sqlite3_errmsg(db))) }
    }

    func loadSources() throws -> [Source] {
        try withDatabase { db in
            try rows(db, sql: """
                SELECT s.*, SUM(CASE WHEN e.is_read=0 THEN 1 ELSE 0 END) AS unread_count
                FROM sources s LEFT JOIN episodes e ON e.source_id=s.id
                WHERE s.archived=0
                GROUP BY s.id ORDER BY s.category,s.name
                """).map { row in
                    Source(
                        id: row.string("id"), name: row.string("name"), handle: row.string("handle"), kind: row.string("kind"),
                        category: row.string("category"), minDuration: row.int("min_duration"), enabled: row.int("enabled") == 1,
                        health: row.string("health"), lastCheckedAt: row.optionalString("last_checked_at"),
                        lastError: row.optionalString("last_error"), unreadCount: row.int("unread_count"),
                        profileVersion: row.string("profile_version"), profilePrompt: row.string("profile_prompt")
                    )
                }
        }
    }

    func loadEpisodes() throws -> [Episode] {
        try withDatabase { db in
            try rows(db, sql: """
                SELECT e.id,e.source_id,e.title,e.url,e.thumbnail_url,e.published_at,e.organized_at,
                       e.duration_seconds,e.status,e.is_read,e.transcript_error,e.error,
                       s.name AS source_name
                FROM episodes e
                JOIN sources s ON s.id=e.source_id
                WHERE s.kind!='channel' OR e.duration_seconds IS NULL OR e.duration_seconds>=s.min_duration
                ORDER BY e.published_at DESC
                """).map { row in
                    Episode(
                        id: row.string("id"), sourceID: row.string("source_id"), sourceName: row.string("source_name"),
                        title: row.string("title"), url: row.string("url"), thumbnailURL: row.string("thumbnail_url"),
                        publishedAt: row.string("published_at"), organizedAt: row.optionalString("organized_at"),
                        durationSeconds: row.optionalInt("duration_seconds"),
                        status: row.string("status"), isRead: row.int("is_read") == 1,
                        transcriptError: row.optionalString("transcript_error"), error: row.optionalString("error")
                    )
                }
        }
    }

    func loadAnalysisJSON(episodeID: String) throws -> String? {
        try withDatabase { db in
            try rows(db, sql: "SELECT analysis_json FROM episodes WHERE id=?", bind: {
                sqlite3_bind_text($0, 1, episodeID, -1, SQLITE_TRANSIENT)
            }).first?.optionalString("analysis_json")
        }
    }

    func loadSegments(episodeID: String) throws -> [TranscriptSegment] {
        try withDatabase { db in
            try rows(db, sql: "SELECT * FROM transcript_segments WHERE episode_id=? ORDER BY position", bind: {
                sqlite3_bind_text($0, 1, episodeID, -1, SQLITE_TRANSIENT)
            }).map { row in
                TranscriptSegment(id: Int64(row.int("id")), position: row.int("position"), timestamp: row.string("timestamp"),
                                  startSeconds: row.optionalDouble("start_seconds"), originalText: row.string("original_text"),
                                  translatedText: row.optionalString("translated_text"))
            }
        }
    }

    func loadRuns() throws -> [PipelineRun] {
        try withDatabase { db in
            try rows(db, sql: "SELECT * FROM runs ORDER BY id DESC LIMIT 30").map { row in
                PipelineRun(id: Int64(row.int("id")), trigger: row.string("trigger"), startedAt: row.string("started_at"),
                            finishedAt: row.optionalString("finished_at"), status: row.string("status"),
                            discoveredCount: row.int("discovered_count"), completedCount: row.int("completed_count"),
                            noTranscriptCount: row.int("no_transcript_count"), failedCount: row.int("failed_count"),
                            currentDetail: row.optionalString("current_detail"), error: row.optionalString("error"))
            }
        }
    }

    func markRead(_ episodeID: String, read: Bool) throws {
        try withDatabase { try execute($0, sql: "UPDATE episodes SET is_read=?,updated_at=datetime('now') WHERE id=?", values: [read ? "1" : "0", episodeID]) }
    }

}

private extension Dictionary where Key == String, Value == Any? {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func optionalString(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int { self[key] as? Int ?? 0 }
    func optionalInt(_ key: String) -> Int? { self[key] as? Int }
    func optionalDouble(_ key: String) -> Double? { self[key] as? Double }
}
