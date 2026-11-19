#!/usr/bin/env bash
# Exercise the public CLI on a Linux host. Temporary logs are isolated per run.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -f -- "$temp"/health* "$temp"/output "$temp"/warnings; rmdir -- "$temp"' EXIT
export HEALTH_LOG="$temp/health" HEALTH_LOG_MAX_BYTES=1
exercise() {
  local expected=$1 actual=0
  shift
  bash "$root/system_health.sh" --json "$@" >"$temp/output" 2>"$temp/warnings" || actual=$?
  [[ $actual == "$expected" ]] || { cat "$temp/warnings" >&2; return 1; }
  jq -e '(.cpu_pct|type=="number") and (.load|length==3) and (.disks|length>0) and (.top_processes|length>0 and length<=5)' "$temp/output" >/dev/null
  if ((expected)); then grep -F '[WARNING]' "$temp/warnings" >/dev/null; fi
}
bash "$root/system_health.sh" --help >/dev/null
exercise 0 --cpu 100 --mem 100 --disk 100 --critical 100
exercise 1 --mem 0 --critical 100
exercise 2 --cpu 0 --mem 0 --disk 0 --critical 0
test -s "$HEALTH_LOG.1"
bad=0
bash "$root/system_health.sh" --disk invalid 2>/dev/null || bad=$?
test "$bad" = 2
echo 'Passed health JSON, healthy/warning/critical exits, rotation, help and invalid-input checks.'
