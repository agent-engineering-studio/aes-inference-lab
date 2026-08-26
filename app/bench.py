"""Motore di benchmark: latenza, time-to-first-token, throughput."""
from __future__ import annotations

import asyncio
import statistics
from collections.abc import Sequence

from .clients import stream_chat
from .config import Endpoint
from .models import BenchRequest, BenchResult, RunSample


def _pct(values: Sequence[float], q: float) -> float | None:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * q
    lo, hi = int(pos), min(int(pos) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)


async def _single_run(ep: Endpoint, model: str, req: BenchRequest) -> RunSample:
    stats: dict = {}
    error: str | None = None
    async for kind, payload in stream_chat(
        ep, model, req.prompt,
        max_tokens=req.max_tokens, temperature=req.temperature,
    ):
        if kind == "error":
            error = payload["error"]
            break
        if kind == "done":
            stats = payload
    if error:
        return RunSample(ok=False, error=error)
    if not stats:
        return RunSample(ok=False, error="nessun token ricevuto")
    return RunSample(ok=True, **stats)


async def bench_endpoint(ep: Endpoint, model: str, req: BenchRequest) -> BenchResult:
    sem = asyncio.Semaphore(req.concurrency)

    async def guarded() -> RunSample:
        async with sem:
            return await _single_run(ep, model, req)

    samples = await asyncio.gather(*(guarded() for _ in range(req.runs)))
    ok = [s for s in samples if s.ok]
    result = BenchResult(
        endpoint=ep.id, endpoint_name=ep.name, model=model,
        runs=req.runs, ok_runs=len(ok), samples=list(samples),
    )
    if not ok:
        result.error = samples[0].error if samples else "nessuna esecuzione"
        return result
    result.ttft_ms_p50 = _pct([s.ttft_ms for s in ok if s.ttft_ms], 0.50)
    result.ttft_ms_p95 = _pct([s.ttft_ms for s in ok if s.ttft_ms], 0.95)
    result.total_ms_p50 = _pct([s.total_ms for s in ok if s.total_ms], 0.50)
    tps = [s.tokens_per_s for s in ok if s.tokens_per_s]
    result.tokens_per_s_mean = statistics.fmean(tps) if tps else None
    toks = [s.output_tokens for s in ok if s.output_tokens]
    result.output_tokens_mean = statistics.fmean(toks) if toks else None
    return result
