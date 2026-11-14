#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(realpath "$0")")"
[[ -f .env.production ]] || { echo 'Missing .env.production' >&2; exit 1; }
set -a
source .env.production
set +a
: "${IMAGE_NAME:?Set IMAGE_NAME}"
: "${NGINX_SITE:?Set NGINX_SITE}"
: "${BLUE_PORT:?Set BLUE_PORT}"
: "${GREEN_PORT:?Set GREEN_PORT}"
[[ "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || { echo 'Invalid IMAGE_NAME' >&2; exit 1; }
[[ "$NGINX_SITE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid NGINX_SITE' >&2; exit 1; }
for port in "$BLUE_PORT" "$GREEN_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) || { echo 'Invalid port' >&2; exit 1; }
done
[[ "$BLUE_PORT" != "$GREEN_PORT" ]] || { echo 'Ports must differ' >&2; exit 1; }
[[ "${BUILD_ENV:-prod}" == prod ]] || { echo 'Production requires BUILD_ENV=prod' >&2; exit 1; }
# next.config.ts basePath. `/` returns 404, so readiness must hit this path.
APP_PATH=/search
BUILD_ENV=prod
RUNTIME_ENV_FILE=.env.production
[[ -f "$RUNTIME_ENV_FILE" ]] || { echo 'Missing .env.production' >&2; exit 1; }
site="/etc/nginx/sites-available/$NGINX_SITE"
[[ -f "$site" ]] || { echo "Missing Nginx site: $site" >&2; exit 1; }
command -v nginx >/dev/null
command -v flock >/dev/null
command -v python3 >/dev/null
exec 9>"/tmp/deploy-${IMAGE_NAME}.lock"
flock -n 9 || { echo 'Deployment already running' >&2; exit 1; }
# Requires exactly one line: server 127.0.0.1:PORT; # DEPLOY_SEARCH_TARGET
current=$(python3 - "$site" <<'PYCODE'
import re,sys
s=open(sys.argv[1]).read()
m=re.findall(r'^\s*server\s+127\.0\.0\.1:(\d+);\s*#\s*DEPLOY_SEARCH_TARGET\s*$',s,re.M)
if len(m)!=1: sys.exit('Expected exactly one marked upstream server line')
print(m[0])
PYCODE
)
if [[ "$current" == "$BLUE_PORT" ]]; then
  target=green; target_port="$GREEN_PORT"; old=blue
elif [[ "$current" == "$GREEN_PORT" ]]; then
  target=blue; target_port="$BLUE_PORT"; old=green
else
  echo "Nginx points to unexpected port $current. Initialize site with BLUE_PORT or GREEN_PORT." >&2; exit 1
fi
# Guard against silently bootstrapping with a missing active container.
active_id=$(docker compose --env-file .env.production -p "${IMAGE_NAME}-${old}" ps -q app 2>/dev/null || true)
[[ -n "$active_id" && "$(docker inspect -f '{{.State.Running}}' "$active_id")" == true ]] || {
  echo "Active ${old} container not running. Bootstrap first; refusing traffic switch." >&2; exit 1;
}
export BUILD_ENV IMAGE_NAME RUNTIME_ENV_FILE HOST_PORT="$target_port"
export IMAGE_TAG="${IMAGE_TAG:-prod-$(date +%Y%m%d%H%M%S)}"
new_project="${IMAGE_NAME}-${target}"
old_project="${IMAGE_NAME}-${old}"
echo "Deploying $new_project on $target_port (active: $old_project on $current)"
docker compose --env-file .env.production -p "$new_project" build app
docker compose --env-file .env.production -p "$new_project" up -d --no-build --force-recreate app
# Node is not listening at container start. Wait until the app responds.
# Accept 200 and redirects. curl --fail treats the basePath 404 on `/` as down.
health_url="http://127.0.0.1:${target_port}${APP_PATH}"
ready=false
last_status=""
for _ in $(seq 1 30); do
  last_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$health_url" || true)
  case "$last_status" in
    200|301|302|307|308) ready=true; break ;;
  esac
  sleep 2
done
if [[ "$ready" != true ]]; then
  echo "New slot is not accepting requests at ${health_url} (last HTTP status: ${last_status:-none}); existing traffic unchanged" >&2
  exit 1
fi
backup=$(mktemp "/tmp/nginx-${IMAGE_NAME}.XXXXXX")
cp -p "$site" "$backup"
restore() {
  cp -p "$backup" "$site"
  nginx -t && nginx -s reload || echo 'WARNING: Nginx restoration/reload failed; manual action required' >&2
}
# Replace only the marked line, preserve everything else.
python3 - "$site" "$target_port" <<'PYCODE'
import re,sys
path,port=sys.argv[1:]
s=open(path).read()
pat=r'^(\s*server\s+127\.0\.0\.1:)\d+(;\s*#\s*DEPLOY_SEARCH_TARGET\s*)$'
out,n=re.subn(pat,lambda m:m.group(1)+port+m.group(2),s,flags=re.M)
if n!=1: sys.exit('Marker replacement failed')
open(path,'w').write(out)
PYCODE
if ! nginx -t || ! nginx -s reload; then
  echo 'Nginx switch failed, restoring previous config' >&2
  restore
  exit 1
fi
# Roll back routing if immediate post-switch probe fails.
post_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$health_url" || true)
case "$post_status" in
  200|301|302|307|308) ;;
  *)
    echo "Post-switch probe failed at ${health_url} (HTTP ${post_status:-none}); restoring previous config" >&2
    restore
    exit 1
    ;;
esac
rm -f "$backup"
echo "Switched Nginx to ${target} (${target_port})"
# Allow in-flight requests to drain before stopping the old slot.
sleep "${DRAIN_SECONDS:-30}"
# If old slot shutdown fails, keep new traffic active; report error.
docker compose --env-file .env.production -p "$old_project" stop -t 60 app
echo "PROD deployed: ${IMAGE_NAME} ${IMAGE_TAG}; active=${target}"
