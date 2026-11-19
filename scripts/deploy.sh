#!/usr/bin/env bash
# Installed by EC2 bootstrap. Invoked as root by a restricted SSM document.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/assessment-release.env
tag=${1:?image tag required}
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || exit 2
exec 9>/run/assessment-deploy.lock
flock -w 120 9
registry=${REPOSITORY%%/*}
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
trap 'rm -f -- "$DOCKER_CONFIG/config.json"; rmdir -- "$DOCKER_CONFIG"' EXIT
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry"
candidate="$REPOSITORY:$tag"
docker pull "$candidate"
previous=$(docker inspect --format '{{.Config.Image}}' assessment-app 2>/dev/null || true)
start_app() {
  docker run -d --name assessment-app --restart unless-stopped --read-only --cap-drop ALL \
    --security-opt no-new-privileges --memory 96m --cpus 0.5 -p 8080:8080 \
    -e APP_ENV="$APP_ENV" --log-driver awslogs --log-opt awslogs-region="$REGION" \
    --log-opt awslogs-group="$LOG_GROUP" --log-opt awslogs-stream="$APP_ENV" "$1"
}
healthy() {
  local expected actual _
  expected=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1") || return 1
  [[ -n $expected ]] || return 1
  for _ in {1..20}; do
    if curl -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null &&
      actual=$(curl -fsS --max-time 2 http://127.0.0.1:8080/ | jq -er .version) &&
      [[ $actual == "$expected" ]]; then return 0; fi
    sleep 1
  done
  return 1
}
if [[ -n $previous ]]; then
  docker stop --time 15 assessment-app >/dev/null
  docker rm assessment-app >/dev/null
fi
if start_app "$candidate" && healthy "$candidate"; then
  echo "Healthy release $candidate"; exit 0
fi
docker rm -f assessment-app >/dev/null 2>&1 || true
if [[ -n $previous ]]; then
  if ! start_app "$previous" || ! healthy "$previous"; then echo "Rollback failed" >&2; exit 2; fi
  echo "Restored $previous" >&2
fi
exit 1
