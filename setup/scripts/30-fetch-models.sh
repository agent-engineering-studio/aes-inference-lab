#!/usr/bin/env bash
# Downloads small GGUF files and (with confirmation) the 372 GB GLM-5.2 container.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_mount "$MODELS_DIR"

export HF_HOME HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p "$HF_HOME" "$GGUF_DIR" "$(dirname "$COLIBRI_MODEL_DIR")"

# In a dedicated venv: 'pip --break-system-packages' fails when it has to
# upgrade a package installed by Debian (no RECORD file).
step "Hugging Face tools"
HF_VENV="$OPT_DIR/hf-tools/venv"
if [[ ! -x "$HF_VENV/bin/pip" ]]; then
  python3 -m venv "$HF_VENV" || die "venv creation failed (python3-venv required)"
fi
"$HF_VENV/bin/pip" install -q --upgrade pip
"$HF_VENV/bin/pip" install -q --upgrade huggingface_hub hf_transfer
# Recent versions rename the command to 'hf'; we keep both.
if   [[ -x "$HF_VENV/bin/hf" ]];               then HFCLI="$HF_VENV/bin/hf"
elif [[ -x "$HF_VENV/bin/huggingface-cli" ]];  then HFCLI="$HF_VENV/bin/huggingface-cli"
else die "no Hugging Face client in the venv"; fi
ok "$("$HFCLI" version 2>&1 | head -1)  ($HFCLI)"

dl_file() {   # repo file
  local repo="$1" file="$2"
  [[ -n "$repo" && -n "$file" ]] || die "repo/file not configured in .env"
  if [[ -f "$GGUF_DIR/$file" ]]; then ok "already present: $file"; return; fi
  log "downloading $repo :: $file"
  "$HFCLI" download "$repo" "$file" --local-dir "$GGUF_DIR"
  ok "$file ($(du -h "$GGUF_DIR/$file" | cut -f1))"
}

step "Embedding — 1024 dimensions, wired into knowledge-graph's REDIS_VECTOR_DIM"
dl_file "$HF_EMBED_REPO" "$HF_EMBED_FILE"

step "Conversational models"
dl_file "$HF_CHAT4B_REPO" "$HF_CHAT4B_FILE"
dl_file "$HF_CHAT8B_REPO" "$HF_CHAT8B_FILE"

step "GGUF quota"
xfs_quota -x -c 'report -p -h' "$MODELS_DIR" 2>/dev/null | sed 's/^/     /' || \
  warn "quota not readable (root required or prjquota not active)"

# ── GLM-5.2 ──────────────────────────────────────────────────
step "colibri — GLM-5.2 int4 gs64 with int8 MTP head"
if [[ -d "$COLIBRI_MODEL_DIR" ]] && [[ -n "$(ls -A "$COLIBRI_MODEL_DIR" 2>/dev/null)" ]]; then
  ok "directory already populated: $COLIBRI_MODEL_DIR"
else
  warn "this is ~372 GB. HF_HOME points to $HF_HOME (HDD) so the NVMe space is not paid for twice."
  confirm "start the GLM-5.2 download?" || { warn "skipped"; exit 0; }
  "$HFCLI" download "$HF_GLM_REPO" --local-dir "$COLIBRI_MODEL_DIR"
fi

step "MTP head check (int4 => 0% draft acceptance)"
mapfile -t MTP < <(find "$COLIBRI_MODEL_DIR" -maxdepth 1 -name 'out-mtp-*' -printf '%s\n' | sort -n)
if [[ ${#MTP[@]} -eq 0 ]]; then
  warn "no out-mtp-* file found: check manually"
else
  printf '     sizes found: %s\n' "${MTP[*]}"
  if [[ " ${MTP[*]} " == *" 1065950496 "* && " ${MTP[*]} " == *" 3527131672 "* && " ${MTP[*]} " == *" 5366238584 "* ]]; then
    ok "int8 MTP head confirmed"
  else
    warn "sizes differ from the expected (1065950496 / 3527131672 / 5366238584)"
    warn "if it is int4 speculation will have 0% acceptance: check the downloaded repo"
  fi
fi

ok "models ready"
