"""Rilevazione stato dei servizi di inferenza."""
from __future__ import annotations

import asyncio

from .clients import InferenceError, list_models
from .config import Endpoint, settings
from .models import EndpointStatus


async def check(ep: Endpoint) -> EndpointStatus:
    base = EndpointStatus(
        id=ep.id, name=ep.name, kind=ep.kind, role=ep.role,
        base_url=ep.base_url, note=ep.note, online=False,
    )
    try:
        models, latency = await list_models(ep, timeout=settings.health_timeout_s)
    except InferenceError as exc:
        base.error = str(exc)
        return base
    base.online = True
    base.latency_ms = round(latency, 1)
    base.models = models
    return base


async def check_all() -> list[EndpointStatus]:
    return list(await asyncio.gather(*(check(ep) for ep in settings.active)))


def pick_model(status: EndpointStatus, ep: Endpoint, requested: str = "") -> str:
    """Sceglie il modello: richiesto → default dell'endpoint → primo disponibile."""
    if requested and (not status.models or requested in status.models):
        return requested
    if ep.default_model and (not status.models or ep.default_model in status.models):
        return ep.default_model
    return status.models[0] if status.models else (requested or ep.default_model)
