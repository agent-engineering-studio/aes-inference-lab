#!/usr/bin/env bash
# sysctl, I/O scheduler, file descriptors, wait-online. Idempotent.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root

step "sysctl"
install_file "$ROOT/etc/sysctl.d/99-inference.conf" /etc/sysctl.d/99-inference.conf
sysctl --system >/dev/null && ok "sysctl applied"
for k in vm.swappiness vm.max_map_count vm.vfs_cache_pressure; do
  printf '     %s = %s\n' "$k" "$(sysctl -n $k)"
done

step "I/O scheduler"
install_file "$ROOT/etc/udev/60-ioscheduler.rules" /etc/udev/rules.d/60-ioscheduler.rules
udevadm control --reload-rules && udevadm trigger --subsystem-match=block
for d in /sys/block/nvme*/queue/scheduler /sys/block/sd*/queue/scheduler; do
  [[ -e "$d" ]] && printf '     %s: %s\n' "${d#/sys/block/}" "$(cat "$d")"
done

step "File descriptors"
install_file "$ROOT/etc/security/99-inference.conf" /etc/security/limits.d/99-inference.conf
warn "the limits apply at the next login; the services use LimitNOFILE in the units"

step "wait-online"
if systemctl is-enabled systemd-networkd-wait-online.service >/dev/null 2>&1; then
  install_file "$ROOT/etc/systemd/wait-online-any.conf" \
    /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
  systemctl daemon-reload
  ok "wait-online: proceeds as soon as one interface is online (timeout 30s)"
else
  ok "wait-online already disabled"
fi

ok "tuning done"
