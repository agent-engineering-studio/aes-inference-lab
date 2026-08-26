#!/usr/bin/env bash
# Orchestratore. Esegue le fasi in ordine, fermandosi al primo errore.
#
#   sudo ./install.sh              tutte le fasi, con conferme
#   sudo ./install.sh --yes        senza conferme (attenzione: scarica 372 GB)
#   sudo ./install.sh 20 40        solo le fasi indicate
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
  [[ ${#selected[@]} -gt 0 ]] || die "nessuna fase corrisponde a: ${ARGS[*]}"
fi

log "fasi da eseguire: ${selected[*]}"
for p in "${selected[@]}"; do
  step "FASE $p"
  bash "$ROOT/scripts/$p.sh" || die "fase $p fallita"
done
ok "completato"
