"""Schemi Pydantic usati dall'API."""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class EndpointStatus(BaseModel):
    id: str
    name: str
    kind: str
    role: str
    base_url: str
    note: str = ""
    online: bool
    latency_ms: float | None = None
    models: list[str] = Field(default_factory=list)
    error: str | None = None


class ChatRequest(BaseModel):
    endpoint: str
    # Vuoto = lo risolve il server con pick_model: il chiamante non deve
    # conoscere i nomi esposti dal servizio.
    model: str = ""
    prompt: str
    system: str | None = None
    max_tokens: int = Field(default=256, ge=1, le=8192)
    temperature: float = Field(default=0.2, ge=0.0, le=2.0)


class BenchRequest(BaseModel):
    endpoints: list[str]
    model: str = ""
    prompt: str = ""
    runs: int = Field(default=3, ge=1, le=50)
    concurrency: int = Field(default=1, ge=1, le=16)
    max_tokens: int = Field(default=128, ge=1, le=4096)
    temperature: float = Field(default=0.0, ge=0.0, le=2.0)
    label: str = ""


class RunSample(BaseModel):
    ok: bool
    ttft_ms: float | None = None
    total_ms: float | None = None
    output_tokens: int = 0
    tokens_per_s: float | None = None
    error: str | None = None


class BenchResult(BaseModel):
    endpoint: str
    endpoint_name: str
    model: str
    runs: int
    ok_runs: int
    ttft_ms_p50: float | None = None
    ttft_ms_p95: float | None = None
    total_ms_p50: float | None = None
    tokens_per_s_mean: float | None = None
    output_tokens_mean: float | None = None
    error: str | None = None
    samples: list[RunSample] = Field(default_factory=list)


class EmbedRequest(BaseModel):
    endpoint: str
    model: str = ""
    texts: list[str] = Field(min_length=2, max_length=16)


class EmbedResult(BaseModel):
    model: str
    dimensions: int
    latency_ms: float
    texts: list[str]
    similarity: list[list[float]]


class ResourceSnapshot(BaseModel):
    ts: float
    cpu_percent: float
    load1: float
    ram_total_gb: float
    ram_used_gb: float
    ram_available_gb: float
    page_cache_gb: float
    swap_used_gb: float
    disk_path: str
    disk_total_gb: float | None = None
    disk_used_gb: float | None = None
    disk_read_mb_s: float | None = None
    gpus: list[GpuSnapshot] = Field(default_factory=list)
    source: Literal["host", "container"] = "container"


class GpuSnapshot(BaseModel):
    index: int
    name: str
    vram_total_mb: float
    vram_used_mb: float
    util_percent: float | None = None
    temperature_c: float | None = None


ResourceSnapshot.model_rebuild()
