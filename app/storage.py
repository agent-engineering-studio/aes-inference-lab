"""Persistenza SQLite dello storico benchmark."""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

from .config import settings
from .models import BenchRequest, BenchResult

_SCHEMA = """
CREATE TABLE IF NOT EXISTS bench_run (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          REAL    NOT NULL,
    label       TEXT    NOT NULL DEFAULT '',
    endpoint    TEXT    NOT NULL,
    endpoint_name TEXT  NOT NULL DEFAULT '',
    model       TEXT    NOT NULL,
    runs        INTEGER NOT NULL,
    ok_runs     INTEGER NOT NULL,
    concurrency INTEGER NOT NULL DEFAULT 1,
    max_tokens  INTEGER NOT NULL DEFAULT 0,
    ttft_ms_p50 REAL,
    ttft_ms_p95 REAL,
    total_ms_p50 REAL,
    tokens_per_s_mean REAL,
    output_tokens_mean REAL,
    error       TEXT,
    prompt      TEXT NOT NULL DEFAULT '',
    payload     TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_bench_ts ON bench_run(ts DESC);
"""


def _connect() -> sqlite3.Connection:
    path = Path(settings.db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)


def save_results(req: BenchRequest, results: list[BenchResult]) -> None:
    now = time.time()
    with _connect() as conn:
        conn.executemany(
            """INSERT INTO bench_run
               (ts, label, endpoint, endpoint_name, model, runs, ok_runs, concurrency,
                max_tokens, ttft_ms_p50, ttft_ms_p95, total_ms_p50, tokens_per_s_mean,
                output_tokens_mean, error, prompt, payload)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            [(now, req.label, r.endpoint, r.endpoint_name, r.model, r.runs, r.ok_runs,
              req.concurrency, req.max_tokens, r.ttft_ms_p50, r.ttft_ms_p95,
              r.total_ms_p50, r.tokens_per_s_mean, r.output_tokens_mean, r.error,
              req.prompt[:2000], json.dumps(r.model_dump()))
             for r in results],
        )


def history(limit: int = 50) -> list[dict]:
    with _connect() as conn:
        rows = conn.execute(
            "SELECT * FROM bench_run ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


def clear_history() -> int:
    with _connect() as conn:
        cur = conn.execute("DELETE FROM bench_run")
        return cur.rowcount
