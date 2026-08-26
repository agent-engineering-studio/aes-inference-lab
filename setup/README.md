# aes-server — inference layer setup

Scripts to install **colibrì** (GLM-5.2), **llama.cpp/llama-swap**, the
**embedding server** and the **LiteLLM gateway** on a dedicated server, and to
configure Docker so it doesn't steal resources from inference.

Assumes the **LVM storage is already prepared** (see `docs/storage.md`).

## Reference hardware profile

| | |
|---|---|
| CPU | dual socket, NUMA enabled |
| RAM | 30 GiB |
| GPU | Quadro RTX 4000 — Turing, `compute_cap 7.5`, 8 GiB |
| NVMe | 2× striped → `lv_models` 760 GB, XFS + `prjquota` |
| HDD | 3× in `vg1` → Docker, container state, data, archive, backup |

## Usage

```bash
git clone <this-repo> ~/aes-server-setup && cd ~/aes-server-setup
./scripts/01-autoconfig.sh   # reads the hardware and fills in .env
sudo ./install.sh 02         # preflight: verifies, changes nothing
sudo ./install.sh            # everything, with confirmations
```

`01-autoconfig` does the bulk of the configuration work on its own: it detects
the GPU and `compute_cap`, decides whether the VRAM goes to the small models or
to colibrì, sizes the contexts on the residual VRAM, finds the CPUs of socket 1,
computes the `docker.slice` budget from the RAM, verifies mounts and ports, and
searches Hugging Face for the 4B and 8B GGUFs, proposing the candidates. It
shows the diff and asks for confirmation before writing.

```bash
./scripts/01-autoconfig.sh --dry-run        # only the proposal
./scripts/01-autoconfig.sh --no-models      # skip the HF search
SEARCH_4B='gemma-3-4b-it GGUF' ./scripts/01-autoconfig.sh   # another family
```

Only `ANTHROPIC_API_KEY` (optional: without it, the local tier works) and any
models the autoconfig couldn't resolve are left to set by hand.

The phases are independent and re-runnable:

| Phase | What it does |
|---|---|
| `01-autoconfig` | detects the hardware and fills in `.env`. Shows the diff, asks for confirmation |
| `02-preflight` | verifies mounts, striping, quotas, GPU, RAM, ports. Does not write |
| `10-system-tuning` | sysctl, I/O scheduler, file descriptors, `wait-online` fix |
| `20-build-inference` | llama.cpp with CUDA, colibrì, llama-swap, LiteLLM venv |
| `30-fetch-models` | small GGUFs + (with confirmation) the 372 GB of GLM-5.2 |
| `40-install-services` | renders the templates, installs and starts the four units |
| `50-docker-tuning` | `daemon.json`, `docker.slice`, prune timer |
| `90-verify` | endpoints, `fio`, report in `docs/` |

```bash
sudo ./install.sh 20 40      # only build and services
sudo ./install.sh --list     # list the phases
```

## Architecture

```
                    ┌──────────────────────────────┐
   the 3 projects ─▶│  LiteLLM gateway   :8091     │
                    │  routing by model name        │
                    └───┬────────┬─────────┬────────┘
              ┌─────────▼──┐  ┌──▼──────┐ ┌▼──────────────┐
              │ llama-swap │  │embedding│ │  colibrì      │
              │   :8081    │  │  :8082  │ │  :8070        │
              │ 4B / 8B    │  │Qwen3-0.6│ │ GLM-5.2 372GB │
              │ GPU ~6.3GB │  │ CPU     │ │ CPU + 1.5 GB  │
              └────────────┘  └─────────┘ └───────┬───────┘
                                                  │ fallback
                                          ┌───────▼────────┐
                                          │  Claude API    │
                                          │  (optional)    │
                                          └────────────────┘
```

Model names exposed by the gateway: `fast` (4B), `chat` (8B),
`extract` (4B for throughput), `embed`, `quality-local` (colibrì),
`quality-cloud` (Claude).

## Why the GPU goes to the small models

6 GB of expert tiers in VRAM hold ~315 of GLM-5.2's 19,456 experts:
**1.6%**, the flat part of the curve. The same 6 GB on an 8B in full
offload gives tens of tokens per second. Hence `CUDA_EXPERT_GB=0` and
`COLI_CUDA_PIPE=2`: colibrì uses ~1.5 GB only for the dense part and the
MLA attention, which is a real gain independent of expert residency.

On **Pascal** GPUs (`compute_cap 6.1`) the choice reverses: no usable
fp16/bf16, so it pays to give the VRAM to colibrì
(`COLI_CUDA_EXPERT_GB=6`, pure memory transfer) and put llama.cpp on
CPU. The preflight flags this.

## Switching the quality tier: colibrì or Claude

A single variable per project:

```
QUALITY_MODEL=quality-local     # colibrì, free, data stays in-house
QUALITY_MODEL=quality-cloud     # Claude via API
```

Plus LiteLLM's fallback: with `ANTHROPIC_API_KEY` set, a colibrì that
times out automatically switches to Claude. Without the key,
`quality-cloud` is unreachable and only the local tier remains.

The criterion is **per-workload, not global**: high volume and low value per
call (entity extraction on every chunk) → always local, because the API cost
scales with the chunks; low volume and high value (a long report) → Anthropic's
Batch API is cheap and a hundred times faster. Where colibrì wins anyway:
when data must not leave, when you need unlimited volume at zero marginal cost,
and when you don't want external dependencies.

## Things that are easy to get wrong

- **`-ub` must be ≥ `-c`** on the embedding server: non-causal attention.
- **colibrì does not go behind llama-swap**: it has a 10 GB resident set and a
  learning cache (`.coli_usage`) that improves with use; unloading and
  reloading it destroys the accumulated value.
- **Do not set `COLI_MODEL_MIRROR`**: the LVM striping already parallelizes
  across the two NVMes, an application-level mirror would duplicate 372 GB for
  nothing.
- **No Ollama**: two inference engines on 8 GB of VRAM is an OOM waiting to
  happen.
- **`/srv/models` must stay writable**: colibrì writes `.coli_usage` and
  `.coli_kv` next to the weights.
- **The `/dev/nvmeXnY` names are not stable across reboots** on this
  hardware: the scripts use labels and UUIDs, never the direct devices.

## Measurements, not assumptions

```bash
sudo ./bench/ab-direct.sh                    # A/B of DIRECT=1, warm cache
sudo ./install.sh 90                         # full report
iostat -xm 2                                 # both NVMes must be working
```

`DIRECT=1` bypasses the page cache: reported at +34% on some drives and
neutral/negative on QLC or DRAM-less. On the two striped NVMes it is
absolutely worth the test — it's probably the single knob with the most
impact.

Realistic expectations: **1–2 tok/s** on GLM-5.2 with a warm cache. The ceiling
is the PCIe bandwidth of the NVMes, not the LVM. And with 30 GiB of RAM the
expert cache stays below 2% of the model: **raising the RAM to 128 GB is the
upgrade with the highest return**, more than any GPU or disk.
