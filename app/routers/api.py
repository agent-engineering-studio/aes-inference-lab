"""API JSON: utilizzabile anche da riga di comando o da altri progetti."""
from __future__ import annotations

import asyncio
import json
import math
from collections.abc import AsyncIterator

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from .. import storage
from ..bench import bench_endpoint
from ..clients import InferenceError, embed, stream_chat
from ..config import settings
from ..health import check, check_all, pick_model
from ..metrics import snapshot
from ..models import (
    BenchRequest,
    BenchResult,
    ChatRequest,
    EmbedRequest,
    EmbedResult,
    EndpointStatus,
    ResourceSnapshot,
)

router = APIRouter(prefix="/api", tags=["api"])


@router.get("/health", response_model=list[EndpointStatus])
async def health() -> list[EndpointStatus]:
    return await check_all()


@router.get("/resources", response_model=ResourceSnapshot)
async def resources() -> ResourceSnapshot:
    return snapshot()


@router.post("/bench", response_model=list[BenchResult])
async def bench(req: BenchRequest) -> list[BenchResult]:
    if not req.endpoints:
        raise HTTPException(400, "nessun endpoint selezionato")
    req.prompt = req.prompt or settings.default_prompt

    async def run_one(endpoint_id: str) -> BenchResult:
        ep = settings.by_id(endpoint_id)
        if ep is None:
            return BenchResult(endpoint=endpoint_id, endpoint_name=endpoint_id,
                               model=req.model, runs=req.runs, ok_runs=0,
                               error="endpoint sconosciuto")
        status = await check(ep)
        if not status.online:
            return BenchResult(endpoint=ep.id, endpoint_name=ep.name, model=req.model,
                               runs=req.runs, ok_runs=0,
                               error=f"servizio non raggiungibile: {status.error}")
        return await bench_endpoint(ep, pick_model(status, ep, req.model), req)

    results = list(await asyncio.gather(*(run_one(e) for e in req.endpoints)))
    storage.save_results(req, results)
    return results


@router.get("/history")
async def get_history(limit: int = 50) -> list[dict]:
    return storage.history(limit)


@router.delete("/history")
async def delete_history() -> dict[str, int]:
    return {"deleted": storage.clear_history()}


async def _resolve_model(ep, requested: str) -> str:
    """Nome modello da usare: quello chiesto, altrimenti quello del servizio.

    Evita di inoltrare un nome inventato: il gateway risponderebbe 400 con
    'Invalid model name', errore che dal lato chiamante e' illeggibile.
    """
    if requested:
        return requested
    return pick_model(await check(ep), ep, requested)


@router.post("/chat/stream")
async def chat_stream(req: ChatRequest) -> StreamingResponse:
    ep = settings.by_id(req.endpoint)
    if ep is None:
        raise HTTPException(404, "endpoint sconosciuto")
    model = await _resolve_model(ep, req.model)

    async def gen() -> AsyncIterator[str]:
        async for kind, payload in stream_chat(
            ep, model, req.prompt, system=req.system,
            max_tokens=req.max_tokens, temperature=req.temperature,
        ):
            yield f"event: {kind}\ndata: {json.dumps(payload)}\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


@router.post("/embed", response_model=EmbedResult)
async def embeddings(req: EmbedRequest) -> EmbedResult:
    ep = settings.by_id(req.endpoint)
    if ep is None:
        raise HTTPException(404, "endpoint sconosciuto")
    model = await _resolve_model(ep, req.model)
    try:
        vectors, latency = await embed(ep, model, req.texts)
    except InferenceError as exc:
        raise HTTPException(502, str(exc)) from exc
    matrix = [[round(_cosine(a, b), 4) for b in vectors] for a in vectors]
    return EmbedResult(model=model, dimensions=len(vectors[0]),
                       latency_ms=round(latency, 1), texts=req.texts,
                       similarity=matrix)
