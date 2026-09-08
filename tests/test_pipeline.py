import datetime as dt
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "PodcastNotesApp" / "Resources"
SPEC = importlib.util.spec_from_file_location("podcast_reader_pipeline", RESOURCES / "pipeline.py")
pipeline = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(pipeline)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temporary.name) / "reader.sqlite3"
        self.db = pipeline.connect(self.db_path)
        pipeline.init_database(self.db, RESOURCES)

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def update_args(self, **overrides):
        values = dict(
            trigger="test", lookback_days=30, per_source=1, source_id="all-in",
            retry_failed=False, discover_only=True, transcript_only=False,
        )
        values.update(overrides)
        return SimpleNamespace(**values)

    def enable_only(self, source_id="all-in"):
        self.db.execute("UPDATE sources SET enabled=(id=?)", (source_id,))
        self.db.commit()

    def test_seed_init_is_idempotent_and_does_not_rewrite_unchanged_sources(self):
        self.db.execute("UPDATE sources SET updated_at='2000-01-01T00:00:00+00:00' WHERE id='all-in'")
        self.db.commit()
        pipeline.init_database(self.db, RESOURCES)
        value = self.db.execute("SELECT updated_at FROM sources WHERE id='all-in'").fetchone()[0]
        self.assertEqual(value, "2000-01-01T00:00:00+00:00")

    def test_new_database_has_no_note_taking_columns(self):
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(episodes)")}
        self.assertNotIn("note", columns)
        self.assertNotIn("is_highlighted", columns)

    def test_analysis_contract_requires_a_core_summary(self):
        schema = json.loads((RESOURCES / "analysis-schema.json").read_text(encoding="utf-8"))
        self.assertIn("coreSummary", schema["required"])
        prompt = pipeline.analysis_prompt(
            {"title": "Episode", "url": "https://example.invalid"},
            {"name": "Source", "id": "source", "profile_version": "2.0.0", "profile_prompt": "Profile"},
            "Transcript text",
        )
        self.assertIn("coreSummary", prompt)
        self.assertIn("一个自然段", prompt)

    def test_transcript_fetch_falls_back_to_ytdlp_without_asr(self):
        description = "00:00 Chapter\n" + "short " * 20
        transcript = "\n".join(
            f"[{index // 60}:{index % 60:02d}] spoken transcript sentence {index}"
            for index in range(900)
        )
        results = [
            pipeline.subprocess.CompletedProcess([], 0, description, ""),
            pipeline.subprocess.CompletedProcess([], 0, "YouTube views: 10\n\nTranscript:\n" + transcript, ""),
        ]
        with mock.patch.object(pipeline, "youtube_caption_extraction_enabled", return_value=True), \
             mock.patch.object(pipeline.Path, "exists", return_value=True), \
             mock.patch.object(pipeline.subprocess, "run", side_effect=results) as run:
            text, segments, source = pipeline.fetch_transcript({
                "url": "https://www.youtube.com/watch?v=Fallback01",
                "duration_seconds": 900,
            })
        modes = [call.args[0][call.args[0].index("--youtube") + 1] for call in run.call_args_list]
        self.assertEqual(modes, ["web", "yt-dlp"])
        self.assertEqual(source, "youtube_ytdlp")
        self.assertNotIn("YouTube views", text)
        self.assertTrue(segments)
        self.assertTrue(all(
            "--video-mode" in call.args[0] and "transcript" in call.args[0]
            for call in run.call_args_list
        ))

    def test_transcript_extraction_is_disabled_without_explicit_local_opt_in(self):
        with mock.patch.object(pipeline, "youtube_caption_extraction_enabled", return_value=False), \
             mock.patch.object(pipeline.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "默认关闭"):
                pipeline.fetch_transcript({
                    "url": "https://www.youtube.com/watch?v=ManualVid01",
                    "duration_seconds": 900,
                })
        run.assert_not_called()

    def test_discovery_is_incremental_and_idempotent(self):
        self.enable_only()
        item = {
            "id": "TestVideo01", "title": "A full episode",
            "url": "https://www.youtube.com/watch?v=TestVideo01",
            "thumbnail": "https://i.ytimg.com/vi/TestVideo01/maxresdefault.jpg",
            "published": dt.datetime.now(dt.timezone.utc).isoformat(), "description": "",
        }
        with mock.patch.object(pipeline, "parse_feed", return_value=[item]), \
             mock.patch.object(pipeline, "duration_from_page", return_value=3600):
            first = pipeline.run_update(self.update_args(), self.db, RESOURCES)
            second = pipeline.run_update(self.update_args(), self.db, RESOURCES)
        self.assertEqual(first["discovered"], 1)
        self.assertEqual(second["discovered"], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM episodes").fetchone()[0], 1)

    def test_discovery_does_not_backfill_unknown_episodes_behind_source_watermark(self):
        self.enable_only()
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,duration_seconds,status,created_at,updated_at)
               VALUES('KnownLatest1','all-in','Known latest','https://example.invalid',?,3600,'complete',?,?)""",
            (now, now, now),
        )
        self.db.commit()
        older = {
            "id": "UnknownOld1", "title": "Older unknown episode",
            "url": "https://www.youtube.com/watch?v=UnknownOld1",
            "thumbnail": "https://i.ytimg.com/vi/UnknownOld1/maxresdefault.jpg",
            "published": (pipeline.iso_date(now) - dt.timedelta(days=1)).isoformat(),
            "description": "",
        }
        with mock.patch.object(pipeline, "parse_feed", return_value=[older]), \
             mock.patch.object(pipeline, "duration_from_page") as fetch:
            result = pipeline.run_update(self.update_args(), self.db, RESOURCES)
        self.assertEqual(result["discovered"], 0)
        self.assertIsNone(self.db.execute("SELECT 1 FROM episodes WHERE id='UnknownOld1'").fetchone())
        fetch.assert_not_called()

    def test_duration_lookup_reuses_cache_and_fetches_only_unknown_items(self):
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,duration_seconds,status,created_at,updated_at)
               VALUES('CachedVideo1','all-in','Cached','https://example.invalid',?,3600,'complete',?,?)""",
            (now, now, now),
        )
        self.db.commit()
        items = [{"id": "CachedVideo1"}, {"id": "UnknownVid1"}]
        with mock.patch.object(pipeline, "duration_from_page", return_value=2400) as fetch:
            durations = pipeline.candidate_durations(self.db, items)
        self.assertEqual(durations, {"CachedVideo1": 3600, "UnknownVid1": 2400})
        fetch.assert_called_once_with("UnknownVid1")

    def test_source_fetch_failure_is_visible_in_run_counts(self):
        self.enable_only()
        with mock.patch.object(pipeline, "parse_feed", side_effect=RuntimeError("feed offline")):
            result = pipeline.run_update(self.update_args(), self.db, RESOURCES)
        self.assertEqual(result["failed"], 1)
        health = self.db.execute("SELECT health FROM sources WHERE id='all-in'").fetchone()[0]
        self.assertEqual(health, "error")

    def test_retry_failed_reprocesses_only_the_target_source(self):
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,status,created_at,updated_at)
               VALUES('RetryVideo1','all-in','Retry','https://example.invalid',?,'no_transcript',?,?)""",
            (now, now, now),
        )
        self.db.commit()
        processed = []

        def fake_process(db, episode_id, resources, analyze=True):
            processed.append(episode_id)
            return "complete"

        with mock.patch.object(pipeline, "discover", return_value=([], [])), \
             mock.patch.object(pipeline, "process_episode", side_effect=fake_process), \
             mock.patch.object(pipeline, "translate_episode", return_value=0):
            pipeline.run_update(
                self.update_args(retry_failed=True, discover_only=False), self.db, RESOURCES
            )
        self.assertEqual(processed, ["RetryVideo1"])

    def test_translation_failure_is_visible_in_run_counts(self):
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,status,created_at,updated_at)
               VALUES('TranslationFail1','all-in','Retry','https://example.invalid',?,'discovered',?,?)""",
            (now, now, now),
        )
        self.db.commit()
        with mock.patch.object(pipeline, "discover", return_value=([], [])), \
             mock.patch.object(pipeline, "process_episode", return_value="complete"), \
             mock.patch.object(pipeline, "translate_episode", side_effect=RuntimeError("translator offline")):
            result = pipeline.run_update(
                self.update_args(discover_only=False), self.db, RESOURCES
            )
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["failed"], 1)
        error = self.db.execute(
            "SELECT error FROM episodes WHERE id='TranslationFail1'"
        ).fetchone()[0]
        self.assertIn("翻译待重试", error)

    def test_processing_records_a_stable_organized_timestamp(self):
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,status,created_at,updated_at)
               VALUES('Organized01','all-in','Organized','https://example.invalid',?,'discovered',?,?)""",
            (now, now, now),
        )
        self.db.commit()
        analysis = {
            "priority": "worth_reading", "oneSentence": "Summary", "coreSummary": "Core summary", "participants": [],
            "topics": [], "keyInsights": [], "extensions": [], "evidenceLimits": [],
            "nextQuestions": [], "guestSources": [],
        }
        with mock.patch.object(pipeline, "fetch_transcript", return_value=("hello world " * 30, [("0:00", 0.0, "hello world " * 30)], "youtube_ytdlp")), \
             mock.patch.object(pipeline, "run_codex", return_value=analysis):
            status = pipeline.process_episode(self.db, "Organized01", RESOURCES)
        row = self.db.execute(
            "SELECT status,organized_at,transcript_source FROM episodes WHERE id='Organized01'"
        ).fetchone()
        self.assertEqual(status, "complete")
        self.assertEqual(row["status"], "complete")
        self.assertIsNotNone(row["organized_at"])
        self.assertEqual(row["transcript_source"], "youtube_ytdlp")

    def test_successful_translation_clears_only_translation_retry_error(self):
        now = pipeline.utc_now()
        self.db.execute(
            """INSERT INTO episodes(id,source_id,title,url,published_at,status,transcript_language,
               transcript_text,error,created_at,updated_at)
               VALUES('Translate01','all-in','Translate','https://example.invalid',?,'complete','en',
               'hello world','翻译待重试: timeout',?,?)""",
            (now, now, now),
        )
        self.db.execute(
            """INSERT INTO transcript_segments(episode_id,position,timestamp,original_text)
               VALUES('Translate01',0,'0:00','hello world')"""
        )
        self.db.commit()
        segment_id = self.db.execute(
            "SELECT id FROM transcript_segments WHERE episode_id='Translate01'"
        ).fetchone()[0]
        result = {"translations": [{"segmentId": segment_id, "translatedText": "你好，世界"}]}
        with mock.patch.object(pipeline, "run_codex", return_value=result):
            translated = pipeline.translate_episode(self.db, "Translate01", RESOURCES)
        error = self.db.execute("SELECT error FROM episodes WHERE id='Translate01'").fetchone()[0]
        self.assertEqual(translated, 1)
        self.assertIsNone(error)

    def test_manual_episode_uses_youtube_publish_date_not_import_time(self):
        url = "https://www.youtube.com/watch?v=ManualVid01"
        with mock.patch.object(pipeline, "oembed", return_value={"title": "Manual episode"}), \
             mock.patch.object(pipeline, "published_from_page", return_value="2024-02-03T00:00:00+00:00"), \
             mock.patch.object(pipeline, "duration_from_page", return_value=1800):
            result = pipeline.add_url(self.db, url, RESOURCES)
        row = self.db.execute(
            "SELECT published_at,duration_seconds FROM episodes WHERE id='ManualVid01'"
        ).fetchone()
        self.assertEqual(result["kind"], "episode")
        self.assertEqual(row["published_at"], "2024-02-03T00:00:00+00:00")
        self.assertEqual(row["duration_seconds"], 1800)

    def test_add_url_rejects_non_youtube_origins_before_network_access(self):
        rejected = [
            "file:///tmp/fake-youtube-channel.html",
            "http://www.youtube.com/@channel",
            "https://127.0.0.1/@channel",
            "https://localhost/@channel",
            "https://169.254.169.254/latest/meta-data",
            "https://10.0.0.1/@channel",
            "https://youtube.com.evil.example/watch?v=ManualVid01",
            "https://www.youtube.com@evil.example/watch?v=ManualVid01",
            "https://www.youtube.com:8443/watch?v=ManualVid01",
        ]
        with mock.patch.object(pipeline.YOUTUBE_OPENER, "open") as network:
            for url in rejected:
                with self.subTest(url=url), self.assertRaises(ValueError):
                    pipeline.add_url(self.db, url, RESOURCES)
        network.assert_not_called()

    def test_add_url_accepts_supported_youtube_video_origins(self):
        accepted = [
            "https://www.youtube.com/watch?v=ManualVid01",
            "https://youtube.com/shorts/ManualVid01",
            "https://m.youtube.com/live/ManualVid01",
            "https://youtu.be/ManualVid01",
        ]
        for url in accepted:
            with self.subTest(url=url), \
                 mock.patch.object(pipeline, "oembed", return_value={"title": "Manual episode"}), \
                 mock.patch.object(pipeline, "published_from_page", return_value="2024-02-03T00:00:00+00:00"), \
                 mock.patch.object(pipeline, "duration_from_page", return_value=1800):
                result = pipeline.add_url(self.db, url, RESOURCES)
                self.assertEqual(result, {"kind": "episode", "id": "ManualVid01"})

    def test_redirect_policy_revalidates_every_target(self):
        handler = pipeline.YouTubeRedirectHandler()
        request = pipeline.urllib.request.Request("https://www.youtube.com/@channel")
        with mock.patch.object(
            pipeline.urllib.request.HTTPRedirectHandler, "redirect_request", return_value="accepted"
        ) as parent:
            result = handler.redirect_request(
                request, None, 302, "Found", {}, "https://www.youtube.com/channel/UC12345678901234567890"
            )
            self.assertEqual(result, "accepted")
            parent.assert_called_once()
        for target in (
            "file:///tmp/redirected.html",
            "http://www.youtube.com/@channel",
            "https://127.0.0.1/internal",
            "https://youtube.com.evil.example/@channel",
        ):
            with self.subTest(target=target), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, target)

    def insert_episode(self, episode_id, status="complete", source="all-in"):
        now = pipeline.utc_now()
        self.db.execute("""INSERT INTO episodes(id,source_id,title,url,published_at,status,
                           transcript_language,transcript_text,created_at,updated_at)
                           VALUES(?,?,?,'https://example.invalid',?,?,'en','hello world',?,?)""",
                        (episode_id, source, episode_id, now, status, now, now))
        self.db.execute("""INSERT INTO transcript_segments(episode_id,position,timestamp,original_text)
                           VALUES(?,0,'0:00','hello world')""", (episode_id,))
        self.db.commit()
        return self.db.execute("SELECT id FROM transcript_segments WHERE episode_id=?", (episode_id,)).fetchone()[0]

    def test_worker_lock_blocks_cli_before_database_writes_and_releases(self):
        import subprocess
        import sys
        command = [sys.executable, str(RESOURCES / "pipeline.py"), "--db", str(self.db_path), "init"]
        with pipeline.worker_lock(self.db_path):
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 75)
            self.assertEqual(json.loads(result.stderr)["status"], "busy")
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_recovers_abandoned_run_after_acquiring_lock(self):
        import subprocess
        import sys
        self.db.execute("INSERT INTO runs(trigger,started_at,status) VALUES('test',?,'running')", (pipeline.utc_now(),))
        self.db.commit()
        result = subprocess.run([sys.executable, str(RESOURCES / "pipeline.py"), "--db", str(self.db_path), "init"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.db.execute("SELECT status,finished_at,error FROM runs").fetchone()
        self.assertEqual(row["status"], "failed")
        self.assertTrue(row["finished_at"])
        self.assertIn("退出", row["error"])

    def test_interrupted_stages_resume_and_disabled_sources_are_excluded(self):
        for episode_id, state, source in [("Fetch", "transcript_fetching", "all-in"),
                                          ("Analyze", "analyzing", "all-in"),
                                          ("Disabled", "failed", "all-in"),
                                          ("Archived", "analyzing", "all-in")]:
            self.insert_episode(episode_id, state, source)
        self.db.execute("UPDATE sources SET enabled=0 WHERE id='all-in'")
        self.db.commit()
        with mock.patch.object(pipeline, "discover", return_value=([], [])), \
             mock.patch.object(pipeline, "process_episode", return_value="no_transcript") as process:
            pipeline.run_update(self.update_args(discover_only=False, retry_failed=True), self.db, RESOURCES)
            process.assert_not_called()
            self.db.execute("UPDATE sources SET enabled=1 WHERE id='all-in'")
            self.db.commit()
            pipeline.run_update(self.update_args(discover_only=False), self.db, RESOURCES)
            self.assertEqual({call.args[1] for call in process.call_args_list}, {"Fetch", "Analyze", "Archived"})
            process.reset_mock()
            self.db.execute("UPDATE sources SET archived=1 WHERE id='all-in'")
            self.db.commit()
            pipeline.run_update(self.update_args(discover_only=False, retry_failed=True), self.db, RESOURCES)
            process.assert_not_called()

    def test_manual_update_repairs_old_translation_before_receipt_completes(self):
        segment_id = self.insert_episode("OldTranslation")
        def translate(*args, **kwargs):
            self.assertEqual(self.db.execute("SELECT status FROM runs ORDER BY id DESC LIMIT 1").fetchone()[0], "running")
            return {"translations": [{"segmentId": segment_id, "translatedText": "你好"}]}
        with mock.patch.object(pipeline, "discover", return_value=([], [])), \
             mock.patch.object(pipeline, "process_episode") as process, \
             mock.patch.object(pipeline, "run_codex", side_effect=translate):
            result = pipeline.run_update(self.update_args(discover_only=False), self.db, RESOURCES)
        process.assert_not_called()
        self.assertEqual(result["failed"], 0)
        self.assertEqual(self.db.execute("SELECT translated_text FROM transcript_segments").fetchone()[0], "你好")

    def test_translation_batches_reject_duplicate_missing_foreign_and_blank_ids_atomically(self):
        segment_id = self.insert_episode("Malformed")
        good = {"segmentId": segment_id, "translatedText": "你好"}
        invalid = [[good, good], [], [good, {"segmentId": segment_id+100, "translatedText": "外来"}],
                   [{"segmentId": segment_id, "translatedText": "  "}],
                   [{"segmentId": segment_id, "translatedText": 42}]]
        for translations in invalid:
            with self.subTest(translations=translations), \
                 mock.patch.object(pipeline, "run_codex", return_value={"translations": translations}):
                with self.assertRaises(RuntimeError):
                    pipeline.translate_episode(self.db, "Malformed", RESOURCES)
                self.assertIsNone(self.db.execute("SELECT translated_text FROM transcript_segments").fetchone()[0])

    def test_blank_cached_translation_is_repaired(self):
        segment_id = self.insert_episode("Blank")
        self.db.execute("UPDATE transcript_segments SET translated_text='  '")
        self.db.commit()
        with mock.patch.object(pipeline, "run_codex", return_value={"translations": [{"segmentId": segment_id, "translatedText": "你好"}]}):
            self.assertEqual(pipeline.translate_episode(self.db, "Blank", RESOURCES), 1)

    def test_backlog_failure_is_recorded_and_not_reported_as_success(self):
        self.insert_episode("OldFailure")
        with mock.patch.object(pipeline, "discover", return_value=([], [])), \
             mock.patch.object(pipeline, "run_codex", side_effect=RuntimeError("offline")):
            result = pipeline.run_update(self.update_args(discover_only=False), self.db, RESOURCES)
        self.assertEqual(result["failed"], 1)
        self.assertIn("翻译待重试", self.db.execute("SELECT error FROM episodes").fetchone()[0])
        with mock.patch.object(pipeline, "run_update", return_value=result), mock.patch("builtins.print"):
            self.assertEqual(pipeline.dispatch(self.update_args(command="update", resources=RESOURCES), self.db), 1)

    def test_source_profile_failure_survives_successful_discovery(self):
        self.enable_only()
        self.db.execute("UPDATE sources SET health='profile_pending',last_error='profile offline' WHERE id='all-in'")
        self.db.commit()
        with mock.patch.object(pipeline, "parse_feed", return_value=[]):
            pipeline.run_update(self.update_args(), self.db, RESOURCES)
        source = self.db.execute("SELECT health,last_error FROM sources WHERE id='all-in'").fetchone()
        self.assertEqual(source["health"], "profile_pending")
        self.assertEqual(source["last_error"], "profile offline")

    def test_incremental_batch_limit_does_not_skip_remaining_new_episodes(self):
        self.enable_only()
        self.insert_episode("Watermark")
        base = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=10)
        self.db.execute("UPDATE episodes SET published_at=? WHERE id='Watermark'", (base.isoformat(),))
        self.db.commit()
        items = [{"id": f"NewVideo{i:03}", "title": f"Episode {i}", "url": "https://example.invalid",
                  "thumbnail": "", "description": "", "published": (base + dt.timedelta(days=i)).isoformat()}
                 for i in range(6, 0, -1)]
        with mock.patch.object(pipeline, "parse_feed", return_value=items), \
             mock.patch.object(pipeline, "duration_from_page", return_value=3600):
            first = pipeline.run_update(self.update_args(per_source=5), self.db, RESOURCES)
            second = pipeline.run_update(self.update_args(per_source=5), self.db, RESOURCES)
        self.assertEqual(first["discovered"], 5)
        self.assertEqual(second["discovered"], 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM episodes").fetchone()[0], 7)

    def test_same_publish_timestamp_does_not_hide_an_unseen_episode(self):
        self.enable_only()
        self.insert_episode("SameSecond")
        published = self.db.execute("SELECT published_at FROM episodes").fetchone()[0]
        item = {"id": "NewSameTime", "title": "Same second", "url": "https://example.invalid",
                "thumbnail": "", "description": "", "published": published}
        with mock.patch.object(pipeline, "parse_feed", return_value=[item]), \
             mock.patch.object(pipeline, "duration_from_page", return_value=3600):
            self.assertEqual(pipeline.run_update(self.update_args(), self.db, RESOURCES)["discovered"], 1)
            self.assertEqual(pipeline.run_update(self.update_args(), self.db, RESOURCES)["discovered"], 0)

    def test_profile_retry_survives_a_feed_failure(self):
        self.enable_only()
        self.db.execute("UPDATE sources SET health='profile_pending' WHERE id='all-in'")
        self.db.commit()
        with mock.patch.object(pipeline, "parse_feed", side_effect=RuntimeError("feed offline")):
            result = pipeline.run_update(self.update_args(), self.db, RESOURCES)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(self.db.execute("SELECT health FROM sources WHERE id='all-in'").fetchone()[0], "profile_pending")


if __name__ == "__main__":
    unittest.main()
