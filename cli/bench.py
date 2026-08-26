#!/usr/bin/env python3
"""Benchmark da riga di comando, senza dashboard.

Esempi:
    python -m cli.bench --list
    python -m cli.bench --endpoint colibri --endpoint llama_chat --runs 5
    python -m cli.bench --endpoint gateway --model glm52 --json > run.json
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import storage
from app.bench import bench_endpoint
from app.config import settings
from app.health import check, pick_model
from app.models import BenchRequest, BenchResult


def _fmt(value: float | None, digits: int = 1) -> str:
    return "—" if value is None else f"{value:,.{digits}f}".replace(",", " ")


async def run(args: argparse.Namespace) -> list[BenchResult]:
    req = BenchRequest(
        endpoints=args.endpoint, model=args.model,
        prompt=args.prompt or settings.default_prompt, runs=args.runs,
        concurrency=args.concurrency, max_tokens=args.max_tokens, label=args.label,
    )
    results: list[BenchResult] = []
    for endpoint_id in req.endpoints:
        ep = settings.by_id(endpoint_id)
        if ep is None:
            print(f"! endpoint sconosciuto: {endpoint_id}", file=sys.stderr)
            continue
        status = await check(ep)
        if not status.online:
            print(f"! {ep.name}: non raggiungibile ({status.error})", file=sys.stderr)
            results.append(BenchResult(endpoint=ep.id, endpoint_name=ep.name,
                                       model=req.model, runs=req.runs, ok_runs=0,
                                       error=status.error))
            continue
        model = pick_model(status, ep, req.model)
        print(f"→ {ep.name} · {model} · {req.runs} run…", file=sys.stderr)
        results.append(await bench_endpoint(ep, model, req))
    if results and not args.no_save:
        storage.init_db()
        storage.save_results(req, results)
    return results


def main() -> int:
    p = argparse.ArgumentParser(description="Benchmark dei server di inferenza locali.")
    p.add_argument("--endpoint", action="append", default=[],
                   help="id dell'endpoint (ripetibile); default: tutti quelli di chat")
    p.add_argument("--model", default="", help="modello da usare (default: automatico)")
    p.add_argument("--prompt", default="", help="prompt da inviare")
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--max-tokens", type=int, default=128, dest="max_tokens")
    p.add_argument("--label", default="", help="etichetta salvata nello storico")
    p.add_argument("--json", action="store_true", help="stampa JSON invece della tabella")
    p.add_argument("--no-save", action="store_true", help="non scrivere nel database")
    p.add_argument("--list", action="store_true", help="elenca gli endpoint configurati")
    args = p.parse_args()

    if args.list:
        for ep in settings.endpoints:
            state = "" if ep.enabled else "  (disabilitato)"
            print(f"{ep.id:<14} {ep.kind:<8} {ep.role:<10} {ep.base_url}{state}")
        return 0

    if not args.endpoint:
        args.endpoint = [e.id for e in settings.active if e.role in ("chat", "mixed")]
    if not args.endpoint:
        print("nessun endpoint disponibile", file=sys.stderr)
        return 2

    results = asyncio.run(run(args))

    if args.json:
        print(json.dumps([r.model_dump() for r in results], indent=2, ensure_ascii=False))
        return 0

    head = f"{'SERVIZIO':<26}{'MODELLO':<22}{'OK':>7}{'TTFT p50':>11}{'TOT p50':>10}{'TOK/S':>9}"
    print("\n" + head)
    print("-" * len(head))
    for r in results:
        ok = f"{r.ok_runs}/{r.runs}"
        print(f"{r.endpoint_name[:25]:<26}{(r.model or '—')[:21]:<22}{ok:>7}"
              f"{_fmt(r.ttft_ms_p50, 0):>11}{_fmt(r.total_ms_p50, 0):>10}"
              f"{_fmt(r.tokens_per_s_mean, 2):>9}")
        if r.error:
            print(f"  ! {r.error}")
    print()
    return 0 if any(r.ok_runs for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
