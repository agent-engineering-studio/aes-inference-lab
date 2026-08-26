from __future__ import annotations

import asyncio
import contextlib
import socket
import threading
import time

import pytest
import uvicorn


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def mock_server() -> str:
    """Avvia il motore simulato in un thread e ne restituisce la base URL."""
    from mock.server import app as mock_app

    port = _free_port()
    config = uvicorn.Config(mock_app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    deadline = time.time() + 15
    while time.time() < deadline and not server.started:
        time.sleep(0.05)
    if not server.started:
        pytest.fail("il mock server non si è avviato")

    yield f"http://127.0.0.1:{port}/v1"

    server.should_exit = True
    thread.join(timeout=5)
    with contextlib.suppress(RuntimeError):
        asyncio.get_event_loop()


@pytest.fixture
def mock_endpoint(mock_server: str):
    from app.config import Endpoint
    return Endpoint(id="mock", name="Mock", base_url=mock_server,
                    role="mixed", default_model="mock-fast", timeout_s=30)
