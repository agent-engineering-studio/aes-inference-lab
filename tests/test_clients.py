from __future__ import annotations

import pytest

from app.clients import InferenceError, embed, list_models, stream_chat
from app.config import Endpoint


async def test_list_models(mock_endpoint):
    models, latency = await list_models(mock_endpoint)
    assert "mock-fast" in models
    assert latency > 0


async def test_list_models_offline():
    ep = Endpoint(id="dead", name="Dead", base_url="http://127.0.0.1:1/v1", timeout_s=1)
    with pytest.raises(InferenceError):
        await list_models(ep, timeout=0.5)


async def test_stream_chat_yields_text_and_stats(mock_endpoint):
    text, stats = "", None
    async for kind, payload in stream_chat(mock_endpoint, "mock-fast", "ciao",
                                           max_tokens=8):
        assert kind != "error", payload
        if kind == "delta":
            text += payload["text"]
        elif kind == "done":
            stats = payload
    assert text.strip()
    assert stats is not None
    assert stats["output_tokens"] > 0
    assert stats["ttft_ms"] > 0
    assert stats["tokens_per_s"] > 0


async def test_stream_chat_reports_http_error(mock_server):
    ep = Endpoint(id="bad", name="Bad", base_url=mock_server.replace("/v1", "/nope"),
                  timeout_s=5)
    events = [k async for k, _ in stream_chat(ep, "mock-fast", "ciao", max_tokens=4)]
    assert events == ["error"]


async def test_embed_returns_one_vector_per_text(mock_endpoint):
    texts = ["il gatto dorme", "il gatto riposa", "compilatore CUDA"]
    vectors, latency = await embed(mock_endpoint, "mock-embed", texts)
    assert len(vectors) == 3
    assert len({len(v) for v in vectors}) == 1
    assert latency > 0
