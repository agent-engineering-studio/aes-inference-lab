"""Motore di inferenza simulato, compatibile con l'API OpenAI.

Serve a provare la dashboard senza avere il server reale acceso, e a far girare
i test in CI. Simula tre modelli con velocità molto diverse fra loro.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import random
import time
from collections.abc import AsyncIterator

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI(title="Mock inference engine")

# nome → (token al secondo, ritardo iniziale in secondi)
MODELS: dict[str, tuple[float, float]] = {
    "mock-large": (1.6, 4.0),    # imita colibrì: lentissimo, lungo avvio
    "mock-fast": (45.0, 0.15),   # imita un modello piccolo su GPU
    "mock-embed": (0.0, 0.0),
}

WORDS = ("gli esperti restano sul disco e vengono letti solo quando servono "
         "quindi la memoria video non deve contenere tutto il modello ma "
         "soltanto le parti più richieste dal calcolo in corso").split()


class ChatBody(BaseModel):
    model: str = "mock-fast"
    messages: list[dict] = []
    max_tokens: int = 128
    temperature: float = 0.0
    stream: bool = False


class EmbedBody(BaseModel):
    model: str = "mock-embed"
    input: list[str] | str = ""


@app.get("/v1/models")
async def models() -> dict:
    return {"object": "list",
            "data": [{"id": m, "object": "model", "owned_by": "mock"} for m in MODELS]}


def _tokens(model: str, limit: int) -> list[str]:
    rng = random.Random(hashlib.sha1(model.encode()).hexdigest())
    n = min(limit, 60)
    return [rng.choice(WORDS) + " " for _ in range(n)]


@app.post("/v1/chat/completions")
async def chat(body: ChatBody):
    tps, warmup = MODELS.get(body.model, (20.0, 0.2))
    delay = 1.0 / tps if tps else 0.0
    pieces = _tokens(body.model, body.max_tokens)

    if not body.stream:
        await asyncio.sleep(warmup + delay * len(pieces))
        return {"id": "mock", "object": "chat.completion", "model": body.model,
                "choices": [{"index": 0, "message": {"role": "assistant",
                                                     "content": "".join(pieces)},
                             "finish_reason": "stop"}],
                "usage": {"completion_tokens": len(pieces)}}

    async def gen() -> AsyncIterator[str]:
        await asyncio.sleep(warmup)
        for piece in pieces:
            chunk = {"id": "mock", "object": "chat.completion.chunk", "model": body.model,
                     "choices": [{"index": 0, "delta": {"content": piece}}]}
            yield f"data: {json.dumps(chunk)}\n\n"
            await asyncio.sleep(delay)
        yield ("data: " + json.dumps({
            "id": "mock", "object": "chat.completion.chunk", "model": body.model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {"completion_tokens": len(pieces)}}) + "\n\n")
        yield "data: [DONE]\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post("/v1/embeddings")
async def embeddings(body: EmbedBody) -> dict:
    texts = [body.input] if isinstance(body.input, str) else body.input
    await asyncio.sleep(0.05 * len(texts))
    dim = 64
    data = []
    for i, text in enumerate(texts):
        seed = int(hashlib.sha1(text.lower().encode()).hexdigest()[:12], 16)
        rng = random.Random(seed)
        # componente "semantica" grossolana: parole comuni → vettori simili
        base = [0.0] * dim
        for word in text.lower().split():
            wr = random.Random(int(hashlib.sha1(word.encode()).hexdigest()[:12], 16))
            for j in range(dim):
                base[j] += wr.uniform(-1, 1)
        noise = [rng.uniform(-0.05, 0.05) for _ in range(dim)]
        vec = [b + n for b, n in zip(base, noise, strict=True)]
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        data.append({"object": "embedding", "index": i,
                     "embedding": [v / norm for v in vec]})
    return {"object": "list", "data": data, "model": body.model,
            "usage": {"prompt_tokens": sum(len(t.split()) for t in texts)}}


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok", "ts": time.time()}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("MOCK_PORT", 9000)))
