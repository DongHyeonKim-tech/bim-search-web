#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
# Deployment configuration always comes from .env.development.
# BUILD_ENV may be overridden at invocation time (e.g. BUILD_ENV=prod ./deploy-dev.sh).
requested_build_env="${BUILD_ENV:-}"
[[ -f .env.development ]] || { echo 'Missing .env.development' >&2; exit 1; }
set -a
source .env.development
set +a
BUILD_ENV="${requested_build_env:-${BUILD_ENV:-dev}}"
RUNTIME_ENV_FILE=".env.development"

if [[ "${BUILD_ENV}" == "prod" ]]; then
  RUNTIME_ENV_FILE=".env.production"
fi

export RUNTIME_ENV_FILE
case "$BUILD_ENV" in dev|prod|default) ;; *) echo 'BUILD_ENV must be dev/prod/default' >&2; exit 1;; esac
if [[ "$BUILD_ENV" == default ]]; then RUNTIME_ENV_FILE=.env; else RUNTIME_ENV_FILE=".env.$([[ "$BUILD_ENV" == dev ]] && echo development || echo production)"; fi
[[ -f "$RUNTIME_ENV_FILE" ]] || { echo "Missing $RUNTIME_ENV_FILE" >&2; exit 1; }
: "${IMAGE_NAME:?Set IMAGE_NAME (simple name, matching nginx site)}"
: "${APP_PORT:?Set APP_PORT}"
[[ "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || { echo 'Invalid IMAGE_NAME' >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT>=1 && APP_PORT<=65535 )) || { echo 'Invalid APP_PORT' >&2; exit 1; }
export BUILD_ENV IMAGE_NAME RUNTIME_ENV_FILE HOST_PORT="$APP_PORT"
export IMAGE_TAG="${IMAGE_TAG:-${BUILD_ENV}-$(date +%Y%m%d%H%M%S)}"
project="${IMAGE_NAME}-dev"
command -v docker >/dev/null
# Compose env_file loads application runtime values; it does not select the build environment.
docker compose --env-file .env.development -p "$project" build app
docker compose --env-file .env.development -p "$project" up -d --no-build --force-recreate app
cid=$(docker compose --env-file .env.development -p "$project" ps -q app)
for _ in $(seq 1 30); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
  [[ "$status" == healthy ]] && { echo "DEV deployed: $project $IMAGE_TAG port $APP_PORT"; exit 0; }
  [[ "$status" == unhealthy ]] && break
  sleep 2
done
echo 'DEV health check failed (downtime possible)' >&2
exit 1
