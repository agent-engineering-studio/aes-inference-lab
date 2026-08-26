"""Client asincrono minimale per endpoint compatibili OpenAI."""
from __future__ import annotations

import json
import time
from collections.abc import AsyncIterator

import httpx

from .config import Endpoint


class InferenceError(RuntimeError):
    pass


async def list_models(ep: Endpoint, timeout: float = 5.0) -> tuple[list[str], float]:
    """Ritorna (modelli, latenza_ms). Solleva InferenceError su fallimento."""
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=timeout) as c:
            r = await c.get(ep.url("models"), headers=ep.headers())
            r.raise_for_status()
            payload = r.json()
    except Exception as exc:
        raise InferenceError(str(exc)) from exc
    latency = (time.perf_counter() - t0) * 1000
    data = payload.get("data", payload if isinstance(payload, list) else [])
    models = [m.get("id", "") for m in data if isinstance(m, dict) and m.get("id")]
    return sorted(models), latency


def _chat_payload(model: str, prompt: str, system: str | None,
                  max_tokens: int, temperature: float, stream: bool) -> dict:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    return {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": stream,
    }


async def stream_chat(
    ep: Endpoint,
    model: str,
    prompt: str,
    *,
    system: str | None = None,
    max_tokens: int = 256,
    temperature: float = 0.2,
) -> AsyncIterator[tuple[str, dict]]:
    """Genera eventi ('delta' | 'done' | 'error', payload) leggendo l'SSE.

    I tempi sono misurati lato client: TTFT è il ritardo fino al primo token
    utile, tokens_per_s riguarda la sola fase di generazione.
    """
    body = _chat_payload(model, prompt, system, max_tokens, temperature, True)
    t0 = time.perf_counter()
    ttft: float | None = None
    chunks = 0
    usage: dict = {}
    try:
        async with (
            httpx.AsyncClient(timeout=ep.timeout_s) as client,
            client.stream("POST", ep.url("chat/completions"),
                          headers=ep.headers(), json=body) as response,
        ):
            if response.status_code >= 400:
                detail = (await response.aread()).decode("utf-8", "replace")[:400]
                yield "error", {"error": f"HTTP {response.status_code}: {detail}"}
                return
            async for line in response.aiter_lines():
                if not line or not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if obj.get("usage"):
                    usage = obj["usage"]
                for choice in obj.get("choices", []):
                    piece = (choice.get("delta") or {}).get("content") or ""
                    if not piece:
                        continue
                    if ttft is None:
                        ttft = (time.perf_counter() - t0) * 1000
                    chunks += 1
                    yield "delta", {"text": piece}
    except Exception as exc:
        yield "error", {"error": str(exc)}
        return

    total_ms = (time.perf_counter() - t0) * 1000
    out_tokens = int(usage.get("completion_tokens") or chunks)
    gen_ms = max(total_ms - (ttft or 0.0), 1e-6)
    yield "done", {
        "ttft_ms": ttft,
        "total_ms": total_ms,
        "output_tokens": out_tokens,
        "tokens_per_s": (out_tokens / (gen_ms / 1000)) if out_tokens else None,
    }


async def embed(ep: Endpoint, model: str, texts: list[str]) -> tuple[list[list[float]], float]:
    """Ritorna (vettori, latenza_ms) per la lista di testi."""
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=ep.timeout_s) as client:
            r = await client.post(ep.url("embeddings"), headers=ep.headers(),
                                  json={"model": model, "input": texts})
            r.raise_for_status()
            payload = r.json()
    except Exception as exc:
        raise InferenceError(str(exc)) from exc
    latency = (time.perf_counter() - t0) * 1000
    rows = payload.get("data", [])
    vectors = [row["embedding"] for row in sorted(rows, key=lambda x: x.get("index", 0))]
    if len(vectors) != len(texts):
        raise InferenceError(f"attesi {len(texts)} vettori, ricevuti {len(vectors)}")
    return vectors, latency
