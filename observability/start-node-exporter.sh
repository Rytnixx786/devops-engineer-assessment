#!/bin/sh
set -eu
# /proc/net resolves through "self" and would count the exporter's bridge traffic.
# Point net at host PID 1's network namespace while keeping the listener private.
view=$(mktemp -d)
for entry in stat cpuinfo meminfo 1 self; do
  ln -s "/host/proc/$entry" "$view/$entry"
done
ln -s /host/proc/1/net "$view/net"
exec /bin/node_exporter --path.rootfs=/host --path.procfs="$view" --path.sysfs=/host/sys \
  --collector.disable-defaults --collector.cpu --collector.meminfo --collector.filesystem --collector.netdev --no-collector.netdev.netlink
