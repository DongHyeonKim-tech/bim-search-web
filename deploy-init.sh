set -a
source .env.production
set +a
export BUILD_ENV=prod RUNTIME_ENV_FILE=.env.production
export HOST_PORT="$BLUE_PORT"
export IMAGE_TAG="prod-bootstrap"
docker compose --env-file .env.production -p "${IMAGE_NAME}-blue" up -d --build app
