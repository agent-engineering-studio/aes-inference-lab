#!/usr/bin/env bash
# Legge l'hardware e compila .env con i valori corretti.
#
#   ./scripts/01-autoconfig.sh              interattivo
#   ./scripts/01-autoconfig.sh --dry-run    mostra soltanto la proposta
#   ./scripts/01-autoconfig.sh --no-models  salta la ricerca su Hugging Face
#   ASSUME_YES=1 ./scripts/01-autoconfig.sh sceglie da solo il primo candidato
#
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

DRY_RUN=0; DO_MODELS=1
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY_RUN=1 ;;
    --no-models) DO_MODELS=0 ;;
    --yes|-y)    export ASSUME_YES=1 ;;
    *) die "argomento sconosciuto: $a" ;;
  esac
done

ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
  ok "creato .env da .env.example"
fi

declare -A NEW=()
propose() { NEW["$1"]="$2"; }

cur() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true; }

# ── GPU ──────────────────────────────────────────────────────
step "GPU"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
  VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  ok "$GPU_NAME — compute_cap $CC — ${VRAM_MIB} MiB"
  propose CUDA_ARCH "${CC//./}"

  # Su Turing+ la GPU rende molto di piu' ai modelli piccoli: 6 GB di tier
  # esperti sono ~315 dei 19.456 esperti di GLM-5.2, l'1,6%. Su Pascal non
  # c'e' fp16 utilizzabile e la scelta si inverte.
  CC_MAJOR="${CC%%.*}"
  if (( CC_MAJOR >= 7 )); then
    propose COLI_CUDA_EXPERT_GB 0
    COLI_VRAM_MIB=1536
    ok "Turing o superiore: GPU ai modelli piccoli, colibri con CUDA_EXPERT_GB=0"
  else
    RESERVE=$(( VRAM_MIB > 2048 ? VRAM_MIB - 1024 : 0 ))
    propose COLI_CUDA_EXPERT_GB $(( RESERVE / 1024 ))
    COLI_VRAM_MIB="$RESERVE"
    warn "Pascal o precedente: niente fp16/bf16 utilizzabili"
    warn "  → GPU a colibri, llama.cpp su CPU (metti -ngl 0 in etc/llama-swap/config.yaml)"
  fi

  # Contesti in base alla VRAM che resta a llama.cpp.
  USABLE=$(( VRAM_MIB - COLI_VRAM_MIB - 512 ))
  ok "VRAM per llama.cpp: ~${USABLE} MiB"
  if   (( USABLE >= 6000 )); then propose CTX_CHAT4B 32768; propose CTX_CHAT8B 16384
  elif (( USABLE >= 4500 )); then propose CTX_CHAT4B 32768; propose CTX_CHAT8B 8192
  elif (( USABLE >= 3000 )); then propose CTX_CHAT4B 16384; propose CTX_CHAT8B 8192
  else propose CTX_CHAT4B 8192; propose CTX_CHAT8B 4096
       warn "VRAM stretta: valuta di rinunciare all'8B"
  fi
  warn "i contesti sono una stima: verificali con 'nvidia-smi' a modello caricato"
else
  warn "driver NVIDIA assente: salto CUDA_ARCH e contesti"
fi

# ── CPU e NUMA ───────────────────────────────────────────────
step "CPU e NUMA"
CPUS=$(socket_cpus 1)
NPROC=$(nproc)
if [[ -n "$CPUS" ]]; then
  propose SOCKET1_CPUS "$CPUS"
  ok "socket 1: $CPUS"
else
  warn "single socket: lascio SOCKET1_CPUS vuoto (AllowedCPUs verra' omesso)"
fi
if   (( NPROC >= 24 )); then propose PARALLEL_EXTRACT 8
elif (( NPROC >= 12 )); then propose PARALLEL_EXTRACT 6
else propose PARALLEL_EXTRACT 4; fi
ok "$NPROC thread → PARALLEL_EXTRACT $(printf '%s' "${NEW[PARALLEL_EXTRACT]}")"

# ── RAM e budget Docker ──────────────────────────────────────
step "RAM"
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
ok "${RAM_GB} GiB totali"
# Riservati: set denso colibri 10 + llama 1 + litellm/embed 2 + OS 2 = 15,
# piu' almeno 6 GiB di cache esperti, che e' la leva della tok/s.
DH=$(( RAM_GB - 23 )); (( DH < 4 )) && DH=4; (( DH > 16 )) && DH=16
propose DOCKER_MEMORY_HIGH "${DH}G"
propose DOCKER_MEMORY_MAX  "$(( DH + 3 ))G"
ok "docker.slice: MemoryHigh=${DH}G MemoryMax=$(( DH + 3 ))G"
if (( RAM_GB < 64 )); then
  warn "con ${RAM_GB} GiB la cache esperti resta sotto il 2% del modello."
  warn "  portare la RAM a 128 GB e' l'upgrade con il ritorno piu' alto su questo server."
fi

# ── Storage ──────────────────────────────────────────────────
step "Storage"
for pair in "MODELS_DIR:/srv/models" "ARCHIVE_DIR:/srv/archive"; do
  var="${pair%%:*}"; path="${pair##*:}"
  if findmnt -n "$path" >/dev/null 2>&1; then propose "$var" "$path"; ok "$path montato"
  else warn "$path NON montato: verifica lo storage prima di procedere"; fi
done
propose HF_HOME "$(printf '%s' "${NEW[ARCHIVE_DIR]:-/srv/archive}")/hf"
propose GGUF_DIR "$(printf '%s' "${NEW[MODELS_DIR]:-/srv/models}")/gguf"
propose COLIBRI_MODEL_DIR "$(printf '%s' "${NEW[MODELS_DIR]:-/srv/models}")/colibri/glm52_i4"

# ── Porte ────────────────────────────────────────────────────
step "Porte"
for pair in "PORT_COLIBRI:8070" "PORT_LLAMA_SWAP:8081" "PORT_EMBED:8082" "PORT_LITELLM:8091"; do
  var="${pair%%:*}"; p="$(cur "$var")"; p="${p:-${pair##*:}}"
  if port_free "$p"; then ok "$var=$p libera"
  else warn "$var=$p GIA' OCCUPATA da: $(ss -tlnpH "sport = :$p" | head -1 | sed 's/.*users:((//;s/).*//')"; fi
done

# ── Modelli su Hugging Face ──────────────────────────────────
hf_tree() { curl -fsSL --max-time 20 "https://huggingface.co/api/models/$1/tree/main?recursive=true" 2>/dev/null; }

hf_find() {   # search min_bytes max_bytes  →  righe "repo<TAB>file<TAB>GB"
  local q="$1" lo="$2" hi="$3" repo
  curl -fsSL --max-time 20 \
    "https://huggingface.co/api/models?search=$(printf '%s' "$q" | sed 's/ /+/g')&filter=gguf&sort=downloads&direction=-1&limit=12" \
    2>/dev/null | jq -r '.[].id' | while read -r repo; do
      hf_tree "$repo" | jq -r --argjson lo "$lo" --argjson hi "$hi" --arg r "$repo" '
        .[]? | select(.path | test("Q4_K_M\\.gguf$"; "i"))
             | select(.path | test("-0000[0-9]-of-") | not)
             | (.lfs.size // .size) as $s
             | select($s >= $lo and $s <= $hi)
             | [$r, .path, (($s/1073741824*100|floor)/100|tostring)] | @tsv' 2>/dev/null
    done | head -8
}

pick_model() {  # etichetta var_repo var_file search lo hi
  local label="$1" vrepo="$2" vfile="$3" q="$4" lo="$5" hi="$6"
  step "Modello $label — cerco su Hugging Face: \"$q\""
  mapfile -t C < <(hf_find "$q" "$lo" "$hi")
  if [[ ${#C[@]} -eq 0 ]]; then
    warn "nessun candidato per \"$q\". Compila a mano $vrepo e $vfile in .env"
    return
  fi
  local i=1
  for line in "${C[@]}"; do
    printf '     %d) %s  ·  %s  ·  %s GB\n' "$i" "$(cut -f1 <<<"$line")" "$(cut -f2 <<<"$line")" "$(cut -f3 <<<"$line")"
    ((i++))
  done
  local sel=1
  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "$(printf '%s  ?? %sscegli [1-%d, invio=1, s=salta] ' "$C_YEL" "$C_OFF" "${#C[@]}")" sel
    [[ "$sel" == "s" ]] && { warn "saltato $label"; return; }
    sel="${sel:-1}"
  fi
  local chosen="${C[$((sel-1))]}"
  propose "$vrepo" "$(cut -f1 <<<"$chosen")"
  propose "$vfile" "$(cut -f2 <<<"$chosen")"
  ok "$label → $(cut -f1 <<<"$chosen") :: $(cut -f2 <<<"$chosen")"
}

if [[ "$DO_MODELS" == "1" ]]; then
  if command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    SEARCH_4B="${SEARCH_4B:-Qwen3-4B-Instruct GGUF}"
    SEARCH_8B="${SEARCH_8B:-Qwen3-8B GGUF}"
    pick_model "4B"  HF_CHAT4B_REPO HF_CHAT4B_FILE "$SEARCH_4B" 2000000000 3600000000
    pick_model "8B"  HF_CHAT8B_REPO HF_CHAT8B_FILE "$SEARCH_8B" 4000000000 6200000000
    warn "per cercare altre famiglie: SEARCH_4B='gemma-3-4b-it GGUF' $0"
  else
    warn "servono jq e curl per la ricerca su Hugging Face: apt install jq curl"
  fi
fi

# ── Applica ──────────────────────────────────────────────────
step "Differenze rispetto a .env"
CHANGED=0
for k in $(printf '%s\n' "${!NEW[@]}" | sort); do
  old="$(cur "$k")"; new="${NEW[$k]}"
  if [[ "$old" == "$new" ]]; then
    printf '     %-22s %s %s(invariato)%s\n' "$k" "$new" "$C_DIM" "$C_OFF"
  else
    printf '     %-22s %s%s%s → %s%s%s\n' "$k" "$C_DIM" "${old:-<vuoto>}" "$C_OFF" "$C_GRN" "$new" "$C_OFF"
    CHANGED=1
  fi
done

if [[ "$CHANGED" -eq 0 ]]; then ok ".env gia' allineato all'hardware"; exit 0; fi
if [[ "$DRY_RUN" == "1" ]]; then warn "--dry-run: non scrivo nulla"; exit 0; fi
confirm "scrivo queste modifiche in .env?" || { warn "annullato"; exit 0; }

cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
for k in "${!NEW[@]}"; do
  v="${NEW[$k]}"
  if grep -qE "^$k=" "$ENV_FILE"; then
    # delimitatore | e valore senza | : i path non ne contengono
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
done
ok "scritto $ENV_FILE (backup accanto)"

step "Cosa resta da fare a mano"
[[ -n "$(cur ANTHROPIC_API_KEY)" ]] \
  && ok "ANTHROPIC_API_KEY presente: il tier 'quality-cloud' sara' attivo" \
  || warn "ANTHROPIC_API_KEY vuota: resta solo 'quality-local' (colibri). Opzionale."
for v in HF_CHAT4B_REPO HF_CHAT4B_FILE HF_CHAT8B_REPO HF_CHAT8B_FILE; do
  [[ -n "$(cur "$v")" ]] || warn "$v ancora vuoto"
done
ok "ora: sudo ./install.sh 02   (preflight)"
