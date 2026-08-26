from __future__ import annotations

from app.bench import _pct, bench_endpoint
from app.models import BenchRequest


def test_percentile_edges():
    assert _pct([], 0.5) is None
    assert _pct([7.0], 0.95) == 7.0
    assert _pct([0.0, 10.0], 0.5) == 5.0
    assert _pct([1.0, 2.0, 3.0, 4.0], 0.0) == 1.0


async def test_bench_endpoint_collects_stats(mock_endpoint):
    req = BenchRequest(endpoints=["mock"], runs=3, concurrency=3,
                       max_tokens=6, prompt="ciao")
    result = await bench_endpoint(mock_endpoint, "mock-fast", req)
    assert result.ok_runs == 3
    assert result.error is None
    assert result.ttft_ms_p50 and result.ttft_ms_p50 > 0
    assert result.tokens_per_s_mean and result.tokens_per_s_mean > 0
    assert result.ttft_ms_p95 >= result.ttft_ms_p50


async def test_bench_endpoint_marks_failures(mock_endpoint):
    from dataclasses import replace
    broken = replace(mock_endpoint, base_url="http://127.0.0.1:1/v1", timeout_s=1)
    req = BenchRequest(endpoints=["mock"], runs=2, max_tokens=4, prompt="ciao")
    result = await bench_endpoint(broken, "mock-fast", req)
    assert result.ok_runs == 0
    assert result.error
