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
        with mock.patch.object(pipeline, "fetch_transcript", return_value=("hello world " * 30, [("0:00", 0.0, "hello world " * 30)])), \
             mock.patch.object(pipeline, "run_codex", return_value=analysis):
            status = pipeline.process_episode(self.db, "Organized01", RESOURCES)
        row = self.db.execute(
            "SELECT status,organized_at FROM episodes WHERE id='Organized01'"
        ).fetchone()
        self.assertEqual(status, "complete")
        self.assertEqual(row["status"], "complete")
        self.assertIsNotNone(row["organized_at"])

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


if __name__ == "__main__":
    unittest.main()
