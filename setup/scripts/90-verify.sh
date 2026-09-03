#!/usr/bin/env bash
# End-to-end verification. Writes a report to docs/REPORT-<date>.md
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"

# A failed check must not abort the report: it is recorded and the script
# exits non-zero at the end, so install.sh still stops on it.
FAILED=0
fail() { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; FAILED=$((FAILED + 1)); }

REPORT="$ROOT/docs/REPORT-$(date +%Y%m%d-%H%M).md"
exec > >(tee "$REPORT") 2>&1
echo "# Verification report — $(date -Is)"

step "Services"
for s in colibri llama-swap llama-embed litellm docker; do
  printf '     %-12s %s\n' "$s" "$(systemctl is-active "$s.service" 2>/dev/null || echo absent)"
done

step "Secrets"
SECRETS_FILE="${SECRETS_FILE:-/etc/inference/secrets.env}"
COLI_KEY=""
if [[ ! -f "$SECRETS_FILE" ]]; then
  fail "$SECRETS_FILE missing: the units declare EnvironmentFile= on it and will not start. Run 'sudo ./install.sh 40'."
else
  mode="$(stat -c '%a' "$SECRETS_FILE")"
  if [[ "$mode" == "640" ]]; then
    ok "$SECRETS_FILE $(stat -c '%a %U:%G' "$SECRETS_FILE")"
  else
    fail "$SECRETS_FILE has mode $mode, expected 640 (root:inference). Fix: chown root:inference $SECRETS_FILE && chmod 0640 $SECRETS_FILE"
  fi
  # The value is read but never printed: this report is a file in docs/.
  COLI_KEY="$(grep -m1 '^COLI_API_KEY=' "$SECRETS_FILE" | cut -d= -f2- || true)"
  if [[ -n "$COLI_KEY" ]]; then
    ok "COLI_API_KEY present (${#COLI_KEY} chars, value not shown)"
  else
    fail "COLI_API_KEY empty in $SECRETS_FILE: colibri refuses any bind beyond 127.0.0.1 without it and would restart forever."
  fi
fi

step "The key reaches the processes"
if [[ $EUID -ne 0 ]]; then
  warn "not root: /proc/<pid>/environ unreadable, check skipped (re-run with sudo)"
elif [[ -z "$COLI_KEY" ]]; then
  warn "no key to look for: check skipped"
else
  for svc in colibri litellm; do
    pid="$(systemctl show -p MainPID --value "$svc.service" 2>/dev/null || echo 0)"
    if [[ -z "$pid" || "$pid" == "0" ]]; then
      fail "$svc is not running: cannot verify that COLI_API_KEY is in its environment"
    elif ! [[ -r "/proc/$pid/environ" ]]; then
      fail "/proc/$pid/environ unreadable for $svc"
    elif tr '\0' '\n' < "/proc/$pid/environ" | grep -qxF "COLI_API_KEY=$COLI_KEY"; then
      ok "$svc (pid $pid) has COLI_API_KEY in its environment"
    else
      fail "$svc (pid $pid) does NOT have the current COLI_API_KEY: the unit is missing EnvironmentFile=$SECRETS_FILE, or it was started before the file changed. Fix: systemctl daemon-reload && systemctl restart $svc"
    fi
  done
fi

step "colibri authenticated endpoint"
if [[ -z "$COLI_KEY" ]]; then
  warn "no key: check skipped"
else
  # --config on stdin, not -H: an Authorization header on the command line
  # would be visible in 'ps' to every user on the machine.
  ids="$(printf 'header = "Authorization: Bearer %s"\nurl = "http://127.0.0.1:%s/v1/models"\n' \
           "$COLI_KEY" "$PORT_COLIBRI" \
         | curl -fsS --max-time 20 --config - 2>/dev/null \
         | jq -r '.data[].id' 2>/dev/null | paste -sd, || true)"
  if [[ -z "$ids" ]]; then
    fail "GET /v1/models on colibri (:$PORT_COLIBRI) returned nothing: engine down, key wrong, or Host rejected by the DNS-rebinding guard (COLI_ALLOWED_HOSTS)."
  elif [[ ",$ids," == *",$COLI_MODEL_ID,"* ]]; then
    ok "colibri exposes '$COLI_MODEL_ID' (models: $ids)"
  else
    fail "colibri answers but exposes '$ids' while COLI_MODEL_ID=$COLI_MODEL_ID: the LiteLLM route 'openai/$COLI_MODEL_ID' will 404."
  fi
fi

step "Restart counters"
# The incident this check exists for: 1447 restarts nobody noticed.
for svc in colibri llama-swap llama-embed litellm; do
  n="$(systemctl show -p NRestarts --value "$svc.service" 2>/dev/null || true)"
  n="${n:-0}"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 3 )); then
    fail "$svc restarted $n times: it is crash-looping, not running. Last lines:"
    journalctl -u "$svc.service" -n 15 --no-pager 2>/dev/null | sed 's/^/     /' || true
  else
    ok "$svc restarts: $n"
  fi
done

step "Exposure of the listening ports"
for pair in "colibri:$PORT_COLIBRI" "llama-swap:$PORT_LLAMA_SWAP" \
            "llama-embed:$PORT_EMBED" "litellm:$PORT_LITELLM"; do
  svc="${pair%%:*}" port="${pair##*:}"
  [[ -n "$port" ]] || continue
  ss -tlnH "sport = :$port" | awk '{print $4}' \
    | grep -qE '^(0\.0\.0\.0|\*|\[::\]):' || continue
  # Wide bind is the intended configuration; what must exist is a rule
  # narrowing who may use it. This is a warning, never a failure: the
  # boundary may legitimately live somewhere else.
  if ! command -v ufw >/dev/null 2>&1; then
    warn "$svc listens on 0.0.0.0:$port and ufw is not installed: nothing limits access"
  elif ufw status 2>/dev/null | head -1 | grep -q inactive; then
    warn "$svc listens on 0.0.0.0:$port and ufw is INACTIVE: the port is open to the whole LAN"
  else
    rules="$(ufw status 2>/dev/null | awk -v p="$port/tcp" '$1 == p' || true)"
    if [[ -z "$rules" ]]; then
      warn "$svc listens on 0.0.0.0:$port but no ufw rule covers it — run 'sudo ./install.sh 45'"
    elif grep -q 'Anywhere' <<< "$rules"; then
      warn "$svc :$port is allowed from Anywhere: the rule does not limit anything"
    else
      ok "$svc :$port limited to $(awk '{print $NF}' <<< "$rules" | paste -sd' ')"
    fi
  fi
done

step "Storage"
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS -t xfs,ext4 | sed 's/^/     /'
df -hT | grep -E 'vg0|vg1' | sed 's/^/     /'

step "GPU and memory"
nvidia-smi --query-gpu=name,compute_cap,memory.total,memory.used --format=csv | sed 's/^/     /'
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | sed 's/^/     /'
free -h | sed 's/^/     /'

step "Endpoint"
gw="http://127.0.0.1:$PORT_LITELLM"
if curl -fsS --max-time 10 "$gw/v1/models" >/dev/null 2>&1; then
  ok "gateway responds"
  curl -fsS "$gw/v1/models" | jq -r '.data[].id' | sed 's/^/     model: /'
else
  warn "gateway not responding on $gw"
fi

dim=$(curl -fsS --max-time 30 "$gw/v1/embeddings" -H 'Content-Type: application/json' \
      -d '{"model":"embed","input":"embedding test in Italian"}' 2>/dev/null \
      | jq -r '.data[0].embedding | length' 2>/dev/null || echo 0)
if [[ "$dim" == "1024" ]]; then ok "embedding: 1024 dimensions"
else warn "embedding: expected 1024 dimensions, got '$dim'"; fi

if curl -fsS --max-time 60 "$gw/v1/chat/completions" -H 'Content-Type: application/json' \
   -d '{"model":"fast","messages":[{"role":"user","content":"hello"}],"max_tokens":16}' >/dev/null 2>&1; then
  ok "chat 'fast' responds"
else warn "chat 'fast' not responding (the first load into VRAM can take time)"; fi

step "Models LV bandwidth (pattern similar to expert reads: 19 MiB random)"
if command -v fio >/dev/null 2>&1; then
  fio --name=expert --filename="$MODELS_DIR/.fiotest" --size=4G \
      --rw=randread --bs=19m --iodepth=8 --numjobs=4 --direct=1 \
      --group_reporting --output-format=terse 2>/dev/null \
      | awk -F';' '{printf "     read: %.0f MB/s  iops: %s\n", $7/1024, $8}'
  rm -f "$MODELS_DIR/.fiotest"
else
  warn "fio not installed: apt install fio"
fi

step "Both NVMe must work during inference"
warn "run by hand, during a colibri session: iostat -xm 2"
warn "nvme0n1 and nvme1n1 must have similar r/s — if only one drive works, striping is not active"

echo
ok "report saved to $REPORT"
if (( FAILED )); then
  die "$FAILED check(s) FAILED — see the FAIL lines above and in $REPORT"
fi
