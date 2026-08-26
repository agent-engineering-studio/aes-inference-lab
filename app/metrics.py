"""Monitor risorse: CPU, RAM, page cache, disco, GPU."""
from __future__ import annotations

import shutil
import subprocess
import time

import psutil

from .config import settings
from .models import GpuSnapshot, ResourceSnapshot

_GB = 1024 ** 3
_last_io: tuple[float, int] | None = None

if settings.host_proc:
    psutil.PROCFS_PATH = settings.host_proc  # type: ignore[attr-defined]


def _page_cache_gb() -> float:
    """Page cache reale del kernel: è la vera cache degli esperti."""
    try:
        procfs = settings.host_proc or "/proc"
        with open(f"{procfs}/meminfo", encoding="utf-8") as fh:
            info = {
                k.strip(): int(v.split()[0])
                for k, v in (ln.split(":", 1) for ln in fh if ":" in ln)
            }
        return (info.get("Cached", 0) + info.get("Buffers", 0)) * 1024 / _GB
    except OSError:
        return 0.0


def _gpus() -> list[GpuSnapshot]:
    if not shutil.which("nvidia-smi"):
        return []
    query = "index,name,memory.total,memory.used,utilization.gpu,temperature.gpu"
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return []

    gpus: list[GpuSnapshot] = []
    for line in out.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 4:
            continue

        def num(value: str) -> float | None:
            try:
                return float(value)
            except ValueError:
                return None

        gpus.append(GpuSnapshot(
            index=int(parts[0]), name=parts[1],
            vram_total_mb=float(parts[2]), vram_used_mb=float(parts[3]),
            util_percent=num(parts[4]) if len(parts) > 4 else None,
            temperature_c=num(parts[5]) if len(parts) > 5 else None,
        ))
    return gpus


def _disk_read_mb_s() -> float | None:
    global _last_io
    counters = psutil.disk_io_counters()
    if counters is None:
        return None
    now, read = time.time(), counters.read_bytes
    prev, _last_io = _last_io, (now, read)
    if prev is None or now - prev[0] < 0.2:
        return None
    return (read - prev[1]) / (now - prev[0]) / (1024 ** 2)


def snapshot() -> ResourceSnapshot:
    vm = psutil.virtual_memory()
    sw = psutil.swap_memory()
    try:
        load1 = psutil.getloadavg()[0]
    except (OSError, AttributeError):
        load1 = 0.0

    disk_total = disk_used = None
    try:
        usage = psutil.disk_usage(settings.models_path)
        disk_total, disk_used = usage.total / _GB, usage.used / _GB
    except OSError:
        pass

    return ResourceSnapshot(
        ts=time.time(),
        cpu_percent=psutil.cpu_percent(interval=None),
        load1=load1,
        ram_total_gb=vm.total / _GB,
        ram_used_gb=(vm.total - vm.available) / _GB,
        ram_available_gb=vm.available / _GB,
        page_cache_gb=_page_cache_gb(),
        swap_used_gb=sw.used / _GB,
        disk_path=settings.models_path,
        disk_total_gb=disk_total,
        disk_used_gb=disk_used,
        disk_read_mb_s=_disk_read_mb_s(),
        gpus=_gpus(),
        source="host" if settings.host_proc else "container",
    )
