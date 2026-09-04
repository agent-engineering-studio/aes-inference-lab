"""AES Inference Lab — banco di prova per server di inferenza self-hosted."""
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from . import __version__, storage
from .config import settings
from .routers import api, ui


@asynccontextmanager
async def lifespan(_: FastAPI):
    storage.init_db()
    yield


app = FastAPI(
    title="AES Inference Lab",
    description="Banco di prova e dashboard per server di inferenza locali "
                "(colibrì, llama.cpp, LiteLLM).",
    version=__version__,
    lifespan=lifespan,
    # Impostato quando nginx serve la dashboard sotto un prefisso (LAB_ROOT_PATH):
    # rende corretti /docs, openapi.json e gli URL generati nei template.
    root_path=settings.root_path,
)

app.mount("/static", StaticFiles(directory="app/static"), name="static")
app.include_router(api.router)
app.include_router(ui.router)


@app.get("/healthz", include_in_schema=False)
async def healthz() -> dict[str, str]:
    return {"status": "ok", "version": __version__}
