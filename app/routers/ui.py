"""Rotte HTML per la dashboard (HTMX)."""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from .. import storage
from ..config import settings
from ..health import check_all
from ..metrics import snapshot
from ..models import BenchRequest
from .api import bench as run_bench

router = APIRouter(tags=["ui"])
templates = Jinja2Templates(directory="app/templates")


def _fmt(value: float | None, digits: int = 0, suffix: str = "") -> str:
    if value is None:
        return "—"
    return f"{value:,.{digits}f}".replace(",", " ") + suffix


def _ts(value: float | None) -> str:
    if not value:
        return "—"
    return datetime.fromtimestamp(value).strftime("%d/%m %H:%M:%S")


templates.env.filters["fmt"] = _fmt
templates.env.filters["ts"] = _ts


@router.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    statuses = await check_all()
    return templates.TemplateResponse(request, "index.html", {
        "statuses": statuses,
        "endpoints": settings.active,
        "default_prompt": settings.default_prompt,
        "history": storage.history(20),
    })


@router.get("/ui/services", response_class=HTMLResponse)
async def ui_services(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/services.html",
                                      {"statuses": await check_all()})


@router.get("/ui/resources", response_class=HTMLResponse)
async def ui_resources(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/resources.html",
                                      {"res": snapshot()})


@router.post("/ui/bench", response_class=HTMLResponse)
async def ui_bench(
    request: Request,
    endpoint: list[str] = Form(default=[]),
    model: str = Form(default=""),
    prompt: str = Form(default=""),
    runs: int = Form(default=3),
    concurrency: int = Form(default=1),
    max_tokens: int = Form(default=128),
    label: str = Form(default=""),
) -> HTMLResponse:
    if not endpoint:
        return templates.TemplateResponse(
            request, "partials/bench_results.html",
            {"results": [], "error": "Seleziona almeno un servizio."})
    req = BenchRequest(endpoints=endpoint, model=model,
                       prompt=prompt or settings.default_prompt, runs=runs,
                       concurrency=concurrency, max_tokens=max_tokens, label=label)
    results = await run_bench(req)
    return templates.TemplateResponse(request, "partials/bench_results.html",
                                      {"results": results, "error": None,
                                       "req": req})


@router.get("/ui/history", response_class=HTMLResponse)
async def ui_history(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/history.html",
                                      {"history": storage.history(20)})


@router.delete("/ui/history", response_class=HTMLResponse)
async def ui_history_clear(request: Request) -> HTMLResponse:
    storage.clear_history()
    return templates.TemplateResponse(request, "partials/history.html",
                                      {"history": []})
