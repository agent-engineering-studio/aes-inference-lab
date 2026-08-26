#!/usr/bin/env bash
# Builds llama.cpp (CUDA) and colibri, installs llama-swap and LiteLLM.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root

step "Build dependencies"
apt-get update -qq
apt-get install -y -qq build-essential cmake git curl jq \
  libcurl4-openssl-dev python3-venv python3-pip pciutils \
  gettext-base fio bc xfsprogs
ok "packages installed"

# ── CUDA Toolkit ─────────────────────────────────────────────
# The driver exposes the GPU, but building the CUDA backend needs nvcc,
# the headers and the development libraries: they are a separate package.
step "CUDA Toolkit"
if command -v nvcc >/dev/null 2>&1; then
  ok "nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
else
  warn "nvcc absent: without the toolkit llama.cpp cannot build the CUDA backend"
  # Check that apt does not want to touch the already installed driver.
  if apt-get install -s -y nvidia-cuda-toolkit 2>/dev/null \
       | grep -qE '^(Inst|Remv) nvidia-driver'; then
    warn "apt would like to modify the installed NVIDIA driver:"
    apt-get install -s -y nvidia-cuda-toolkit 2>/dev/null \
      | grep -E '^(Inst|Remv) nvidia' | sed 's/^/     /'
    die "use the official NVIDIA repo with 'cuda-toolkit-13-0' (not the 'cuda' meta-package, which pulls in the driver) and re-run"
  fi
  apt-get install -y -qq nvidia-cuda-toolkit
  command -v nvcc >/dev/null 2>&1 || die "toolkit installation failed"
  ok "nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
fi

# ── llama.cpp ────────────────────────────────────────────────
step "llama.cpp (CUDA arch $CUDA_ARCH)"
LLAMA_SRC="$OPT_DIR/llama.cpp"
if [[ -d "$LLAMA_SRC/.git" ]]; then
  git -C "$LLAMA_SRC" pull --ff-only && ok "updated"
else
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
fi
configure_llama() {   # extra arguments for cmake
  cmake -S "$LLAMA_SRC" -B "$LLAMA_SRC/build" \
    -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" "$@"
}

if ! configure_llama >/dev/null 2>"$LLAMA_SRC/cmake-err.log"; then
  sed 's/^/     /' "$LLAMA_SRC/cmake-err.log" | tail -15
  # On recent distributions the system gcc may be too new for the installed
  # CUDA version: fall back to an older host compiler, which is the only
  # thing nvcc insists on.
  if grep -qiE 'unsupported (GNU|GCC) version|requires (gcc|g\+\+)' "$LLAMA_SRC/cmake-err.log"; then
    warn "system gcc not supported by this CUDA version"
    HOSTCC=""
    for v in 14 13 12 11; do
      command -v "g++-$v" >/dev/null 2>&1 && { HOSTCC="/usr/bin/g++-$v"; break; }
    done
    if [[ -z "$HOSTCC" ]]; then
      log "installing g++-13 as the host compiler for nvcc"
      apt-get install -y -qq g++-13 && HOSTCC=/usr/bin/g++-13
    fi
    [[ -n "$HOSTCC" ]] || die "no compatible g++ available"
    rm -rf "$LLAMA_SRC/build"
    ok "retrying with CMAKE_CUDA_HOST_COMPILER=$HOSTCC"
    configure_llama -DCMAKE_CUDA_HOST_COMPILER="$HOSTCC" >/dev/null \
      || die "llama.cpp configure failed even with $HOSTCC"
  else
    die "llama.cpp configure failed: see $LLAMA_SRC/cmake-err.log"
  fi
fi
cmake --build "$LLAMA_SRC/build" --config Release -j"$(nproc)"
[[ -x "$LLAMA_SRC/build/bin/llama-server" ]] || die "llama.cpp build failed"
ok "llama-server built"

# ── colibri ──────────────────────────────────────────────────
step "colibri"
COLI_SRC="$OPT_DIR/colibri"
if [[ -d "$COLI_SRC/.git" ]]; then
  git -C "$COLI_SRC" pull --ff-only && ok "updated"
else
  git clone --depth 1 https://github.com/JustVugg/colibri "$COLI_SRC"
fi
# The colibri Makefile looks for $CUDA_HOME/bin/nvcc (default /usr/local/cuda),
# while the Ubuntu package puts nvcc in /usr/bin: we derive it for it.
CUDA_HOME_GUESS=""
if command -v nvcc >/dev/null 2>&1; then
  CUDA_HOME_GUESS="$(dirname "$(dirname "$(command -v nvcc)")")"
  ok "CUDA_HOME=$CUDA_HOME_GUESS (from $(command -v nvcc))"
fi

# On Pascal the CUDA backend yields little: we build it anyway, how much
# to use it is decided by CUDA_EXPERT_GB.
# CUDA_ARCH comes from .env for llama.cpp's CMAKE_CUDA_ARCHITECTURES, which
# wants the bare number (75). The colibri Makefile passes it to nvcc as
# -arch=, where 'native' or 'sm_75' is needed: it must be overridden on the
# command line, otherwise nvcc rejects the value.
COLI_ARCH="${COLI_CUDA_ARCH:-native}"
if [[ -n "$CUDA_HOME_GUESS" ]] \
   && make -C "$COLI_SRC/c" glm CUDA=1 CUDA_HOME="$CUDA_HOME_GUESS" \
        NVCC="$(command -v nvcc)" CUDA_ARCH="$COLI_ARCH"; then
  ok "colibri built with CUDA backend (-arch=$COLI_ARCH)"
else
  warn "build with -arch=$COLI_ARCH failed: retrying with sm_${CUDA_ARCH}"
  if make -C "$COLI_SRC/c" glm CUDA=1 CUDA_HOME="$CUDA_HOME_GUESS" \
       NVCC="$(command -v nvcc)" CUDA_ARCH="sm_${CUDA_ARCH}"; then
    ok "colibri built with CUDA backend (-arch=sm_${CUDA_ARCH})"
  else
    warn "CUDA backend not buildable: falling back to CPU-only"
    make -C "$COLI_SRC/c" glm || die "colibri build failed"
    warn "set COLI_VRAM_GB=0 in .env and COLI_CUDA_PIPE=0 in the unit"
  fi
fi

# The launcher is in c/, not in the repo root.
COLI_BIN="$COLI_SRC/c/coli"
[[ -f "$COLI_BIN" ]] || die "coli launcher not found in $COLI_SRC/c"
chmod +x "$COLI_BIN" 2>/dev/null || true
ok "launcher: $COLI_BIN"

# The unit uses options that must exist in this version of coli.
# coli is a Python script: we invoke it with an explicit python3 so as not
# to depend on the shebang or the execute bit.
step "Checking the 'coli serve' options"
HELP="$(python3 "$COLI_BIN" serve --help 2>&1 || true)"
MISSING=()
for opt in --model --host --port --model-id --vram; do
  grep -q -- "$opt" <<<"$HELP" || MISSING+=("$opt")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "options absent in this version of coli: ${MISSING[*]}"
  sed 's/^/     /' <<<"$HELP" | head -25
  die "adapt etc/systemd/colibri.service to the available options, then re-run phase 40"
fi
for opt in --kv-slots --policy; do
  grep -q -- "$opt" <<<"$HELP" || warn "option $opt absent in coli: remove it from the unit"
done
ok "coli serve exposes all the options used by the unit"

# ── llama-swap ───────────────────────────────────────────────
step "llama-swap"
if command -v llama-swap >/dev/null 2>&1; then
  ok "already present: $(llama-swap --version 2>&1 | head -1)"
else
  URL=$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest \
        | jq -r '.assets[].browser_download_url' \
        | grep -iE 'linux.*(amd64|x86_64).*\.tar\.gz$' | head -1)
  [[ -n "$URL" ]] || die "cannot find the linux amd64 release of llama-swap: download it by hand into /usr/local/bin"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$URL" -o "$tmp/ls.tgz"
  tar xzf "$tmp/ls.tgz" -C "$tmp"
  install -m755 "$(find "$tmp" -type f -name 'llama-swap' | head -1)" /usr/local/bin/llama-swap
  ok "installed $(llama-swap --version 2>&1 | head -1)"
fi

# ── LiteLLM ──────────────────────────────────────────────────
step "LiteLLM"
LL_DIR="$OPT_DIR/litellm"
[[ -d "$LL_DIR/venv" ]] || python3 -m venv "$LL_DIR/venv"
"$LL_DIR/venv/bin/pip" install -q --upgrade pip
"$LL_DIR/venv/bin/pip" install -q --upgrade 'litellm[proxy]'
ok "litellm $("$LL_DIR/venv/bin/litellm" --version 2>&1 | head -1)"

ok "build done"
