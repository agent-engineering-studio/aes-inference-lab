#!/usr/bin/env bash
# Verifica che il server sia pronto. Non modifica nulla.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"

FAIL=0
bad() { warn "$*"; FAIL=1; }

step "Mount point"
for m in "$MODELS_DIR" /srv/wal /srv/appdata /srv/data "$ARCHIVE_DIR" /srv/backup /var/lib/docker /home; do
  if findmnt -n "$m" >/dev/null 2>&1; then ok "$m"; else bad "$m NON montato"; fi
done

step "Striping e quote"
if findmnt -no OPTIONS "$MODELS_DIR" | grep -q prjquota; then
  ok "prjquota attiva su $MODELS_DIR"
else
  bad "prjquota MANCANTE su $MODELS_DIR — aggiungila a fstab e rimonta (umount+mount, non remount)"
fi
sw=$(findmnt -no OPTIONS "$MODELS_DIR" | tr ',' '\n' | grep '^swidth=' || true)
su=$(findmnt -no OPTIONS "$MODELS_DIR" | tr ',' '\n' | grep '^sunit=' || true)
if [[ -n "$sw" && -n "$su" ]]; then
  n=$(( ${sw#swidth=} / ${su#sunit=} ))
  ok "$MODELS_DIR striped su $n dispositivi ($su $sw)"
  [[ "$n" -ge 2 ]] || bad "atteso striping su 2 NVMe, trovato $n"
else
  bad "$MODELS_DIR non risulta striped: perderesti meta' della banda di lettura"
fi

step "Spazio"
avail=$(df -BG --output=avail "$MODELS_DIR" | tail -1 | tr -dc '0-9')
if [[ "$avail" -ge 480 ]]; then ok "$MODELS_DIR: ${avail}G liberi"
else bad "$MODELS_DIR: solo ${avail}G liberi, GLM-5.2 ne vuole 372 + margine"; fi

step "GPU"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv,noheader | sed 's/^/     /'
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
  ok "compute_cap rilevata, CUDA_ARCH atteso = $cc (in .env hai $CUDA_ARCH)"
  [[ "$cc" == "$CUDA_ARCH" ]] || bad "CUDA_ARCH in .env non corrisponde alla GPU"
  if [[ "$cc" == "61" ]]; then
    warn "GPU Pascal: niente fp16/bf16 utilizzabili. Valuta COLI_CUDA_EXPERT_GB=6 e llama.cpp su CPU."
  fi
  if command -v nvcc >/dev/null 2>&1; then
    ok "CUDA Toolkit: nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
  else
    warn "CUDA Toolkit assente: la fase 20 lo installera' (nvidia-cuda-toolkit)"
  fi
else
  bad "driver NVIDIA assente o non caricato"
fi

step "Memoria e NUMA"
free -h | sed 's/^/     /'
nodes=$(lscpu | awk '/NUMA node\(s\)/{print $NF}')
ok "NUMA node: $nodes"
cpus="${SOCKET1_CPUS:-$(socket_cpus 1)}"
if [[ -n "$cpus" ]]; then ok "CPU socket 1: $cpus"
else warn "single socket o autodetect fallito: AllowedCPUs sara' vuoto"; fi

step "Porte"
for p in "$PORT_COLIBRI" "$PORT_LLAMA_SWAP" "$PORT_EMBED" "$PORT_LITELLM"; do
  if port_free "$p"; then ok "porta $p libera"; else bad "porta $p GIA' OCCUPATA"; fi
done

step "Modelli dichiarati in .env"
for v in HF_CHAT4B_REPO HF_CHAT4B_FILE HF_CHAT8B_REPO HF_CHAT8B_FILE; do
  [[ -n "${!v:-}" ]] && ok "$v = ${!v}" || bad "$v vuoto — verifica quali release esistono oggi e compila .env"
done

echo
if [[ "$FAIL" -eq 0 ]]; then ok "preflight superato"; else die "preflight fallito: risolvi i punti sopra"; fi
