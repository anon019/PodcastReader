#!/usr/bin/env python3
"""Independent Podcast Reader pipeline. It never imports or reads Hermes runtime data."""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Iterable

APP_ID = "com.sota.PodcastNotes"
USER_AGENT = "PodcastReader/0.4 (personal macOS reader)"
YOUTUBE_VIDEO_RE = re.compile(r"(?:youtu\.be/|youtube\.com/(?:watch\?.*?v=|shorts/|live/))([A-Za-z0-9_-]{11})")
TIMESTAMP_RE = re.compile(r"^\s*\[(?P<time>\d{1,2}:\d{2}(?::\d{2})?)\]\s*(?P<text>.*)$")
ANALYSIS_STYLE_VERSION = "editorial-2.1"


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def default_db_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "PodcastNotes" / "podcast_notes.sqlite3"


def http_get(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.8"})
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as exc:
            last_error = exc
            if isinstance(exc, urllib.error.HTTPError) and exc.code not in {408, 429, 500, 502, 503, 504}:
                raise
            if attempt < 2:
                time.sleep(1.5 * (attempt + 1))
    assert last_error is not None
    raise last_error


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=30000")
    return db


SCHEMA = """
CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  handle TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'channel',
  external_id TEXT NOT NULL DEFAULT '',
  feed_url TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '未分类',
  min_duration INTEGER NOT NULL DEFAULT 0,
  profile_version TEXT NOT NULL DEFAULT '1.0.0',
  profile_prompt TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  archived INTEGER NOT NULL DEFAULT 0,
  last_checked_at TEXT,
  health TEXT NOT NULL DEFAULT 'new',
  last_error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS episodes (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  thumbnail_url TEXT NOT NULL DEFAULT '',
  published_at TEXT NOT NULL,
  duration_seconds INTEGER,
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'discovered',
  transcript_language TEXT,
  transcript_source TEXT,
  transcript_text TEXT,
  transcript_hash TEXT,
  transcript_error TEXT,
  analysis_json TEXT,
  analysis_profile_version TEXT,
  organized_at TEXT,
  model TEXT,
  is_read INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS episodes_published_idx ON episodes(published_at DESC);
CREATE INDEX IF NOT EXISTS episodes_status_idx ON episodes(status, published_at DESC);
CREATE INDEX IF NOT EXISTS episodes_source_published_idx ON episodes(source_id, published_at DESC);
CREATE TABLE IF NOT EXISTS transcript_segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  timestamp TEXT NOT NULL DEFAULT '',
  start_seconds REAL,
  original_text TEXT NOT NULL,
  translated_text TEXT,
  UNIQUE(episode_id, position)
);
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trigger TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  status TEXT NOT NULL,
  discovered_count INTEGER NOT NULL DEFAULT 0,
  completed_count INTEGER NOT NULL DEFAULT 0,
  no_transcript_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  current_detail TEXT,
  error TEXT
);
"""


def init_database(db: sqlite3.Connection, resources: Path) -> None:
    db.executescript(SCHEMA)
    source_columns = {row[1] for row in db.execute("PRAGMA table_info(sources)")}
    if "archived" not in source_columns:
        db.execute("ALTER TABLE sources ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
    episode_columns = {row[1] for row in db.execute("PRAGMA table_info(episodes)")}
    if "organized_at" not in episode_columns:
        db.execute("ALTER TABLE episodes ADD COLUMN organized_at TEXT")
        # Historical rows predate the dedicated field. Their last completed
        # local write is the best available one-time migration receipt.
        db.execute("""UPDATE episodes SET organized_at=updated_at
                      WHERE status='complete' AND analysis_json IS NOT NULL""")
    seed_path = resources / "seed_sources.json"
    seeds = json.loads(seed_path.read_text(encoding="utf-8"))
    now = utc_now()
    for item in seeds:
        feed = f"https://www.youtube.com/feeds/videos.xml?channel_id={item['channelId']}"
        db.execute(
            """INSERT INTO sources
               (id,name,handle,kind,external_id,feed_url,category,min_duration,profile_version,profile_prompt,created_at,updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 name=excluded.name, handle=excluded.handle, category=excluded.category,
                 min_duration=excluded.min_duration, profile_version=excluded.profile_version,
                 profile_prompt=excluded.profile_prompt, updated_at=excluded.updated_at
               WHERE name!=excluded.name OR handle!=excluded.handle OR category!=excluded.category
                  OR min_duration!=excluded.min_duration OR profile_version!=excluded.profile_version
                  OR profile_prompt!=excluded.profile_prompt""",
            (item["id"], item["name"], item["handle"], "channel", item["channelId"], feed,
             item["category"], item["minDuration"], item["profileVersion"], item["profile"], now, now),
        )
    db.commit()


def iso_date(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def duration_from_page(video_id: str) -> int | None:
    try:
        page = http_get(f"https://www.youtube.com/watch?v={video_id}", 20).decode("utf-8", "ignore")
    except Exception:
        return None
    match = re.search(r'"lengthSeconds":"(\d+)"', page)
    return int(match.group(1)) if match else None


def candidate_durations(db: sqlite3.Connection, items: list[dict[str, Any]]) -> dict[str, int | None]:
    """Reuse cached durations and fetch only unknown candidates with bounded concurrency."""
    durations: dict[str, int | None] = {}
    missing: list[str] = []
    for item in items:
        row = db.execute("SELECT duration_seconds FROM episodes WHERE id=?", (item["id"],)).fetchone()
        if row:
            durations[item["id"]] = row["duration_seconds"]
        else:
            missing.append(item["id"])
    if missing:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(missing))) as executor:
            durations.update(zip(missing, executor.map(duration_from_page, missing), strict=True))
    return durations


def published_from_page(video_id: str) -> str | None:
    try:
        page = http_get(f"https://www.youtube.com/watch?v={video_id}", 20).decode("utf-8", "ignore")
    except Exception:
        return None
    match = re.search(r'"(?:publishDate|uploadDate)":"(\d{4}-\d{2}-\d{2})"', page)
    return f"{match.group(1)}T00:00:00+00:00" if match else None


def parse_channel_video_page(source: sqlite3.Row, limit: int = 60) -> list[dict[str, Any]]:
    """Read the channel Videos tab when the 15-item Atom feed is all clips."""
    channel_id = source["external_id"]
    if not channel_id:
        return []
    page = http_get(f"https://www.youtube.com/channel/{channel_id}/videos", 30).decode("utf-8", "ignore")
    marker = "var ytInitialData = "
    start = page.find(marker)
    if start < 0:
        return []
    try:
        payload, _ = json.JSONDecoder().raw_decode(page[start + len(marker):])
    except json.JSONDecodeError:
        return []
    found: list[dict[str, Any]] = []
    seen: set[str] = set()

    def text_value(value: Any) -> str:
        if not isinstance(value, dict):
            return ""
        if isinstance(value.get("simpleText"), str):
            return value["simpleText"]
        return "".join(run.get("text", "") for run in value.get("runs", []) if isinstance(run, dict))

    def walk(value: Any) -> None:
        if len(found) >= limit:
            return
        if isinstance(value, dict):
            video_id = value.get("videoId")
            title = text_value(value.get("title"))
            if isinstance(video_id, str) and len(video_id) == 11 and video_id not in seen:
                seen.add(video_id)
                found.append({
                    "id": video_id,
                    "title": title or video_id,
                    "url": f"https://www.youtube.com/watch?v={video_id}",
                    "thumbnail": f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg",
                    "published": "",
                    "description": "",
                })
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(payload)
    return found


def parse_feed(source: sqlite3.Row, lookback_days: int, limit: int) -> list[dict[str, Any]]:
    data = http_get(source["feed_url"], 30)
    root = ET.fromstring(data)
    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "yt": "http://www.youtube.com/xml/schemas/2015",
        "media": "http://search.yahoo.com/mrss/",
    }
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=lookback_days)
    items: list[dict[str, Any]] = []
    for entry in root.findall("atom:entry", ns):
        video_id = (entry.findtext("yt:videoId", default="", namespaces=ns) or "").strip()
        title = (entry.findtext("atom:title", default="", namespaces=ns) or "").strip()
        published = (entry.findtext("atom:published", default="", namespaces=ns) or "").strip()
        description = (entry.findtext("media:group/media:description", default="", namespaces=ns) or "").strip()
        if not video_id or not title or not published:
            continue
        if iso_date(published) < cutoff:
            continue
        items.append({
            "id": video_id,
            "title": title,
            "url": f"https://www.youtube.com/watch?v={video_id}",
            "thumbnail": f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg",
            "published": published,
            "description": description,
        })
        if len(items) >= limit:
            break
    return items


def discover(
    db: sqlite3.Connection, lookback_days: int, per_source: int, run_id: int,
    source_ids: set[str] | None = None,
) -> tuple[list[str], list[str]]:
    new_ids: list[str] = []
    failures: list[str] = []
    if source_ids:
        placeholders = ",".join("?" for _ in source_ids)
        sources = db.execute(
            f"""SELECT * FROM sources WHERE enabled=1 AND archived=0 AND kind!='manual'
                AND id IN ({placeholders}) ORDER BY name""",
            tuple(source_ids),
        ).fetchall()
    else:
        sources = db.execute(
            "SELECT * FROM sources WHERE enabled=1 AND archived=0 AND kind!='manual' ORDER BY name"
        ).fetchall()
    for index, source in enumerate(sources, start=1):
        detail = f"正在检查 {index}/{len(sources)} · {source['name']}"
        db.execute("UPDATE runs SET current_detail=? WHERE id=?", (detail, run_id))
        db.commit()
        try:
            qualified_seen = 0
            inserted_for_source = 0
            watermark_row = db.execute(
                "SELECT max(published_at) FROM episodes WHERE source_id=?", (source["id"],)
            ).fetchone()
            watermark = iso_date(watermark_row[0]) if watermark_row and watermark_row[0] else None
            candidates = parse_feed(source, lookback_days, max(15, per_source))
            recent_candidates = [
                item for item in candidates
                if watermark is None or iso_date(item["published"]) > watermark
            ]
            durations = candidate_durations(db, recent_candidates)
            for item in recent_candidates:
                existing = db.execute("SELECT 1 FROM episodes WHERE id=?", (item["id"],)).fetchone()
                duration = durations[item["id"]]
                if duration is not None and duration < source["min_duration"]:
                    continue
                qualified_seen += 1
                if existing:
                    continue
                now = utc_now()
                db.execute(
                    """INSERT INTO episodes
                       (id,source_id,title,url,thumbnail_url,published_at,duration_seconds,description,status,created_at,updated_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                    (item["id"], source["id"], item["title"], item["url"], item["thumbnail"],
                     item["published"], duration, item["description"], "discovered", now, now),
                )
                new_ids.append(item["id"])
                inserted_for_source += 1
                if inserted_for_source >= per_source:
                    break
            # Some channels publish enough Shorts to push the newest full
            # episode outside YouTube's 15-item Atom feed. In that case inspect
            # the Videos tab once; this still runs only during a one-shot update.
            if recent_candidates and qualified_seen == 0 and source["kind"] == "channel":
                for item in parse_channel_video_page(source, 60):
                    existing = db.execute("SELECT duration_seconds FROM episodes WHERE id=?", (item["id"],)).fetchone()
                    duration = existing["duration_seconds"] if existing else duration_from_page(item["id"])
                    if duration is not None and duration < source["min_duration"]:
                        continue
                    if existing:
                        break
                    if item["title"] == item["id"]:
                        with contextlib.suppress(Exception):
                            item["title"] = oembed(item["url"]).get("title", item["id"])
                    item["published"] = published_from_page(item["id"]) or utc_now()
                    if watermark is not None and iso_date(item["published"]) <= watermark:
                        break
                    now = utc_now()
                    db.execute(
                        """INSERT INTO episodes
                           (id,source_id,title,url,thumbnail_url,published_at,duration_seconds,description,status,created_at,updated_at)
                           VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                        (item["id"], source["id"], item["title"], item["url"], item["thumbnail"],
                         item["published"], duration, item["description"], "discovered", now, now),
                    )
                    new_ids.append(item["id"])
                    break
            db.execute("UPDATE sources SET last_checked_at=?,health='healthy',last_error=NULL,updated_at=? WHERE id=?", (utc_now(), utc_now(), source["id"]))
        except Exception as exc:
            failures.append(source["id"])
            db.execute("UPDATE sources SET last_checked_at=?,health='error',last_error=?,updated_at=? WHERE id=?", (utc_now(), str(exc)[:1000], utc_now(), source["id"]))
        db.commit()
    return new_ids, failures


def discover_latest_each_source(
    db: sqlite3.Connection, feed_limit: int = 15, source_ids: set[str] | None = None,
    skip_unavailable: bool = False,
) -> dict[str, Any]:
    """Select the newest full episode allowed by each source profile."""
    started = utc_now()
    run_id = db.execute(
        "INSERT INTO runs(trigger,started_at,status,current_detail) VALUES(?,?,?,?)",
        ("latest_21_backfill", started, "running", "准备选取每个来源的最新一期"),
    ).lastrowid
    db.commit()
    if source_ids:
        placeholders = ",".join("?" for _ in source_ids)
        sources = db.execute(
            f"SELECT * FROM sources WHERE enabled=1 AND archived=0 AND kind='channel' AND id IN ({placeholders}) ORDER BY name",
            tuple(source_ids),
        ).fetchall()
    else:
        sources = db.execute(
            "SELECT * FROM sources WHERE enabled=1 AND archived=0 AND kind='channel' ORDER BY name"
        ).fetchall()
    targets: list[dict[str, str]] = []
    failures: list[dict[str, str]] = []
    inserted = 0
    for index, source in enumerate(sources, start=1):
        db.execute(
            "UPDATE runs SET current_detail=? WHERE id=?",
            (f"正在选取 {index}/{len(sources)} · {source['name']}", run_id),
        )
        db.commit()
        try:
            candidates = parse_feed(source, 3650, feed_limit)
            selected: tuple[dict[str, Any], int | None] | None = None
            for item in candidates:
                if skip_unavailable and db.execute(
                    """SELECT 1 FROM episodes WHERE id=? AND transcript_text IS NULL
                       AND (status='no_transcript' OR transcript_error IS NOT NULL)""",
                    (item["id"],),
                ).fetchone():
                    continue
                duration = duration_from_page(item["id"])
                if duration is not None and duration < source["min_duration"]:
                    continue
                selected = (item, duration)
                break
            if selected is None:
                for item in parse_channel_video_page(source, 60):
                    if skip_unavailable and db.execute(
                        """SELECT 1 FROM episodes WHERE id=? AND transcript_text IS NULL
                           AND (status='no_transcript' OR transcript_error IS NOT NULL)""",
                        (item["id"],),
                    ).fetchone():
                        continue
                    duration = duration_from_page(item["id"])
                    if duration is not None and duration < source["min_duration"]:
                        continue
                    if item["title"] == item["id"]:
                        with contextlib.suppress(Exception):
                            item["title"] = oembed(item["url"]).get("title", item["id"])
                    item["published"] = published_from_page(item["id"]) or utc_now()
                    selected = (item, duration)
                    break
            if selected is None:
                raise RuntimeError("Atom Feed 与频道 Videos 页都没有符合本节目 Profile 的完整内容")
            item, duration = selected
            existed = db.execute("SELECT 1 FROM episodes WHERE id=?", (item["id"],)).fetchone() is not None
            now = utc_now()
            db.execute(
                """INSERT INTO episodes
                   (id,source_id,title,url,thumbnail_url,published_at,duration_seconds,description,status,created_at,updated_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(id) DO UPDATE SET
                     source_id=excluded.source_id,title=excluded.title,url=excluded.url,
                     thumbnail_url=excluded.thumbnail_url,published_at=excluded.published_at,
                     duration_seconds=COALESCE(excluded.duration_seconds,episodes.duration_seconds),
                     description=excluded.description,updated_at=excluded.updated_at""",
                (item["id"], source["id"], item["title"], item["url"], item["thumbnail"],
                 item["published"], duration, item["description"], "discovered", now, now),
            )
            if not existed:
                inserted += 1
            targets.append({"sourceId": source["id"], "sourceName": source["name"], "episodeId": item["id"], "title": item["title"]})
            db.execute(
                "UPDATE sources SET last_checked_at=?,health='healthy',last_error=NULL,updated_at=? WHERE id=?",
                (now, now, source["id"]),
            )
        except Exception as exc:
            message = str(exc)[:1000]
            failures.append({"sourceId": source["id"], "sourceName": source["name"], "error": message})
            db.execute(
                "UPDATE sources SET last_checked_at=?,health='error',last_error=?,updated_at=? WHERE id=?",
                (utc_now(), message, utc_now(), source["id"]),
            )
        db.commit()
    status = "complete" if not failures else "partial"
    db.execute(
        """UPDATE runs SET finished_at=?,status=?,discovered_count=?,failed_count=?,current_detail=? WHERE id=?""",
        (utc_now(), status, inserted, len(failures),
         f"已选取 {len(targets)}/{len(sources)} 个来源的最新一期", run_id),
    )
    db.commit()
    return {"runId": run_id, "sourceCount": len(sources), "inserted": inserted, "targets": targets, "failures": failures}


def timestamp_seconds(value: str) -> float | None:
    try:
        parts = [float(part) for part in value.split(":")]
        if len(parts) == 2:
            return parts[0] * 60 + parts[1]
        if len(parts) == 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
    except ValueError:
        return None
    return None


def parse_transcript(text: str) -> list[tuple[str, float | None, str]]:
    segments: list[tuple[str, float | None, str]] = []
    current_time = ""
    current_lines: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.lower() == "transcript:":
            continue
        match = TIMESTAMP_RE.match(line)
        if match:
            if current_lines:
                segments.append((current_time, timestamp_seconds(current_time), " ".join(current_lines)))
            current_time = match.group("time")
            current_lines = [match.group("text")] if match.group("text") else []
        elif current_lines:
            current_lines.append(line)
        else:
            current_lines = [line]
    if current_lines:
        segments.append((current_time, timestamp_seconds(current_time), " ".join(current_lines)))
    raw_segments = [item for item in segments if item[2].strip()]

    # YouTube auto captions are often only a few words long. Merge them into
    # stable reading/translation units so the UI is readable and translation
    # does not require dozens of model calls for one episode.
    merged: list[tuple[str, float | None, str]] = []
    for stamp, seconds, segment_text in raw_segments:
        if not merged:
            merged.append((stamp, seconds, segment_text))
            continue
        previous_stamp, previous_seconds, previous_text = merged[-1]
        elapsed = (seconds - previous_seconds) if seconds is not None and previous_seconds is not None else 999
        if len(previous_text) < 520 and elapsed <= 35:
            merged[-1] = (previous_stamp, previous_seconds, previous_text + " " + segment_text)
        else:
            merged.append((stamp, seconds, segment_text))
    return merged


def transcript_language(text: str) -> str:
    sample = text[:20000]
    visible = max(1, sum(1 for char in sample if not char.isspace()))
    cjk = sum(1 for char in sample if "\u3400" <= char <= "\u9fff")
    return "zh" if cjk / visible >= 0.12 else "en"


def fetch_transcript(episode: sqlite3.Row) -> tuple[str, list[tuple[str, float | None, str]]]:
    summarize = Path("/opt/homebrew/bin/summarize")
    if not summarize.exists():
        raise RuntimeError("未找到 /opt/homebrew/bin/summarize")
    command = [str(summarize), episode["url"], "--youtube", "web", "--video-mode", "transcript",
               "--extract", "--timestamps", "--plain", "--no-color", "--metrics", "off", "--timeout", "90s"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    transcript = result.stdout.strip()
    duration = episode["duration_seconds"] or 0
    # The YouTube web fallback sometimes returns the video description and a
    # chapter outline as if it were a transcript. For long-form content, require
    # enough text density to represent actual speech rather than metadata.
    minimum_chars = max(240, int(duration * 0.8))
    looks_like_description = duration >= 900 and len(transcript) < minimum_chars
    if result.returncode != 0 or len(transcript) < 240 or looks_like_description:
        receipt = (result.stderr or result.stdout or "YouTube 未返回可用字幕轨").strip()
        if looks_like_description:
            receipt = f"YouTube 只返回了 {len(transcript)} 字的简介/章节，低于 {duration} 秒节目所需的完整字幕门槛"
        raise RuntimeError(receipt[-2000:])
    segments = parse_transcript(transcript)
    if not segments:
        segments = [("", None, transcript)]
    return transcript, segments


def analysis_prompt(episode: sqlite3.Row, source: sqlite3.Row, transcript: str) -> str:
    return f"""你是 Podcast Reader 的内容分析员。请对以下单集生成严格符合 JSON Schema 的中文结果。

必须遵守：
1. Transcript 是本期观点的唯一主证据。不得用记忆补写本期没有表达的内容。
2. 识别主持人、共同主持人与嘉宾；搜索公开网页核验其当前背景、机构和与本期主题的关系，并在 participants 与 guestSources 中保留核验状态和 URL。外部资料不得成为本期观点证据。
3. 先按语义重组 topics 话题地图，再提炼 keyInsights；不要按聊天时间线流水账摘要，也不要省略改变结论的限定条件。
4. 区分事实、嘉宾判断、主持人判断和你的推断；每个关键观点给出最接近的时间戳、speaker 和置信度。
5. 搜索不到、身份无法消歧或字幕过短时明确写 unknown，不得猜测。
6. 提炼本期真正新增、可迁移、可验证的内容，列出反方解释、证据限制和下一验证问题。
7. 去掉广告、寒暄、重复表达和空泛励志内容；不给出未经请求的投资建议。
8. 按成熟媒体编辑稿的方式写作，语言自然、直接、可连续阅读。禁止在 topics、keyPoints、keyInsights 的正文中反复使用“字幕转述：”“字幕事实：”“主持人判断：”“主持人同时限定：”“嘉宾判断：”“我的归纳：”“反方解释：”“关键限定：”或方括号证据标签。事实与观点的边界通过 speaker、confidence、时间戳以及独立的 evidenceLimits 表达，不要把分类标签写进每句话。
9. 合并重复论述。每个 topic 的 keyPoints 保留 3–6 条真正改变理解的内容；一句只表达一个完整意思，优先写结论、数字、条件和影响，不写分析过程的自我说明。
10. oneSentence 只写一句最核心的判断。coreSummary 紧随其后，用一个自然段高度凝练整期内容，覆盖主要问题、关键结论、重要分歧或限制以及为何值得关注；不要使用项目符号、小标题、分析过程标签，也不要简单重复 oneSentence。

来源：{source['name']}
标题：{episode['title']}
官方链接：{episode['url']}
Profile：{source['id']}/v{source['profile_version']}
来源专属分析合同：{source['profile_prompt']}

TRANSCRIPT BEGIN
{transcript}
TRANSCRIPT END
"""


def run_codex(prompt: str, resources: Path, schema_name: str, timeout: int = 900) -> dict[str, Any]:
    codex = Path("/opt/homebrew/bin/codex")
    if not codex.exists():
        raise RuntimeError("未找到 /opt/homebrew/bin/codex")
    schema = resources / schema_name
    with tempfile.NamedTemporaryFile(prefix="podcast-reader-", suffix=".json", delete=False) as handle:
        output_path = Path(handle.name)
    try:
        command = [str(codex), "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                   "-m", "gpt-5.6-luna", "--output-schema", str(schema), "-o", str(output_path),
                   "-C", str(resources), "-"]
        result = subprocess.run(command, input=prompt, capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout or "Codex failed")[-4000:])
        raw = output_path.read_text(encoding="utf-8").strip()
        return json.loads(raw)
    finally:
        with contextlib.suppress(FileNotFoundError):
            output_path.unlink()


def source_profile_prompt(source: sqlite3.Row, description: str, recent_titles: list[str]) -> str:
    return f"""你要为一个新加入的 Podcast／YouTube 节目自动生成长期使用的中文提炼 Profile。

这是后台配置，用户不会编辑。请根据节目官方信息和最近标题自行完成定位，不要要求用户选择模板。

输出要求：
1. category 使用简洁中文分类。
2. minDuration 用来过滤 Shorts、预告和切片；若节目本身以短篇报道为主可设为 0。
3. profileVersion 使用 auto-1.0.0。
4. profilePrompt 必须是 200 至 1200 字的可执行合同，写清：节目定位、常见主持人或形式、每期先核验哪些参与者背景、应优先恢复的结构、必须保留的数字或证据、需要警惕的偏差，以及什么内容应降权。不要包含通用空话。

节目名称：{source['name']}
YouTube handle：{source['handle']}
官方描述：{description or '未取得'}
最近标题：{json.dumps(recent_titles, ensure_ascii=False)}
"""


def channel_description(source: sqlite3.Row) -> str:
    external_id = source["external_id"]
    if not external_id:
        return ""
    try:
        page = http_get(f"https://www.youtube.com/channel/{external_id}/about", 30).decode("utf-8", "ignore")
        match = re.search(r'"description":"((?:\\.|[^"\\])*)"', page)
        if not match:
            return ""
        return json.loads('"' + match.group(1) + '"')[:5000]
    except Exception:
        return ""


def auto_profile_source(db: sqlite3.Connection, source_id: str, resources: Path) -> dict[str, Any]:
    source = db.execute("SELECT * FROM sources WHERE id=?", (source_id,)).fetchone()
    if not source:
        raise KeyError(source_id)
    try:
        titles = [item["title"] for item in parse_feed(source, 3650, 10)] if source["feed_url"] else []
        result = run_codex(
            source_profile_prompt(source, channel_description(source), titles),
            resources,
            "profile-schema.json",
            timeout=600,
        )
        now = utc_now()
        db.execute(
            """UPDATE sources SET category=?,min_duration=?,profile_version=?,profile_prompt=?,
               health='healthy',last_error=NULL,updated_at=? WHERE id=?""",
            (result["category"], int(result["minDuration"]), result["profileVersion"],
             result["profilePrompt"], now, source_id),
        )
        db.commit()
        return {"status": "complete", **result}
    except Exception as exc:
        db.execute(
            "UPDATE sources SET health='profile_pending',last_error=?,updated_at=? WHERE id=?",
            (str(exc)[:1000], utc_now(), source_id),
        )
        db.commit()
        return {"status": "pending", "error": str(exc)[:1000]}


def process_episode(db: sqlite3.Connection, episode_id: str, resources: Path, analyze: bool = True) -> str:
    episode = db.execute("SELECT * FROM episodes WHERE id=?", (episode_id,)).fetchone()
    if not episode:
        raise KeyError(episode_id)
    source = db.execute("SELECT * FROM sources WHERE id=?", (episode["source_id"],)).fetchone()
    try:
        if not episode["transcript_text"]:
            db.execute("UPDATE episodes SET status='transcript_fetching',error=NULL,updated_at=? WHERE id=?", (utc_now(), episode_id))
            db.commit()
            transcript, segments = fetch_transcript(episode)
            digest = hashlib.sha256(transcript.encode("utf-8")).hexdigest()
            db.execute("DELETE FROM transcript_segments WHERE episode_id=?", (episode_id,))
            for position, (stamp, seconds, text) in enumerate(segments):
                db.execute("INSERT INTO transcript_segments(episode_id,position,timestamp,start_seconds,original_text) VALUES(?,?,?,?,?)",
                           (episode_id, position, stamp, seconds, text))
            language = transcript_language(transcript)
            db.execute("""UPDATE episodes SET transcript_text=?,transcript_hash=?,transcript_source='youtube_web',
                          transcript_language=?,transcript_error=NULL,status='transcript_ready',updated_at=? WHERE id=?""",
                       (transcript, digest, language, utc_now(), episode_id))
            db.commit()
        if not analyze:
            return "transcript_ready"
        episode = db.execute("SELECT * FROM episodes WHERE id=?", (episode_id,)).fetchone()
        db.execute("UPDATE episodes SET status='analyzing',error=NULL,updated_at=? WHERE id=?", (utc_now(), episode_id))
        db.commit()
        analysis = run_codex(analysis_prompt(episode, source, episode["transcript_text"]), resources, "analysis-schema.json")
        organized_at = utc_now()
        db.execute("""UPDATE episodes SET status='complete',analysis_json=?,analysis_profile_version=?,organized_at=?,model='gpt-5.6-luna',
                      error=NULL,updated_at=? WHERE id=?""",
                   (json.dumps(analysis, ensure_ascii=False),
                    f"{source['profile_version']}+{ANALYSIS_STYLE_VERSION}", organized_at, organized_at, episode_id))
        db.commit()
        return "complete"
    except Exception as exc:
        message = str(exc)[:4000]
        current = db.execute("SELECT status FROM episodes WHERE id=?", (episode_id,)).fetchone()[0]
        if current == "transcript_fetching":
            db.execute("UPDATE episodes SET status='no_transcript',transcript_error=?,error=NULL,updated_at=? WHERE id=?", (message, utc_now(), episode_id))
            db.commit()
            return "no_transcript"
        db.execute("UPDATE episodes SET status='failed',error=?,updated_at=? WHERE id=?", (message, utc_now(), episode_id))
        db.commit()
        return "failed"


def translation_prompt(rows: Iterable[sqlite3.Row]) -> str:
    payload = [{"segmentId": row["id"], "timestamp": row["timestamp"], "text": row["original_text"]} for row in rows]
    return """把下面 Podcast Transcript 逐段翻译成简体中文，并严格返回 schema 指定的 JSON。
要求：保留技术术语、公司名、人名和数字；不总结、不省略、不添加解释；segmentId 必须原样返回。

""" + json.dumps(payload, ensure_ascii=False)


def translate_episode(db: sqlite3.Connection, episode_id: str, resources: Path) -> int:
    episode = db.execute("SELECT transcript_language,transcript_text FROM episodes WHERE id=?", (episode_id,)).fetchone()
    if not episode or not episode["transcript_text"]:
        return 0
    if episode["transcript_language"] == "zh" or transcript_language(episode["transcript_text"]) == "zh":
        cursor = db.execute(
            """UPDATE transcript_segments SET translated_text=original_text
               WHERE episode_id=? AND translated_text IS NULL""", (episode_id,)
        )
        db.execute("UPDATE episodes SET transcript_language='zh',updated_at=? WHERE id=?", (utc_now(), episode_id))
        db.execute("""UPDATE episodes SET error=NULL WHERE id=? AND error LIKE '翻译待重试:%'""", (episode_id,))
        db.commit()
        return cursor.rowcount
    count = 0
    while True:
        pending = db.execute("""SELECT * FROM transcript_segments WHERE episode_id=? AND translated_text IS NULL
                              ORDER BY position LIMIT 40""", (episode_id,)).fetchall()
        if not pending:
            break
        expected_ids = {row["id"] for row in pending}
        result = run_codex(translation_prompt(pending), resources, "translation-schema.json", timeout=900)
        progressed = 0
        for item in result.get("translations", []):
            if item.get("segmentId") not in expected_ids or not item.get("translatedText", "").strip():
                continue
            db.execute("UPDATE transcript_segments SET translated_text=? WHERE id=? AND episode_id=?",
                       (item["translatedText"], item["segmentId"], episode_id))
            progressed += 1
        db.commit()
        if progressed == 0:
            raise RuntimeError("翻译结果没有覆盖请求的 segmentId；已停止，原文不受影响")
        count += progressed
    db.execute("""UPDATE episodes SET error=NULL WHERE id=? AND error LIKE '翻译待重试:%'""", (episode_id,))
    db.commit()
    return count


def oembed(video_url: str) -> dict[str, Any]:
    url = "https://www.youtube.com/oembed?" + urllib.parse.urlencode({"url": video_url, "format": "json"})
    return json.loads(http_get(url).decode("utf-8"))


def resolve_channel(url: str) -> tuple[str, str]:
    parsed = urllib.parse.urlparse(url)
    path = parsed.path.strip("/")
    match = re.search(r"(?:^|/)channel/(UC[A-Za-z0-9_-]{20,})", parsed.path)
    if match:
        return match.group(1), path.split("/")[-1]
    page = http_get(url, 30).decode("utf-8", "ignore")
    channel_match = re.search(r'"channelId":"(UC[A-Za-z0-9_-]{20,})"', page)
    if not channel_match:
        raise ValueError("无法从链接解析 YouTube Channel ID")
    title_match = re.search(r'<meta property="og:title" content="([^"]+)"', page)
    return channel_match.group(1), (title_match.group(1) if title_match else path or "YouTube Channel")


def add_url(db: sqlite3.Connection, url: str, resources: Path) -> dict[str, Any]:
    now = utc_now()
    video_match = YOUTUBE_VIDEO_RE.search(url)
    if video_match:
        video_id = video_match.group(1)
        canonical = f"https://www.youtube.com/watch?v={video_id}"
        metadata = oembed(canonical)
        published = published_from_page(video_id) or now
        duration = duration_from_page(video_id)
        source_id = "manual-episodes"
        db.execute("""INSERT INTO sources(id,name,handle,kind,external_id,feed_url,category,min_duration,profile_version,profile_prompt,created_at,updated_at)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET enabled=1,archived=0,updated_at=excluded.updated_at""",
                   (source_id, "手动添加", "manual", "manual", "", "", "手动单集", 0, "1.0.0",
                    "按访谈类型识别嘉宾资格，提炼核心观点、引申意义、证据限制和下一验证点。", now, now))
        db.execute("""INSERT INTO episodes(id,source_id,title,url,thumbnail_url,published_at,duration_seconds,status,created_at,updated_at)
                      VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title,thumbnail_url=excluded.thumbnail_url,published_at=excluded.published_at,
                      duration_seconds=COALESCE(excluded.duration_seconds,episodes.duration_seconds),updated_at=excluded.updated_at""",
                   (video_id, source_id, metadata.get("title", video_id), canonical,
                    f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg", published, duration,
                    "discovered", now, now))
        db.commit()
        return {"kind": "episode", "id": video_id}
    query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    playlist = (query.get("list") or [None])[0]
    if playlist:
        source_id = f"playlist-{playlist}"
        db.execute("""INSERT INTO sources(id,name,handle,kind,external_id,feed_url,category,min_duration,profile_version,profile_prompt,created_at,updated_at)
                      VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET enabled=1,archived=0,updated_at=excluded.updated_at""",
                   (source_id, f"YouTube Playlist {playlist[-6:]}", playlist, "playlist", playlist,
                    f"https://www.youtube.com/feeds/videos.xml?playlist_id={playlist}", "未分类", 0, "1.0.0",
                    "识别节目定位，提炼核心观点、嘉宾背景、引申意义、证据限制和下一验证点。", now, now))
        db.commit()
        profile = auto_profile_source(db, source_id, resources)
        return {"kind": "playlist", "id": source_id, "profile": profile["status"]}
    channel_id, name = resolve_channel(url)
    source_id = "channel-" + channel_id.lower()
    db.execute("""INSERT INTO sources(id,name,handle,kind,external_id,feed_url,category,min_duration,profile_version,profile_prompt,created_at,updated_at)
                  VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET enabled=1,archived=0,updated_at=excluded.updated_at""",
               (source_id, name, urllib.parse.urlparse(url).path.strip("/"), "channel", channel_id,
                f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}", "未分类", 0, "1.0.0",
                "识别节目定位，提炼核心观点、嘉宾背景、引申意义、证据限制和下一验证点。", now, now))
    db.commit()
    profile = auto_profile_source(db, source_id, resources)
    return {"kind": "channel", "id": source_id, "profile": profile["status"]}


def run_update(args: argparse.Namespace, db: sqlite3.Connection, resources: Path) -> dict[str, Any]:
    started = utc_now()
    cursor = db.execute("INSERT INTO runs(trigger,started_at,status,current_detail) VALUES(?,?,?,?)",
                        (args.trigger, started, "running", "准备检查订阅源"))
    run_id = cursor.lastrowid
    db.commit()
    counts = {"discovered": 0, "completed": 0, "noTranscript": 0, "failed": 0}
    try:
        source_filter = {args.source_id} if args.source_id else None
        new_ids, source_failures = discover(db, args.lookback_days, args.per_source, run_id, source_filter)
        counts["discovered"] = len(new_ids)
        counts["failed"] += len(source_failures)
        targets = list(new_ids)
        # A discovery-only first run or an interrupted worker may leave valid
        # episodes waiting. Daily/manual updates must drain that backlog instead
        # of only processing IDs discovered in the current scan.
        if args.source_id:
            targets += [row[0] for row in db.execute(
                """SELECT id FROM episodes WHERE source_id=? AND status IN ('discovered','transcript_ready')
                   ORDER BY published_at DESC LIMIT 100""", (args.source_id,)
            )]
        else:
            targets += [row[0] for row in db.execute(
                """SELECT id FROM episodes WHERE status IN ('discovered','transcript_ready')
                   ORDER BY published_at DESC LIMIT 100"""
            )]
        if args.retry_failed:
            if args.source_id:
                targets += [row[0] for row in db.execute(
                    """SELECT id FROM episodes WHERE source_id=? AND status IN ('failed','no_transcript')
                       ORDER BY published_at DESC LIMIT 100""", (args.source_id,)
                )]
            else:
                targets += [row[0] for row in db.execute(
                    "SELECT id FROM episodes WHERE status IN ('failed','no_transcript') ORDER BY published_at DESC LIMIT 100"
                )]
        if not args.discover_only:
            unique_targets = list(dict.fromkeys(targets))
            for index, episode_id in enumerate(unique_targets, start=1):
                db.execute("UPDATE runs SET current_detail=? WHERE id=?", (f"正在处理 {index}/{len(unique_targets)}", run_id))
                db.commit()
                state = process_episode(db, episode_id, resources, analyze=not args.transcript_only)
                if state == "complete":
                    counts["completed"] += 1
                    if not args.transcript_only:
                        try:
                            translate_episode(db, episode_id, resources)
                        except Exception as exc:
                            # Analysis and original transcript remain complete.
                            # The next one-shot update retries untranslated rows.
                            counts["failed"] += 1
                            db.execute(
                                "UPDATE episodes SET error=?,updated_at=? WHERE id=?",
                                (f"翻译待重试: {str(exc)[:3500]}", utc_now(), episode_id),
                            )
                            db.commit()
                elif state == "no_transcript": counts["noTranscript"] += 1
                elif state == "failed": counts["failed"] += 1
        db.execute("""UPDATE runs SET finished_at=?,status='complete',discovered_count=?,completed_count=?,
                      no_transcript_count=?,failed_count=?,current_detail='更新完成' WHERE id=?""",
                   (utc_now(), counts["discovered"], counts["completed"], counts["noTranscript"], counts["failed"], run_id))
        db.commit()
        return {"runId": run_id, **counts}
    except Exception as exc:
        db.execute("UPDATE runs SET finished_at=?,status='failed',error=?,current_detail='更新失败' WHERE id=?", (utc_now(), str(exc)[:4000], run_id))
        db.commit()
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Podcast Reader independent worker")
    parser.add_argument("--db", type=Path, default=default_db_path())
    parser.add_argument("--resources", type=Path, default=Path(__file__).resolve().parent)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init")
    latest = commands.add_parser("latest-each-source")
    latest.add_argument("--feed-limit", type=int, default=15)
    latest_source = commands.add_parser("latest-source")
    latest_source.add_argument("source_id")
    latest_source.add_argument("--feed-limit", type=int, default=15)
    latest_source.add_argument("--skip-unavailable", action="store_true")
    update = commands.add_parser("update")
    update.add_argument("--trigger", default="manual")
    update.add_argument("--lookback-days", type=int, default=30)
    update.add_argument("--per-source", type=int, default=3)
    update.add_argument("--source-id")
    update.add_argument("--discover-only", action="store_true")
    update.add_argument("--transcript-only", action="store_true")
    update.add_argument("--retry-failed", action="store_true")
    process = commands.add_parser("process")
    process.add_argument("episode_id")
    process.add_argument("--transcript-only", action="store_true")
    translate = commands.add_parser("translate")
    translate.add_argument("episode_id")
    add = commands.add_parser("add")
    add.add_argument("url")
    source_enable = commands.add_parser("source-enable")
    source_enable.add_argument("source_id")
    source_enable.add_argument("enabled", choices=["0", "1"])
    source_remove = commands.add_parser("source-remove")
    source_remove.add_argument("source_id")
    source_profile = commands.add_parser("source-profile")
    source_profile.add_argument("source_id")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    db = connect(args.db)
    init_database(db, args.resources)
    if args.command == "init":
        result: Any = {"database": str(args.db), "sources": db.execute("SELECT COUNT(*) FROM sources").fetchone()[0]}
    elif args.command == "latest-each-source":
        result = discover_latest_each_source(db, args.feed_limit)
    elif args.command == "latest-source":
        result = discover_latest_each_source(db, args.feed_limit, {args.source_id}, args.skip_unavailable)
    elif args.command == "update":
        result = run_update(args, db, args.resources)
    elif args.command == "process":
        status = process_episode(db, args.episode_id, args.resources, not args.transcript_only)
        translated = 0
        if status == "complete" and not args.transcript_only:
            translated = translate_episode(db, args.episode_id, args.resources)
        result = {"episodeId": args.episode_id, "status": status, "translated": translated}
    elif args.command == "translate":
        result = {"episodeId": args.episode_id, "translated": translate_episode(db, args.episode_id, args.resources)}
    elif args.command == "add":
        result = add_url(db, args.url, args.resources)
    elif args.command == "source-enable":
        db.execute("UPDATE sources SET enabled=?,updated_at=? WHERE id=?", (int(args.enabled), utc_now(), args.source_id))
        db.commit(); result = {"sourceId": args.source_id, "enabled": bool(int(args.enabled))}
    elif args.command == "source-remove":
        db.execute("UPDATE sources SET enabled=0,archived=1,updated_at=? WHERE id=?", (utc_now(), args.source_id))
        db.commit(); result = {"sourceId": args.source_id, "removed": True, "historyPreserved": True}
    elif args.command == "source-profile":
        result = {"sourceId": args.source_id, **auto_profile_source(db, args.source_id, args.resources)}
    else:
        raise AssertionError(args.command)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
