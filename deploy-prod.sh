
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Blue/Green Docker Compose Deployment
#
# Run as: deploy user
# Nginx switch: root-owned switch-nginx-target via sudo
#
# Required .env.production:
#   IMAGE_NAME
#   BLUE_PORT
#   GREEN_PORT
#
# Required /etc/nginx/deploy-targets.conf:
#   PROJECT NGINX_CONF MARKER BLUE_PORT GREEN_PORT
# ============================================================

cd "$(dirname "$(realpath "$0")")"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ------------------------------------------------------------
# 1. Load production environment
# ------------------------------------------------------------

[[ -f .env.production ]] ||
  die "Missing .env.production"

set -a
source .env.production
set +a

: "${IMAGE_NAME:?Set IMAGE_NAME}"
: "${BLUE_PORT:?Set BLUE_PORT}"
: "${GREEN_PORT:?Set GREEN_PORT}"

[[ "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
  die "Invalid IMAGE_NAME"

for port in "$BLUE_PORT" "$GREEN_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] ||
    die "Invalid port: $port"

  (( 10#$port <= 65535 )) ||
    die "Port out of range: $port"
done

[[ "$BLUE_PORT" != "$GREEN_PORT" ]] ||
  die "BLUE_PORT and GREEN_PORT must differ"

[[ "${BUILD_ENV:-prod}" == "prod" ]] ||
  die "Production requires BUILD_ENV=prod"

BUILD_ENV=prod
RUNTIME_ENV_FILE=.env.production

export BUILD_ENV IMAGE_NAME RUNTIME_ENV_FILE

# ------------------------------------------------------------
# 2. Check required commands and permissions
# ------------------------------------------------------------

for cmd in docker python3 flock curl sudo; do
  command -v "$cmd" >/dev/null ||
    die "Missing command: $cmd"
done

docker info >/dev/null 2>&1 ||
  die "Docker daemon is unavailable or permission denied"

switch_script="/usr/local/sbin/switch-nginx-target"
allowlist="/etc/nginx/deploy-targets.conf"

[[ -x "$switch_script" ]] ||
  die "Missing Nginx switch script: $switch_script"

[[ -r "$allowlist" ]] ||
  die "Cannot read Nginx deployment allowlist"

# Check sudo permission without executing the switch.
sudo -n -l "$switch_script" >/dev/null ||
  die "deploy user cannot run Nginx switch via passwordless sudo"

# ------------------------------------------------------------
# 3. Acquire project deployment lock
# ------------------------------------------------------------

lock_dir="${HOME}/.local/state/deploy-locks"

mkdir -p "$lock_dir"
chmod 700 "$lock_dir"

exec 9>"${lock_dir}/${IMAGE_NAME}.lock"

flock -n 9 ||
  die "Deployment already running: $IMAGE_NAME"

# ------------------------------------------------------------
# 4. Resolve project Nginx configuration
# ------------------------------------------------------------

found=false
nginx_conf=""
deploy_marker=""
allowed_blue=""
allowed_green=""

while read -r name conf marker blue green extra; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue

  if [[ "$name" == "$IMAGE_NAME" ]]; then
    [[ "$found" == false ]] ||
      die "Duplicate project in allowlist"

    [[ -z "${extra:-}" ]] ||
      die "Invalid allowlist entry"

    found=true
    nginx_conf="$conf"
    deploy_marker="$marker"
    allowed_blue="$blue"
    allowed_green="$green"
  fi
done < "$allowlist"

[[ "$found" == true ]] ||
  die "Project not registered in Nginx allowlist: $IMAGE_NAME"

[[ "$nginx_conf" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] ||
  die "Invalid Nginx conf name"

[[ "$deploy_marker" =~ ^DEPLOY_[A-Z0-9_]+$ ]] ||
  die "Invalid deployment marker"

[[ "$BLUE_PORT" == "$allowed_blue" &&
   "$GREEN_PORT" == "$allowed_green" ]] ||
  die "Port configuration differs from Nginx allowlist"

site="/etc/nginx/sites-available/${nginx_conf}"

[[ -r "$site" ]] ||
  die "Cannot read Nginx site: $site"

# ------------------------------------------------------------
# 5. Detect current active Blue/Green slot
# ------------------------------------------------------------

current=$(python3 - "$site" "$deploy_marker" <<'PYCODE'
import re
import sys

path, marker = sys.argv[1:]

pattern = (
    r'^\s*server\s+127\.0\.0\.1:'
    r'(\d+);[ \t]*#[ \t]*'
    + re.escape(marker)
    + r'[ \t]*$'
)

with open(path, encoding="utf-8") as f:
    content = f.read()

matches = re.findall(pattern, content, re.MULTILINE)

if len(matches) != 1:
    sys.exit(
        f"Expected exactly one {marker}, "
        f"found {len(matches)}"
    )

print(matches[0])
PYCODE
)

if [[ "$current" == "$BLUE_PORT" ]]; then
  old="blue"
  target="green"
  target_port="$GREEN_PORT"

elif [[ "$current" == "$GREEN_PORT" ]]; then
  old="green"
  target="blue"
  target_port="$BLUE_PORT"

else
  die "Unexpected active Nginx port: $current"
fi

old_project="${IMAGE_NAME}-${old}"
new_project="${IMAGE_NAME}-${target}"

echo "========================================"
echo "Project     : $IMAGE_NAME"
echo "Nginx conf  : $nginx_conf"
echo "Marker      : $deploy_marker"
echo "Active      : $old_project ($current)"
echo "Target      : $new_project ($target_port)"
echo "========================================"

# ------------------------------------------------------------
# 6. Verify active container
# ------------------------------------------------------------

active_id=$(
  docker compose \
    --env-file .env.production \
    -p "$old_project" \
    ps -q app 2>/dev/null || true
)

[[ -n "$active_id" ]] ||
  die "Active container not found: $old_project"

[[ "$(docker inspect -f '{{.State.Running}}' "$active_id")" == "true" ]] ||
  die "Active container is not running: $old_project"

# ------------------------------------------------------------
# 7. Build and start inactive slot
# ------------------------------------------------------------

export HOST_PORT="$target_port"
export IMAGE_TAG="${IMAGE_TAG:-prod-$(date +%Y%m%d%H%M%S)}"

echo "Building $new_project..."

docker compose \
  --env-file .env.production \
  -p "$new_project" \
  build app

echo "Starting $new_project..."

docker compose \
  --env-file .env.production \
  -p "$new_project" \
  up -d --no-build --force-recreate app

# ------------------------------------------------------------
# 8. Wait for application readiness
# ------------------------------------------------------------

ready=false

for _ in $(seq 1 30); do
  if curl \
    --fail \
    --silent \
    --max-time 5 \
    "http://127.0.0.1:${target_port}/" \
    >/dev/null; then

    ready=true
    break
  fi

  sleep 2
done

[[ "$ready" == true ]] ||
  die "New container is not ready; existing traffic unchanged"

# ------------------------------------------------------------
# 9. Switch Nginx to new slot
# ------------------------------------------------------------

echo "Switching Nginx to $target_port..."

sudo -n "$switch_script" \
  "$IMAGE_NAME" \
  "$current" \
  "$target_port"

# ------------------------------------------------------------
# 10. Post-switch health check
# ------------------------------------------------------------

if ! curl \
  --fail \
  --silent \
  --max-time 5 \
  "http://127.0.0.1:${target_port}/" \
  >/dev/null; then

  echo "Post-switch health check failed" >&2
  echo "Rolling back Nginx to $current..." >&2

  sudo -n "$switch_script" \
    "$IMAGE_NAME" \
    "$target_port" \
    "$current" || {
      echo "CRITICAL: Nginx rollback failed" >&2
      exit 1
    }

  die "Deployment rolled back"
fi

echo "Nginx switched successfully"

# ------------------------------------------------------------
# 11. Drain and stop previous slot
# ------------------------------------------------------------

drain_seconds="${DRAIN_SECONDS:-30}"

[[ "$drain_seconds" =~ ^[0-9]+$ ]] ||
  die "Invalid DRAIN_SECONDS"

echo "Draining previous slot for ${drain_seconds}s..."

sleep "$drain_seconds"

echo "Stopping $old_project..."

docker compose \
  --env-file .env.production \
  -p "$old_project" \
  stop -t 60 app

# ------------------------------------------------------------
# 12. Deployment completed
# ------------------------------------------------------------

echo "========================================"
echo "PROD deployment completed"
echo "Project : $IMAGE_NAME"
echo "Image   : $IMAGE_TAG"
echo "Active  : $target"
echo "Port    : $target_port"
echo "========================================"
