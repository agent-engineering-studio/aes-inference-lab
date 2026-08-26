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

VARS='$OPT_DIR $MODELS_DIR $GGUF_DIR $COLIBRI_MODEL_DIR $ARCHIVE_DIR
$PORT_COLIBRI $PORT_LLAMA_SWAP $PORT_EMBED $PORT_LITELLM
$COLI_CUDA_EXPERT_GB $SOCKET1_CPUS
$COLI_MODEL_ID $COLI_VRAM_GB $COLI_KV_SLOTS $COLI_POLICY
$HF_EMBED_FILE $HF_CHAT4B_FILE $HF_CHAT8B_FILE
$CTX_CHAT4B $CTX_CHAT8B $CTX_EXTRACT $PARALLEL_EXTRACT
$LITELLM_MAX_BUDGET $LITELLM_BUDGET_DURATION $LITELLM_CLOUD_MODEL
$DOCKER_MEMORY_HIGH $DOCKER_MEMORY_MAX'

render() {  # src dst [mode]
  local tmp; tmp=$(mktemp)
  envsubst "$VARS" < "$1" > "$tmp"
  # An empty AllowedCPUs is a parsing error: drop the line.
  [[ -z "$SOCKET1_CPUS" ]] && sed -i '/^AllowedCPUs=$/d' "$tmp"
  install_file "$tmp" "$2" "${3:-0644}"
  rm -f "$tmp"
}

step "Configurations"
render "$ROOT/etc/llama-swap/config.yaml" /etc/llama-swap/config.yaml
render "$ROOT/etc/litellm/config.yaml"    /etc/litellm/config.yaml

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
# Order: embedding and llama-swap first, colibri (slow to load) next,
# LiteLLM last so its health checks find the upstreams up.
for svc in llama-embed llama-swap colibri litellm; do
  systemctl enable --now "$svc.service"
  sleep 2
  if systemctl is-active --quiet "$svc.service"; then ok "$svc active"
  else
    warn "$svc NOT active — last logs:"
    journalctl -u "$svc.service" -n 20 --no-pager | sed 's/^/     /'
  fi
done

warn "colibri loads ~10 GB of dense set: it may take a few minutes before it responds"
ok "services installed"
