#!/usr/bin/env bash
# Shared functions. Meant to be sourced, not executed.

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
  [[ "$ASSUME_YES" == "1" ]] && { ok "auto-confirm: $prompt"; return 0; }
  local reply
  read -r -p "$(printf '%s  ?? %s%s [y/N] ' "$C_YEL" "$C_OFF" "$prompt")" reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

need_root()  { [[ $EUID -eq 0 ]] || die "root required: re-run with sudo"; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need_mount() {
  findmnt -n "$1" >/dev/null 2>&1 || die "not mounted: $1 (complete the storage setup first)"
}

# Load .env next to the repo, then an optional local override.
load_env() {
  local root="$1"
  [[ -f "$root/.env" ]] || die "missing $root/.env — copy .env.example and adapt it"
  set -a
  # shellcheck disable=SC1090
  source "$root/.env"
  set +a
}

# Writes a file only if it changes, showing the diff. Idempotent.
install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    ok "unchanged $dst"
    return 0
  fi
  if [[ -f "$dst" ]]; then
    warn "overwriting $dst — diff:"
    diff -u "$dst" "$src" | sed 's/^/     /' || true
    confirm "proceed with $dst?" || { warn "skipped $dst"; return 0; }
    cp -a "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -D -m "$mode" "$src" "$dst"
  ok "written $dst"
}

# CPUs of the given socket (default 1). Empty if the machine is single-socket.
socket_cpus() {
  local node="${1:-1}"
  lscpu -p=CPU,NODE 2>/dev/null | grep -v '^#' | awk -F, -v n="$node" '$2==n{print $1}' | paste -sd,
}

port_free() {
  ! ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
}
