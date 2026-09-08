import CSQLite
import Foundation


@main
@MainActor
struct DatabaseTests {
    static func main() throws {
        let tests = DatabaseTests()
        try tests.retainedConnectionDetectsCommitsEvenWithinOneSecond()
        try tests.modelKeepsEmptyTodayEmptyAndShowsNewContent()
        try tests.translationCommitRefreshesDetailWithoutStatusChange()
        try tests.invalidAnalysisIsVisibleInsteadOfSilentlyBlank()
        try tests.unreadSourceCountMatchesDurationFilteredLibrary()
        print("5 Swift database and reader regression checks passed")
    }

    func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) throws {
        let passed = try condition()
        precondition(passed, "Regression failed", file: file, line: line)
    }
    func fixture() throws -> (URL, PodcastDatabase) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastTests-\(UUID().uuidString).sqlite3")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", try PipelineRunner.resourcesURL().appendingPathComponent("pipeline.py").path,
                             "--db", path.path, "init"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0)
        return (path, PodcastDatabase(path: path))
    }

    func write(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        try expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    func cleanup(_ path: URL, _ db: PodcastDatabase) {
        db.close()
        for suffix in ["", "-wal", "-shm", ".worker.lock"] {
            try? FileManager.default.removeItem(atPath: path.path + suffix)
        }
    }

    func retainedConnectionDetectsCommitsEvenWithinOneSecond() throws {
        let (path, db) = try fixture()
        defer { cleanup(path, db) }
        let initial = try db.dataVersion()
        try expect(try db.dataVersion() == initial)
        try write(path, "UPDATE sources SET category='自定义分类' WHERE id='all-in'")
        let updated = try db.dataVersion()
        try expect(updated != initial)
        try expect(try db.loadLibrary().sources.contains { $0.category == "自定义分类" })
        try write(path, "UPDATE sources SET category='第二次修改' WHERE id='all-in'")
        try expect(try db.dataVersion() != updated)
    }

    func modelKeepsEmptyTodayEmptyAndShowsNewContent() throws {
        let (path, db) = try fixture()
        defer { cleanup(path, db) }
        try write(path, """
          INSERT INTO episodes(id,source_id,title,url,published_at,created_at,updated_at)
          VALUES('older','all-in','Old','https://example.invalid','2000-01-01','2000-01-01T00:00:00Z','2000-01-01');
        """)
        let model = AppModel(database: db)
        try expect(model.filteredEpisodes.isEmpty)
        try expect(model.selectedEpisode == nil)
        try write(path, """
          INSERT INTO episodes(id,source_id,title,url,published_at,created_at,updated_at)
          VALUES('new','all-in','New','https://example.invalid',datetime('now'),datetime('now'),datetime('now'));
        """)
        model.refreshLibrary()
        try expect(model.selectedEpisodeID == "new")
        try expect(model.filteredEpisodes.count == 1)
        model.markRead(true)
        try expect(model.sources.first { $0.id == "all-in" }?.unreadCount == 1)
        try expect(try db.loadEpisodes().first { $0.id == "new" }?.isRead == true)
    }

    func translationCommitRefreshesDetailWithoutStatusChange() throws {
        let (path, db) = try fixture()
        defer { cleanup(path, db) }
        try write(path, """
          INSERT INTO episodes(id,source_id,title,url,published_at,created_at,updated_at,status)
          VALUES('new','all-in','New','https://example.invalid',datetime('now'),datetime('now'),datetime('now'),'complete');
          INSERT INTO transcript_segments(episode_id,position,original_text) VALUES('new',0,'hello');
        """)
        let model = AppModel(database: db)
        try expect(model.segments.first?.translatedText == nil)
        try write(path, "UPDATE transcript_segments SET translated_text='你好'")
        model.refreshLibrary()
        try expect(model.segments.first?.translatedText == "你好")
    }

    func invalidAnalysisIsVisibleInsteadOfSilentlyBlank() throws {
        let (path, db) = try fixture()
        defer { cleanup(path, db) }
        try write(path, """
          INSERT INTO episodes(id,source_id,title,url,published_at,created_at,updated_at,status,analysis_json)
          VALUES('new','all-in','New','https://example.invalid',datetime('now'),datetime('now'),datetime('now'),'complete','invalid');
        """)
        let model = AppModel(database: db)
        try expect(model.errorMessage?.contains("读取本期内容失败") == true)
    }

    func unreadSourceCountMatchesDurationFilteredLibrary() throws {
        let (path, db) = try fixture()
        defer { cleanup(path, db) }
        try write(path, """
          INSERT INTO episodes(id,source_id,title,url,published_at,created_at,updated_at,duration_seconds)
          VALUES('clip','all-in','Clip','https://example.invalid',datetime('now'),datetime('now'),datetime('now'),1);
        """)
        let library = try db.loadLibrary()
        try expect(library.episodes.isEmpty)
        try expect(library.sources.first { $0.id == "all-in" }?.unreadCount == 0)
    }
}
