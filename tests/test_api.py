from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(mock_server, tmp_path, monkeypatch):
    from app import storage
    from app.config import Endpoint, settings

    monkeypatch.setattr(settings, "db_path", tmp_path / "test.sqlite3")
    monkeypatch.setattr(settings, "endpoints", [
        Endpoint(id="mock", name="Mock", base_url=mock_server, role="mixed",
                 default_model="mock-fast", timeout_s=30),
        Endpoint(id="dead", name="Dead", base_url="http://127.0.0.1:1/v1", timeout_s=1),
    ])
    monkeypatch.setattr(settings, "health_timeout_s", 1.0)
    storage.init_db()

    from app.main import app
    with TestClient(app) as c:
        yield c


def test_healthz(client):
    assert client.get("/healthz").json()["status"] == "ok"


def test_health_lists_endpoints(client):
    data = client.get("/api/health").json()
    by_id = {d["id"]: d for d in data}
    assert by_id["mock"]["online"] is True
    assert "mock-fast" in by_id["mock"]["models"]
    assert by_id["dead"]["online"] is False


def test_resources_snapshot(client):
    res = client.get("/api/resources").json()
    assert res["ram_total_gb"] > 0
    assert "gpus" in res


def test_bench_roundtrip_and_history(client):
    payload = {"endpoints": ["mock", "dead"], "runs": 2, "max_tokens": 5,
               "prompt": "ciao", "label": "test"}
    results = client.post("/api/bench", json=payload).json()
    by_id = {r["endpoint"]: r for r in results}
    assert by_id["mock"]["ok_runs"] == 2
    assert by_id["dead"]["ok_runs"] == 0

    history = client.get("/api/history").json()
    assert len(history) == 2
    assert {h["label"] for h in history} == {"test"}

    assert client.delete("/api/history").json()["deleted"] == 2
    assert client.get("/api/history").json() == []


def test_embed_similarity_matrix(client):
    body = {"endpoint": "mock", "model": "mock-embed",
            "texts": ["il gatto dorme", "il gatto riposa"]}
    data = client.post("/api/embed", json=body).json()
    assert data["dimensions"] > 0
    assert len(data["similarity"]) == 2
    assert data["similarity"][0][0] == pytest.approx(1.0, abs=1e-3)


def test_dashboard_renders(client):
    html = client.get("/").text
    assert "AES Inference Lab" in html
    assert "Benchmark" in html
