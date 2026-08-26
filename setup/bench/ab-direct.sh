#!/usr/bin/env bash
# A/B test of DIRECT=1 on colibri, with a warm cache.
# Reported at +34% on some drives and neutral/negative on QLC or DRAM-less:
# it must be measured, not assumed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_cmd jq
need_cmd bc

DEFAULT_PROMPT="Explain in three sentences what open data is and why it matters for a municipality."
PROMPT="${1:-$DEFAULT_PROMPT}"
RUNS="${2:-3}"
OUT="$ROOT/docs/MISURE-direct-$(date +%Y%m%d-%H%M).md"
API="http://127.0.0.1:${PORT_COLIBRI}"
DROPIN=/etc/systemd/system/colibri.service.d/ab.conf

payload() {   # max_tokens
  jq -n --arg p "$PROMPT" --argjson m "$1" \
    '{model:"glm52", messages:[{role:"user", content:$p}], max_tokens:$m}'
}

wait_ready() {
  log "waiting for colibri (loads ~10 GB of dense set)"
  local i
  for i in $(seq 1 180); do
    if curl -fsS --max-time 5 "$API/v1/models" >/dev/null 2>&1; then
      ok "ready after ~$((i*5))s"
      return 0
    fi
    sleep 5
  done
  die "colibri not responding on $API"
}

run_case() {  # label direct_value
  local label="$1" direct="$2"
  step "case: $label"
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nEnvironment=DIRECT=%s\n' "$direct" > "$DROPIN"
  systemctl daemon-reload
  systemctl restart colibri
  wait_ready

  # Warmup: the .coli_usage learning cache improves with repeated use,
  # so a cold comparison systematically penalizes the large model.
  log "warmup"
  curl -fsS --max-time 3600 "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(payload 64)" >/dev/null 2>&1 \
    || warn "warmup failed"

  local total=0 i t0 t1 toks tps
  for i in $(seq 1 "$RUNS"); do
    t0=$(date +%s.%N)
    toks=$(curl -fsS --max-time 3600 "$API/v1/chat/completions" \
             -H 'Content-Type: application/json' -d "$(payload 128)" \
             | jq -r '.usage.completion_tokens // 0')
    t1=$(date +%s.%N)
    tps=$(echo "scale=4; $toks / ($t1 - $t0)" | bc -l)
    printf '     run %s: %s tokens, %s tok/s\n' "$i" "$toks" "$tps"
    total=$(echo "scale=4; $total + $tps" | bc -l)
  done
  printf '| %s | %.3f |\n' "$label" "$(echo "scale=4; $total / $RUNS" | bc -l)" >> "$OUT"
}

{
  printf '# A/B DIRECT=1 — %s\n\n' "$(date -Is)"
  printf 'Prompt: %s\n\n' "$PROMPT"
  printf 'Runs per case: %s · warm cache (warmup before each series)\n\n' "$RUNS"
  printf '| case | mean tok/s |\n'
  printf '|---|---|\n'
} > "$OUT"

run_case "DIRECT=0 (page cache)" 0
run_case "DIRECT=1 (O_DIRECT)" 1

rm -f "$DROPIN"
systemctl daemon-reload
systemctl restart colibri
wait_ready

echo
cat "$OUT"
ok "keep the value your hardware rewards and set it in the colibri unit"
