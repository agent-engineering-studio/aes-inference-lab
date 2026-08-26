#!/usr/bin/env bash
# Compila llama.cpp (CUDA) e colibri, installa llama-swap e LiteLLM.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root

step "Dipendenze di build"
apt-get update -qq
apt-get install -y -qq build-essential cmake git curl jq \
  libcurl4-openssl-dev python3-venv python3-pip pciutils \
  gettext-base fio bc xfsprogs
ok "pacchetti installati"

# ── CUDA Toolkit ─────────────────────────────────────────────
# Il driver espone la GPU, ma per compilare il backend CUDA servono nvcc,
# gli header e le librerie di sviluppo: sono un pacchetto separato.
step "CUDA Toolkit"
if command -v nvcc >/dev/null 2>&1; then
  ok "nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
else
  warn "nvcc assente: senza toolkit llama.cpp non compila il backend CUDA"
  # Verifica che apt non voglia toccare il driver gia' installato.
  if apt-get install -s -y nvidia-cuda-toolkit 2>/dev/null \
       | grep -qE '^(Inst|Remv) nvidia-driver'; then
    warn "apt vorrebbe modificare il driver NVIDIA installato:"
    apt-get install -s -y nvidia-cuda-toolkit 2>/dev/null \
      | grep -E '^(Inst|Remv) nvidia' | sed 's/^/     /'
    die "usa il repo ufficiale NVIDIA con 'cuda-toolkit-13-0' (non il meta-pacchetto 'cuda', che porta il driver) e rilancia"
  fi
  apt-get install -y -qq nvidia-cuda-toolkit
  command -v nvcc >/dev/null 2>&1 || die "installazione del toolkit fallita"
  ok "nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
fi

# ── llama.cpp ────────────────────────────────────────────────
step "llama.cpp (CUDA arch $CUDA_ARCH)"
LLAMA_SRC="$OPT_DIR/llama.cpp"
if [[ -d "$LLAMA_SRC/.git" ]]; then
  git -C "$LLAMA_SRC" pull --ff-only && ok "aggiornato"
else
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
fi
configure_llama() {   # argomenti extra per cmake
  cmake -S "$LLAMA_SRC" -B "$LLAMA_SRC/build" \
    -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" "$@"
}

if ! configure_llama >/dev/null 2>"$LLAMA_SRC/cmake-err.log"; then
  sed 's/^/     /' "$LLAMA_SRC/cmake-err.log" | tail -15
  # Su distribuzioni recenti il gcc di sistema puo' essere troppo nuovo
  # per la versione di CUDA installata: si ripiega su un compilatore host
  # piu' vecchio, che e' l'unica cosa che nvcc pretende.
  if grep -qiE 'unsupported (GNU|GCC) version|requires (gcc|g\+\+)' "$LLAMA_SRC/cmake-err.log"; then
    warn "gcc di sistema non supportato da questa versione di CUDA"
    HOSTCC=""
    for v in 14 13 12 11; do
      command -v "g++-$v" >/dev/null 2>&1 && { HOSTCC="/usr/bin/g++-$v"; break; }
    done
    if [[ -z "$HOSTCC" ]]; then
      log "installo g++-13 come compilatore host per nvcc"
      apt-get install -y -qq g++-13 && HOSTCC=/usr/bin/g++-13
    fi
    [[ -n "$HOSTCC" ]] || die "nessun g++ compatibile disponibile"
    rm -rf "$LLAMA_SRC/build"
    ok "riprovo con CMAKE_CUDA_HOST_COMPILER=$HOSTCC"
    configure_llama -DCMAKE_CUDA_HOST_COMPILER="$HOSTCC" >/dev/null \
      || die "configure di llama.cpp fallita anche con $HOSTCC"
  else
    die "configure di llama.cpp fallita: vedi $LLAMA_SRC/cmake-err.log"
  fi
fi
cmake --build "$LLAMA_SRC/build" --config Release -j"$(nproc)"
[[ -x "$LLAMA_SRC/build/bin/llama-server" ]] || die "build llama.cpp fallita"
ok "llama-server compilato"

# ── colibri ──────────────────────────────────────────────────
step "colibri"
COLI_SRC="$OPT_DIR/colibri"
if [[ -d "$COLI_SRC/.git" ]]; then
  git -C "$COLI_SRC" pull --ff-only && ok "aggiornato"
else
  git clone --depth 1 https://github.com/JustVugg/colibri "$COLI_SRC"
fi
# Il Makefile di colibri cerca $CUDA_HOME/bin/nvcc (default /usr/local/cuda),
# mentre il pacchetto Ubuntu mette nvcc in /usr/bin: glielo ricaviamo.
CUDA_HOME_GUESS=""
if command -v nvcc >/dev/null 2>&1; then
  CUDA_HOME_GUESS="$(dirname "$(dirname "$(command -v nvcc)")")"
  ok "CUDA_HOME=$CUDA_HOME_GUESS (da $(command -v nvcc))"
fi

# Su Pascal il backend CUDA rende poco: lo compiliamo comunque, quanto
# usarlo lo decide CUDA_EXPERT_GB.
# CUDA_ARCH viene da .env per CMAKE_CUDA_ARCHITECTURES di llama.cpp, che
# vuole il numero nudo (75). Il Makefile di colibri lo passa a nvcc come
# -arch=, dove serve 'native' o 'sm_75': va sovrascritto sulla riga di
# comando, altrimenti nvcc rifiuta il valore.
COLI_ARCH="${COLI_CUDA_ARCH:-native}"
if [[ -n "$CUDA_HOME_GUESS" ]] \
   && make -C "$COLI_SRC/c" glm CUDA=1 CUDA_HOME="$CUDA_HOME_GUESS" \
        NVCC="$(command -v nvcc)" CUDA_ARCH="$COLI_ARCH"; then
  ok "colibri compilato con backend CUDA (-arch=$COLI_ARCH)"
else
  warn "build con -arch=$COLI_ARCH fallita: riprovo con sm_${CUDA_ARCH}"
  if make -C "$COLI_SRC/c" glm CUDA=1 CUDA_HOME="$CUDA_HOME_GUESS" \
       NVCC="$(command -v nvcc)" CUDA_ARCH="sm_${CUDA_ARCH}"; then
    ok "colibri compilato con backend CUDA (-arch=sm_${CUDA_ARCH})"
  else
    warn "backend CUDA non compilabile: ripiego su CPU-only"
    make -C "$COLI_SRC/c" glm || die "build di colibri fallita"
    warn "metti COLI_VRAM_GB=0 in .env e COLI_CUDA_PIPE=0 nella unit"
  fi
fi

# Il launcher sta in c/, non nella root del repo.
COLI_BIN="$COLI_SRC/c/coli"
[[ -f "$COLI_BIN" ]] || die "launcher coli non trovato in $COLI_SRC/c"
chmod +x "$COLI_BIN" 2>/dev/null || true
ok "launcher: $COLI_BIN"

# La unit usa opzioni che devono esistere in questa versione di coli.
# coli e' uno script Python: lo invochiamo con python3 esplicito per non
# dipendere dallo shebang o dal bit di esecuzione.
step "Verifico le opzioni di 'coli serve'"
HELP="$(python3 "$COLI_BIN" serve --help 2>&1 || true)"
MISSING=()
for opt in --model --host --port --model-id --vram; do
  grep -q -- "$opt" <<<"$HELP" || MISSING+=("$opt")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "opzioni assenti in questa versione di coli: ${MISSING[*]}"
  sed 's/^/     /' <<<"$HELP" | head -25
  die "adatta etc/systemd/colibri.service alle opzioni disponibili, poi rilancia la fase 40"
fi
for opt in --kv-slots --policy; do
  grep -q -- "$opt" <<<"$HELP" || warn "opzione $opt assente in coli: rimuovila dalla unit"
done
ok "coli serve espone tutte le opzioni usate dalla unit"

# ── llama-swap ───────────────────────────────────────────────
step "llama-swap"
if command -v llama-swap >/dev/null 2>&1; then
  ok "gia' presente: $(llama-swap --version 2>&1 | head -1)"
else
  URL=$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest \
        | jq -r '.assets[].browser_download_url' \
        | grep -iE 'linux.*(amd64|x86_64).*\.tar\.gz$' | head -1)
  [[ -n "$URL" ]] || die "non trovo la release linux amd64 di llama-swap: scaricala a mano in /usr/local/bin"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$URL" -o "$tmp/ls.tgz"
  tar xzf "$tmp/ls.tgz" -C "$tmp"
  install -m755 "$(find "$tmp" -type f -name 'llama-swap' | head -1)" /usr/local/bin/llama-swap
  ok "installato $(llama-swap --version 2>&1 | head -1)"
fi

# ── LiteLLM ──────────────────────────────────────────────────
step "LiteLLM"
LL_DIR="$OPT_DIR/litellm"
[[ -d "$LL_DIR/venv" ]] || python3 -m venv "$LL_DIR/venv"
"$LL_DIR/venv/bin/pip" install -q --upgrade pip
"$LL_DIR/venv/bin/pip" install -q --upgrade 'litellm[proxy]'
ok "litellm $("$LL_DIR/venv/bin/litellm" --version 2>&1 | head -1)"

ok "build completata"
