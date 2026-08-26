#!/usr/bin/env bash
# Checks that the server is ready. Modifies nothing.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"

FAIL=0
bad() { warn "$*"; FAIL=1; }

step "Mount point"
for m in "$MODELS_DIR" /srv/wal /srv/appdata /srv/data "$ARCHIVE_DIR" /srv/backup /var/lib/docker /home; do
  if findmnt -n "$m" >/dev/null 2>&1; then ok "$m"; else bad "$m NOT mounted"; fi
done

step "Striping and quotas"
if findmnt -no OPTIONS "$MODELS_DIR" | grep -q prjquota; then
  ok "prjquota active on $MODELS_DIR"
else
  bad "prjquota MISSING on $MODELS_DIR — add it to fstab and remount (umount+mount, not remount)"
fi
sw=$(findmnt -no OPTIONS "$MODELS_DIR" | tr ',' '\n' | grep '^swidth=' || true)
su=$(findmnt -no OPTIONS "$MODELS_DIR" | tr ',' '\n' | grep '^sunit=' || true)
if [[ -n "$sw" && -n "$su" ]]; then
  n=$(( ${sw#swidth=} / ${su#sunit=} ))
  ok "$MODELS_DIR striped across $n devices ($su $sw)"
  [[ "$n" -ge 2 ]] || bad "expected striping across 2 NVMe, found $n"
else
  bad "$MODELS_DIR does not appear striped: you would lose half of the read bandwidth"
fi

step "Space"
avail=$(df -BG --output=avail "$MODELS_DIR" | tail -1 | tr -dc '0-9')
if [[ "$avail" -ge 480 ]]; then ok "$MODELS_DIR: ${avail}G free"
else bad "$MODELS_DIR: only ${avail}G free, GLM-5.2 wants 372 + margin"; fi

step "GPU"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv,noheader | sed 's/^/     /'
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
  ok "compute_cap detected, expected CUDA_ARCH = $cc (in .env you have $CUDA_ARCH)"
  [[ "$cc" == "$CUDA_ARCH" ]] || bad "CUDA_ARCH in .env does not match the GPU"
  if [[ "$cc" == "61" ]]; then
    warn "Pascal GPU: no usable fp16/bf16. Consider COLI_CUDA_EXPERT_GB=6 and llama.cpp on CPU."
  fi
  if command -v nvcc >/dev/null 2>&1; then
    ok "CUDA Toolkit: nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
  else
    warn "CUDA Toolkit absent: phase 20 will install it (nvidia-cuda-toolkit)"
  fi
else
  bad "NVIDIA driver absent or not loaded"
fi

step "Memory and NUMA"
free -h | sed 's/^/     /'
nodes=$(lscpu | awk '/NUMA node\(s\)/{print $NF}')
ok "NUMA node: $nodes"
cpus="${SOCKET1_CPUS:-$(socket_cpus 1)}"
if [[ -n "$cpus" ]]; then ok "CPU socket 1: $cpus"
else warn "single socket or autodetect failed: AllowedCPUs will be empty"; fi

step "Ports"
for p in "$PORT_COLIBRI" "$PORT_LLAMA_SWAP" "$PORT_EMBED" "$PORT_LITELLM"; do
  if port_free "$p"; then ok "port $p free"; else bad "port $p ALREADY IN USE"; fi
done

step "Models declared in .env"
for v in HF_CHAT4B_REPO HF_CHAT4B_FILE HF_CHAT8B_REPO HF_CHAT8B_FILE; do
  [[ -n "${!v:-}" ]] && ok "$v = ${!v}" || bad "$v empty — check which releases exist today and fill in .env"
done

echo
if [[ "$FAIL" -eq 0 ]]; then ok "preflight passed"; else die "preflight failed: fix the points above"; fi
