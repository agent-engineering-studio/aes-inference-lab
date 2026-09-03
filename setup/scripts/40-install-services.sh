#!/usr/bin/env bash
# Renders the templates, installs the systemd units, starts the four services.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_cmd envsubst

# Variables substituted in the templates. Explicit list: everything else
# (e.g. llama-swap's ${PORT}, ${srv}) stays literal.
export SOCKET1_CPUS="${SOCKET1_CPUS:-$(socket_cpus 1)}"
[[ -n "$SOCKET1_CPUS" ]] || { warn "SOCKET1_CPUS empty: removing AllowedCPUs"; }

# Listening addresses. BIND_ADDR is the legacy single knob and stays as the
# fallback for the per-service variables; 127.0.0.1 is not a usable default
# here, because a container reaches the host through the bridge address and
# never through its loopback. What limits access is ufw, not the bind.
export BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
export COLI_HOST="${COLI_HOST:-$BIND_ADDR}"
export LLAMA_SWAP_HOST="${LLAMA_SWAP_HOST:-$BIND_ADDR}"
export LLAMA_EMBED_HOST="${LLAMA_EMBED_HOST:-$BIND_ADDR}"
export LITELLM_HOST="${LITELLM_HOST:-0.0.0.0}"
for pair in "colibri:$COLI_HOST" "llama-swap:$LLAMA_SWAP_HOST" \
            "llama-embed:$LLAMA_EMBED_HOST" "litellm:$LITELLM_HOST"; do
  [[ "${pair##*:}" == "127.0.0.1" ]] \
    && warn "${pair%%:*} listens on loopback only: no container will reach it"
done

# Shared secrets file, read by every unit through EnvironmentFile=.
export SECRETS_FILE="${SECRETS_FILE:-/etc/inference/secrets.env}"
SECRETS_DIR="$(dirname "$SECRETS_FILE")"

VARS='$OPT_DIR $MODELS_DIR $GGUF_DIR $COLIBRI_MODEL_DIR $ARCHIVE_DIR
$PORT_COLIBRI $PORT_LLAMA_SWAP $PORT_EMBED $PORT_LITELLM
$COLI_CUDA_EXPERT_GB $SOCKET1_CPUS $COLI_ALLOWED_HOSTS
$SECRETS_FILE $COLI_HOST $LLAMA_SWAP_HOST $LLAMA_EMBED_HOST $LITELLM_HOST
$COLI_MODEL_ID $COLI_VRAM_GB $COLI_KV_SLOTS $COLI_POLICY
$HF_EMBED_FILE $HF_CHAT4B_FILE $HF_CHAT8B_FILE
$CTX_CHAT4B $CTX_CHAT8B $CTX_EXTRACT $PARALLEL_EXTRACT
$LITELLM_MAX_BUDGET $LITELLM_BUDGET_DURATION $LITELLM_CLOUD_MODEL
$DOCKER_MEMORY_HIGH $DOCKER_MEMORY_MAX'

# Units whose file changed in this run: only these get restarted, so a
# re-run does not needlessly reload colibri's ~10 GB.
CHANGED=()

render() {  # src dst [mode]
  local tmp; tmp=$(mktemp)
  envsubst "$VARS" < "$1" > "$tmp"
  # An empty AllowedCPUs is a parsing error: drop the line.
  [[ -z "$SOCKET1_CPUS" ]] && sed -i '/^AllowedCPUs=$/d' "$tmp"
  if ! { [[ -f "$2" ]] && cmp -s "$tmp" "$2"; }; then
    CHANGED+=("$(basename "$2" .service)")
  fi
  install_file "$tmp" "$2" "${3:-0644}"
  rm -f "$tmp"
}

# ── Secrets ──────────────────────────────────────────────────
# One file for every unit, created once and never rewritten: regenerating
# the key on each run would invalidate the consumers still holding the old
# one. 0640 root:inference, so a future non-root service can read it by
# joining the group without the file becoming world-readable.
step "Secrets"

# Banned on purpose: it switches colibri's bind check off instead of
# satisfying it, and leaves an unauthenticated engine on 0.0.0.0.
[[ -z "${COLI_ALLOW_INSECURE_BIND:-}" || "${COLI_ALLOW_INSECURE_BIND}" == "0" ]] \
  || die "COLI_ALLOW_INSECURE_BIND is set: remove it from .env. It bypasses colibri's security check instead of satisfying it — leave COLI_API_KEY empty and this phase generates one."

if getent group inference >/dev/null 2>&1; then
  ok "group 'inference' present"
else
  groupadd -f inference && ok "group 'inference' created"
fi
install -d -m 0750 -o root -g inference "$SECRETS_DIR"

# Migration from the first, hand-made installation. Idempotent: it only
# fires while the old path still exists and the new one does not.
for legacy in /etc/colibri/colibri.env /etc/colibri/env; do
  [[ -f "$legacy" ]] || continue
  if [[ -e "$SECRETS_FILE" ]]; then
    warn "$legacy still present while $SECRETS_FILE exists: nothing moved, delete $legacy by hand once you have compared them"
    continue
  fi
  mv "$legacy" "$SECRETS_FILE"
  ok "migrated $legacy -> $SECRETS_FILE"
done
if [[ -d /etc/colibri ]] && rmdir /etc/colibri 2>/dev/null; then
  ok "removed the now-empty /etc/colibri"
fi

if [[ -f "$SECRETS_FILE" ]]; then
  ok "$SECRETS_FILE already exists: left untouched (see README to rotate the key)"
else
  need_cmd openssl
  # Written straight into the file: the key never appears on a command
  # line, in a log, or in the output of this script.
  if [[ -n "${COLI_API_KEY:-}" ]]; then origin="taken from .env"
  else origin="generated with openssl rand -hex 32"; fi
  ( umask 077
    printf 'COLI_API_KEY=%s\n' "${COLI_API_KEY:-$(openssl rand -hex 32)}" > "$SECRETS_FILE" )
  ok "$SECRETS_FILE created (COLI_API_KEY $origin)"
fi
chown root:inference "$SECRETS_DIR" "$SECRETS_FILE"
chmod 0750 "$SECRETS_DIR"
chmod 0640 "$SECRETS_FILE"
ok "$(stat -c '%a %U:%G %n' "$SECRETS_FILE")"

# An empty value is worse than a missing file: colibri starts, refuses the
# bind and enters the restart loop this whole phase exists to prevent.
if ! grep -qE '^COLI_API_KEY=.+$' "$SECRETS_FILE"; then
  if [[ "$COLI_HOST" == "127.0.0.1" ]]; then
    warn "COLI_API_KEY empty in $SECRETS_FILE: tolerated only because COLI_HOST=127.0.0.1"
  else
    die "COLI_API_KEY empty in $SECRETS_FILE but COLI_HOST=$COLI_HOST: colibri would refuse the bind and restart forever. Fill the value in, or delete the file and re-run this phase to have one generated."
  fi
fi

step "Configurations"
render "$ROOT/etc/llama-swap/config.yaml" /etc/llama-swap/config.yaml
render "$ROOT/etc/litellm/config.yaml"    /etc/litellm/config.yaml

# Only the gateway's own secret lives here; COLI_API_KEY comes from
# SECRETS_FILE, which litellm.service reads first. Keeping the two apart
# avoids a stale copy of the key silently overriding the shared one.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  install -D -m 0600 /dev/stdin /etc/litellm/env <<< "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
  ok "cloud tier active (key in /etc/litellm/env, 0600)"
else
  install -D -m 0600 /dev/null /etc/litellm/env
  warn "ANTHROPIC_API_KEY empty: 'quality-cloud' will not be reachable, only the local one remains"
fi

step "Unit systemd"
render "$ROOT/etc/systemd/colibri.service"    /etc/systemd/system/colibri.service
render "$ROOT/etc/systemd/llama-swap.service" /etc/systemd/system/llama-swap.service
render "$ROOT/etc/systemd/llama-embed.service" /etc/systemd/system/llama-embed.service
render "$ROOT/etc/systemd/litellm.service"    /etc/systemd/system/litellm.service
systemctl daemon-reload

step "Startup"
[[ ${#CHANGED[@]} -gt 0 ]] && log "changed: ${CHANGED[*]}" || ok "no unit changed"
# Order: embedding and llama-swap first, colibri (slow to load) next,
# LiteLLM last so its health checks find the upstreams up.
for svc in llama-embed llama-swap colibri litellm; do
  systemctl enable "$svc.service" >/dev/null 2>&1 || true
  # 'enable --now' does not restart a unit that is already running: without
  # an explicit restart a re-rendered ExecStart would never take effect.
  if [[ " ${CHANGED[*]} " == *" $svc "* ]]; then
    log "$svc: unit changed, restarting"
    systemctl restart "$svc.service"
  else
    systemctl start "$svc.service"
  fi
  sleep 2
  if systemctl is-active --quiet "$svc.service"; then ok "$svc active"
  else
    warn "$svc NOT active — last logs:"
    journalctl -u "$svc.service" -n 20 --no-pager | sed 's/^/     /'
  fi
done

warn "colibri loads ~10 GB of dense set: it may take a few minutes before it responds"
ok "services installed"
