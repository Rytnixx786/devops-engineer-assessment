#!/usr/bin/env bash
set -euo pipefail
cpu=90 mem=85 disk=80 critical=95 json=false
log=${HEALTH_LOG:-health_log.txt}
max_bytes=${HEALTH_LOG_MAX_BYTES:-1048576}
usage() {
  echo "Usage: system_health.sh [--cpu N] [--mem N] [--disk N] [--critical N] [--json] [--help]"
  echo "Warn above the per-metric percentages. Critical above the common ceiling (default 95)."
  echo "HEALTH_LOG and HEALTH_LOG_MAX_BYTES control output. Keeps one rotated backup."
}
fail() { echo "$*" >&2; exit 2; }
while (($#)); do
  case $1 in
    --help) usage; exit 0 ;;
    --json) json=true; shift ;;
    --cpu|--mem|--disk|--critical)
      [[ ${2:-} =~ ^(0|[1-9][0-9]?|100)$ ]] || fail "Expected a percentage after $1"
      case $1 in --cpu) cpu=$2;; --mem) mem=$2;; --disk) disk=$2;; --critical) critical=$2;; esac
      shift 2 ;;
    *) fail "Unknown flag $1" ;;
  esac
done
((critical >= cpu && critical >= mem && critical >= disk)) || fail "Critical must be at least each warning threshold"
[[ $max_bytes =~ ^[1-9][0-9]*$ ]] || fail "Invalid rotation size"
export LC_ALL=C
trap 'echo "Health collection failed at line $LINENO" >&2; exit 2' ERR
sample_cpu() {
  awk '/^cpu / {for(i=2;i<=9;i++) total+=$i; printf "%.0f %.0f\n",total,$5+$6; exit}' /proc/stat
}
read -r total1 idle1 <<<"$(sample_cpu)"
sleep 1
read -r total2 idle2 <<<"$(sample_cpu)"
cpu_used=$(awk -v t="$((total2-total1))" -v i="$((idle2-idle1))" 'BEGIN{if(t<=0)exit 1; printf "%.2f",100*(t-i)/t}')
mem_used=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(!t)exit 1; printf "%.2f",100*(t-a)/t}' /proc/meminfo)
read -r l1 l5 l15 _ </proc/loadavg
# df -a retains virtual mounts; a null percentage means the kernel reports no capacity.
disks=$(df -a --output=pcent,target | awk 'NR>1 {p=$1; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/,""); print p "\t" $0}' |
  jq -Rn '[inputs | capture("^(?<p>[^\\t]+)\\t(?<mount>.*)$") | {mount,used_pct:(.p|rtrimstr("%")|tonumber? // null)}]')
procs=$(ps -eo rss=,pid=,comm= --sort=-rss | awk 'NR<=5' | jq -Rn '[inputs | capture("^\\s*(?<rss>\\d+)\\s+(?<pid>\\d+)\\s+(?<name>.+)$") | {pid:(.pid|tonumber),rss_kib:(.rss|tonumber),name}]')
entry=$(jq -cn --arg time "$(date -u +%FT%TZ)" --argjson cpu "$cpu_used" --argjson mem "$mem_used" \
  --argjson disks "$disks" --argjson processes "$procs" --argjson load "[$l1,$l5,$l15]" \
  '{time:$time,cpu_pct:$cpu,memory_pct:$mem,disks:$disks,load:$load,top_processes:$processes}')
status=0
check() {
  local name=$1 val=$2 threshold=$3 severity
  severity=$(awk -v v="$val" -v w="$threshold" -v c="$critical" 'BEGIN{print (v>c ? 2 : (v>w ? 1 : 0))}')
  if ((severity)); then printf '[WARNING] %s at %s%% (severity %s)\n' "$name" "$val" "$severity" >&2; fi
  if ((severity>status)); then status=$severity; fi
}
check CPU "$cpu_used" "$cpu"
check memory "$mem_used" "$mem"
while IFS=$'\t' read -r val mount; do check "$mount" "$val" "$disk"; done < <(jq -r '.[] | select(.used_pct!=null) | [.used_pct,.mount] | @tsv' <<<"$disks")
umask 077
exec 9>"$log.lock"
flock -w 10 9
if [[ -f $log ]] && (( $(stat -c %s "$log") + ${#entry} + 1 > max_bytes )); then mv -f -- "$log" "$log.1"; fi
printf '%s\n' "$entry" >>"$log"
if $json; then printf '%s\n' "$entry"; else jq -r '"\(.time) CPU \(.cpu_pct)% memory \(.memory_pct)% load \(.load)\nDisks: \(.disks)\nTop processes: \(.top_processes)"' <<<"$entry"; fi
exit "$status"
