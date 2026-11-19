#!/usr/bin/env bash
# Run inside a disposable Linux container. The stubs model ECR/Docker/HTTP locally.
set -euo pipefail
[[ -f /.dockerenv && ! -e /etc/assessment-release.env ]] || { echo "Use a fresh test container" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
export TEST_DIR
TEST_DIR=$(mktemp -d)
export PATH="$TEST_DIR:$PATH"
printf 'REGION=local\nREPOSITORY=local/app\nAPP_ENV=staging\nLOG_GROUP=local\n' >/etc/assessment-release.env
cat >"$TEST_DIR/aws" <<'STUB'
#!/bin/sh
echo offline-test
STUB
cat >"$TEST_DIR/docker" <<'STUB'
#!/usr/bin/env bash
set -eu
case $1 in
  login) cat >/dev/null ;;
  pull) [[ ${2##*:} != unavailable ]] ;;
  inspect) cat "$TEST_DIR/current" ;;
  stop) test -s "$TEST_DIR/current" ;;
  rm) rm -f "$TEST_DIR/current" ;;
  run) echo "${!#}" >"$TEST_DIR/current" ;;
  image) tag=${!#}; echo "${tag##*:}" ;;
  *) exit 2 ;;
esac
STUB
cat >"$TEST_DIR/curl" <<'STUB'
#!/usr/bin/env bash
set -eu
current=$(cat "$TEST_DIR/current")
case "${!#}" in
  */health) [[ ${current##*:} != unhealthy ]] ;;
  *) printf '{"version":"%s"}\n' "${current##*:}" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/sleep"
chmod +x "$TEST_DIR/"{docker,aws,curl,sleep}
bash "$root/scripts/deploy.sh" one
bash "$root/scripts/deploy.sh" two
for tag in unhealthy unavailable; do
  result=0
  bash "$root/scripts/deploy.sh" "$tag" || result=$?
  test "$result" = 1
  test "$(cat "$TEST_DIR/current")" = local/app:two
done
echo "Passed initial deploy, upgrade, failed health rollback and failed pull preservation (stubbed host)."
