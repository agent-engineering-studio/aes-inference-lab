#!/usr/bin/env bash
# Orchestrator. Runs the phases in order, stopping at the first error.
#
#   sudo ./install.sh              all phases, with confirmations
#   sudo ./install.sh --yes        no confirmations (warning: downloads 372 GB)
#   sudo ./install.sh 20 40        only the specified phases
#
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"

PHASES=(01-autoconfig 02-preflight 10-system-tuning 20-build-inference 30-fetch-models
        40-install-services 50-docker-tuning 90-verify)

ARGS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) export ASSUME_YES=1 ;;
    --list)   printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    *)        ARGS+=("$a") ;;
  esac
done

selected=()
if [[ ${#ARGS[@]} -eq 0 ]]; then
  selected=("${PHASES[@]}")
else
  for a in "${ARGS[@]}"; do
    for p in "${PHASES[@]}"; do [[ "$p" == "$a"* ]] && selected+=("$p"); done
  done
  [[ ${#selected[@]} -gt 0 ]] || die "no phase matches: ${ARGS[*]}"
fi

log "phases to run: ${selected[*]}"
for p in "${selected[@]}"; do
  step "PHASE $p"
  bash "$ROOT/scripts/$p.sh" || die "phase $p failed"
done
ok "done"
