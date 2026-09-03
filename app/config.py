"""Configurazione: endpoint di inferenza + impostazioni runtime."""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

_ENV_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def _expand(value: Any) -> Any:
    """Espande ${VAR} e ${VAR:-default} dentro le stringhe del file YAML."""
    if isinstance(value, str):
        def sub(m: re.Match[str]) -> str:
            return os.environ.get(m.group(1), m.group(2) or "")
        return _ENV_RE.sub(sub, value)
    if isinstance(value, list):
        return [_expand(v) for v in value]
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    return value


def _as_bool(value: Any) -> bool:
    """L'espansione di ${VAR} produce stringhe: 'false' deve restare falso."""
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on", "si", "sì"}


def _root_path() -> str:
    """Normalizza LAB_ROOT_PATH in "" oppure "/prefisso" (senza slash finale)."""
    prefix = os.environ.get("LAB_ROOT_PATH", "").strip().strip("/")
    return f"/{prefix}" if prefix else ""


@dataclass(frozen=True)
class Endpoint:
    id: str
    name: str
    base_url: str
    kind: str = "direct"            # "gateway" | "direct"
    role: str = "chat"              # "chat" | "embedding" | "mixed"
    api_key: str = ""
    note: str = ""
    default_model: str = ""
    timeout_s: float = 120.0
    enabled: bool = True

    @property
    def is_gateway(self) -> bool:
        return self.kind == "gateway"

    def headers(self) -> dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self.api_key:
            h["Authorization"] = f"Bearer {self.api_key}"
        return h

    def url(self, path: str) -> str:
        return f"{self.base_url.rstrip('/')}/{path.lstrip('/')}"


_DEFAULT_PROMPT = ("Spiega in tre frasi perché un modello Mixture-of-Experts "
                   "può girare su hardware con poca memoria video.")


@dataclass
class Settings:
    endpoints: list[Endpoint] = field(default_factory=list)
    db_path: Path = field(
        default_factory=lambda: Path(os.environ.get("LAB_DB_PATH", "data/lab.sqlite3")))
    host_proc: str = field(default_factory=lambda: os.environ.get("HOST_PROC", ""))
    models_path: str = field(
        default_factory=lambda: os.environ.get("MODELS_PATH", "/srv/models"))
    health_timeout_s: float = field(
        default_factory=lambda: float(os.environ.get("HEALTH_TIMEOUT_S", "5")))
    default_prompt: str = field(
        default_factory=lambda: os.environ.get("DEFAULT_PROMPT", _DEFAULT_PROMPT))
    # Prefisso sotto cui il reverse proxy espone la dashboard (es. "/inference").
    # Vuoto quando la dashboard sta sulla radice del dominio.
    root_path: str = field(default_factory=_root_path)

    def by_id(self, endpoint_id: str) -> Endpoint | None:
        return next((e for e in self.endpoints if e.id == endpoint_id), None)

    @property
    def active(self) -> list[Endpoint]:
        return [e for e in self.endpoints if e.enabled]


def load_settings(path: str | os.PathLike[str] | None = None) -> Settings:
    cfg_path = Path(path or os.environ.get("LAB_CONFIG", "config/endpoints.yml"))
    raw: dict[str, Any] = {}
    if cfg_path.is_file():
        raw = _expand(yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {})

    endpoints: list[Endpoint] = []
    known = set(Endpoint.__dataclass_fields__)
    for item in raw.get("endpoints", []):
        data = {k: v for k, v in item.items() if k in known}
        if "enabled" in data:
            data["enabled"] = _as_bool(data["enabled"])
        if "timeout_s" in data:
            data["timeout_s"] = float(data["timeout_s"])
        endpoints.append(Endpoint(**data))

    s = Settings(endpoints=endpoints)
    if "defaults" in raw:
        d = raw["defaults"]
        s.default_prompt = d.get("prompt", s.default_prompt)
        s.models_path = d.get("models_path", s.models_path)
        s.health_timeout_s = float(d.get("health_timeout_s", s.health_timeout_s))
    return s


settings = load_settings()
