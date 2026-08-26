#!/usr/bin/env bash
# Scarica GGUF piccoli e (con conferma) il container GLM-5.2 da 372 GB.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_mount "$MODELS_DIR"

export HF_HOME HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p "$HF_HOME" "$GGUF_DIR" "$(dirname "$COLIBRI_MODEL_DIR")"

# In un venv dedicato: 'pip --break-system-packages' fallisce quando deve
# aggiornare un pacchetto installato da Debian (niente file RECORD).
step "Strumenti Hugging Face"
HF_VENV="$OPT_DIR/hf-tools/venv"
if [[ ! -x "$HF_VENV/bin/pip" ]]; then
  python3 -m venv "$HF_VENV" || die "creazione del venv fallita (serve python3-venv)"
fi
"$HF_VENV/bin/pip" install -q --upgrade pip
"$HF_VENV/bin/pip" install -q --upgrade huggingface_hub hf_transfer
# Le versioni recenti rinominano il comando in 'hf'; teniamo entrambi.
if   [[ -x "$HF_VENV/bin/hf" ]];               then HFCLI="$HF_VENV/bin/hf"
elif [[ -x "$HF_VENV/bin/huggingface-cli" ]];  then HFCLI="$HF_VENV/bin/huggingface-cli"
else die "nessun client Hugging Face nel venv"; fi
ok "$("$HFCLI" version 2>&1 | head -1)  ($HFCLI)"

dl_file() {   # repo file
  local repo="$1" file="$2"
  [[ -n "$repo" && -n "$file" ]] || die "repo/file non configurati in .env"
  if [[ -f "$GGUF_DIR/$file" ]]; then ok "gia' presente: $file"; return; fi
  log "scarico $repo :: $file"
  "$HFCLI" download "$repo" "$file" --local-dir "$GGUF_DIR"
  ok "$file ($(du -h "$GGUF_DIR/$file" | cut -f1))"
}

step "Embedding — 1024 dimensioni, cablato in REDIS_VECTOR_DIM di knowledge-graph"
dl_file "$HF_EMBED_REPO" "$HF_EMBED_FILE"

step "Modelli conversazionali"
dl_file "$HF_CHAT4B_REPO" "$HF_CHAT4B_FILE"
dl_file "$HF_CHAT8B_REPO" "$HF_CHAT8B_FILE"

step "Quota GGUF"
xfs_quota -x -c 'report -p -h' "$MODELS_DIR" 2>/dev/null | sed 's/^/     /' || \
  warn "quota non leggibile (serve root o prjquota non attiva)"

# ── GLM-5.2 ──────────────────────────────────────────────────
step "colibri — GLM-5.2 int4 gs64 con testa MTP int8"
if [[ -d "$COLIBRI_MODEL_DIR" ]] && [[ -n "$(ls -A "$COLIBRI_MODEL_DIR" 2>/dev/null)" ]]; then
  ok "directory gia' popolata: $COLIBRI_MODEL_DIR"
else
  warn "sono ~372 GB. HF_HOME punta a $HF_HOME (HDD) per non pagare due volte lo spazio su NVMe."
  confirm "avvio il download di GLM-5.2?" || { warn "saltato"; exit 0; }
  "$HFCLI" download "$HF_GLM_REPO" --local-dir "$COLIBRI_MODEL_DIR"
fi

step "Verifica testa MTP (int4 => 0% di draft acceptance)"
mapfile -t MTP < <(find "$COLIBRI_MODEL_DIR" -maxdepth 1 -name 'out-mtp-*' -printf '%s\n' | sort -n)
if [[ ${#MTP[@]} -eq 0 ]]; then
  warn "nessun file out-mtp-* trovato: verifica manualmente"
else
  printf '     dimensioni trovate: %s\n' "${MTP[*]}"
  if [[ " ${MTP[*]} " == *" 1065950496 "* && " ${MTP[*]} " == *" 3527131672 "* && " ${MTP[*]} " == *" 5366238584 "* ]]; then
    ok "testa MTP int8 confermata"
  else
    warn "dimensioni diverse dalle attese (1065950496 / 3527131672 / 5366238584)"
    warn "se e' int4 la speculazione avra' 0% di acceptance: verifica il repo scaricato"
  fi
fi

ok "modelli pronti"
