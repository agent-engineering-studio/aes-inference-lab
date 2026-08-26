#!/usr/bin/env bash
# daemon.json, docker.slice, timer di prune.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_cmd docker
need_cmd jq

step "Verifica che /var/lib/docker sia sui meccanici"
src=$(findmnt -no SOURCE /var/lib/docker 2>/dev/null || true)
[[ -n "$src" ]] || die "/var/lib/docker non e' un mount separato: i layer stanno su lv_root"
ok "$src"

step "daemon.json"
DESIRED=$(jq -n --arg mh "$DOCKER_MEMORY_HIGH" '{
  "storage-driver": "overlay2",
  "cgroup-parent": "docker.slice",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 } }
}')
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  MERGED=$(jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DESIRED"))
else
  MERGED="$DESIRED"
fi
tmp=$(mktemp); echo "$MERGED" | jq . > "$tmp"
install_file "$tmp" /etc/docker/daemon.json; rm -f "$tmp"

step "docker.slice"
tmp=$(mktemp)
envsubst '$DOCKER_MEMORY_HIGH $DOCKER_MEMORY_MAX' < "$ROOT/etc/systemd/docker.slice" > "$tmp"
install_file "$tmp" /etc/systemd/system/docker.slice; rm -f "$tmp"

step "Timer di pulizia"
install_file "$ROOT/etc/systemd/stack-prune.service" /etc/systemd/system/stack-prune.service
install_file "$ROOT/etc/systemd/stack-prune.timer"   /etc/systemd/system/stack-prune.timer

systemctl daemon-reload
systemctl enable --now stack-prune.timer
systemctl restart docker
sleep 3
docker info --format '     Root Dir: {{.DockerRootDir}}\n     Driver:   {{.Driver}}\n     Cgroup:   {{.CgroupDriver}}'
ok "Docker configurato"
warn "il conflitto vero non e' il disco: e' la page cache, che fa da cache esperti a colibri"
