#!/usr/bin/env bash
# Funzioni condivise. Va sourced, non eseguito.

set -euo pipefail

readonly C_RED=$'\033[0;31m' C_GRN=$'\033[0;32m' C_YEL=$'\033[0;33m'
readonly C_BLU=$'\033[0;34m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s ERR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
step() { printf '\n%s── %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

ASSUME_YES="${ASSUME_YES:-0}"

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" == "1" ]] && { ok "auto-conferma: $prompt"; return 0; }
  local reply
  read -r -p "$(printf '%s  ?? %s%s [s/N] ' "$C_YEL" "$C_OFF" "$prompt")" reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

need_root()  { [[ $EUID -eq 0 ]] || die "serve root: rilancia con sudo"; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "comando mancante: $1"; }

need_mount() {
  findmnt -n "$1" >/dev/null 2>&1 || die "non montato: $1 (completa prima il setup storage)"
}

# Carica .env accanto al repo, poi eventuale override locale.
load_env() {
  local root="$1"
  [[ -f "$root/.env" ]] || die "manca $root/.env — copia .env.example e adattalo"
  set -a
  # shellcheck disable=SC1090
  source "$root/.env"
  set +a
}

# Scrive un file solo se cambia, mostrando il diff. Idempotente.
install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    ok "invariato $dst"
    return 0
  fi
  if [[ -f "$dst" ]]; then
    warn "sovrascrivo $dst — diff:"
    diff -u "$dst" "$src" | sed 's/^/     /' || true
    confirm "procedo con $dst?" || { warn "saltato $dst"; return 0; }
    cp -a "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -D -m "$mode" "$src" "$dst"
  ok "scritto $dst"
}

# CPU del socket indicato (default 1). Vuoto se la macchina è single-socket.
socket_cpus() {
  local node="${1:-1}"
  lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, -v n="$node" '$2==n{print $1}' | paste -sd,
}

port_free() {
  ! ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
}
