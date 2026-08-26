#!/usr/bin/env bash
# Verifica end-to-end. Scrive un report in docs/REPORT-<data>.md
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"

REPORT="$ROOT/docs/REPORT-$(date +%Y%m%d-%H%M).md"
exec > >(tee "$REPORT") 2>&1
echo "# Report verifica — $(date -Is)"

step "Servizi"
for s in colibri llama-swap llama-embed litellm docker; do
  printf '     %-12s %s\n' "$s" "$(systemctl is-active "$s.service" 2>/dev/null || echo assente)"
done

step "Storage"
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS -t xfs,ext4 | sed 's/^/     /'
df -hT | grep -E 'vg0|vg1' | sed 's/^/     /'

step "GPU e memoria"
nvidia-smi --query-gpu=name,compute_cap,memory.total,memory.used --format=csv | sed 's/^/     /'
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | sed 's/^/     /'
free -h | sed 's/^/     /'

step "Endpoint"
gw="http://127.0.0.1:$PORT_LITELLM"
if curl -fsS --max-time 10 "$gw/v1/models" >/dev/null 2>&1; then
  ok "gateway risponde"
  curl -fsS "$gw/v1/models" | jq -r '.data[].id' | sed 's/^/     modello: /'
else
  warn "gateway non risponde su $gw"
fi

dim=$(curl -fsS --max-time 30 "$gw/v1/embeddings" -H 'Content-Type: application/json' \
      -d '{"model":"embed","input":"prova di embedding in italiano"}' 2>/dev/null \
      | jq -r '.data[0].embedding | length' 2>/dev/null || echo 0)
if [[ "$dim" == "1024" ]]; then ok "embedding: 1024 dimensioni"
else warn "embedding: attese 1024 dimensioni, ottenute '$dim'"; fi

if curl -fsS --max-time 60 "$gw/v1/chat/completions" -H 'Content-Type: application/json' \
   -d '{"model":"fast","messages":[{"role":"user","content":"ciao"}],"max_tokens":16}' >/dev/null 2>&1; then
  ok "chat 'fast' risponde"
else warn "chat 'fast' non risponde (il primo caricamento in VRAM puo' richiedere tempo)"; fi

step "Banda dell'LV modelli (pattern simile agli expert read: 19 MiB random)"
if command -v fio >/dev/null 2>&1; then
  fio --name=expert --filename="$MODELS_DIR/.fiotest" --size=4G \
      --rw=randread --bs=19m --iodepth=8 --numjobs=4 --direct=1 \
      --group_reporting --output-format=terse 2>/dev/null \
      | awk -F';' '{printf "     read: %.0f MB/s  iops: %s\n", $7/1024, $8}'
  rm -f "$MODELS_DIR/.fiotest"
else
  warn "fio non installato: apt install fio"
fi

step "Entrambi gli NVMe devono lavorare durante l'inferenza"
warn "esegui a mano, durante una sessione colibri: iostat -xm 2"
warn "nvme0n1 e nvme1n1 devono avere r/s simili — se lavora un solo drive, lo striping non e' attivo"

echo
ok "report salvato in $REPORT"
