#!/bin/bash

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to send webhook to GitHub Actions (only if GH_TOKEN is available)
notify_github() {
    if [ -n "$GH_TOKEN" ]; then
        local status="$1"
        local message="$2"
        
        log "🔔 Notifying GitHub Actions: $status"

        curl -X POST "https://api.github.com/repos/thiagosol/$SERVICE/dispatches" \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: token $GH_TOKEN" \
            -d "{\"event_type\": \"deploy_finished\", \"client_payload\": {\"status\": \"$status\", \"message\": \"$message\"}}"
    fi
}

# Define variables
SERVICE=$1
GIT_USER=${2:-thiagosol}
BRANCH="main"
BASE_DIR="/opt/auto-deploy/$SERVICE"
TEMP_DIR="$BASE_DIR/temp"
GIT_REPO="https://github.com/$GIT_USER/$SERVICE.git"

shift 2

# Export all passed variables (so GH_TOKEN is available)
for VAR in "$@"; do
    log "AAAA VAR: $VAR"
    if [[ "$VAR" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
        export "$VAR"
    else
        log "⚠️ Skipping invalid variable: $VAR"
    fi
done

mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || { log "ERROR: Failed to access temp directory"; notify_github "failure" "Failed to access temp directory"; exit 1; }

log "📥 Cloning repository $GIT_REPO (branch: $BRANCH)..."
git clone --depth=1 --branch "$BRANCH" "$GIT_REPO" . || { log "ERROR: Git clone failed"; notify_github "failure" "Git clone failed"; exit 1; }

# Check if Dockerfile or docker-compose.yml exists
if [ ! -f "$TEMP_DIR/Dockerfile" ] && [ -z "$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'docker-compose*.yml' -print -quit)" ]; then
    log "⚠️ No Dockerfile or docker-compose.yml found. Copying files and finishing deployment."
    cp -r "$TEMP_DIR/"* "$BASE_DIR/"
    find "$BASE_DIR" -type f -name "*.sh" -exec chmod +x {} \;
    rm -rf "$TEMP_DIR"
    log "✅ Deployment completed without Docker!"
    notify_github "success" "Deployment completed without Docker"
    exit 0
fi

log "🔥 Removing old images..."
EXISTING_IMAGE=$(docker images -q "$SERVICE")
if [ -n "$EXISTING_IMAGE" ]; then
    log "📌 Found existing image. Stopping and removing..."
    docker ps -q --filter "ancestor=$SERVICE" | xargs -r docker stop
    docker ps -aq --filter "ancestor=$SERVICE" | xargs -r docker rm
    docker rmi -f "$SERVICE"
fi

if [ -f "$TEMP_DIR/Dockerfile" ]; then
    log "🔨 Building new Docker image..."
    DOCKER_BUILD_CMD="docker build --memory=4g --rm --force-rm -t $SERVICE $TEMP_DIR"

    for VAR in "$@"; do
        DOCKER_BUILD_CMD+=" --build-arg $VAR"
    done

    eval "$DOCKER_BUILD_CMD" || { log "ERROR: Docker build failed"; notify_github "failure" "Docker build failed"; exit 1; }
else
    log "⚠️ No Dockerfile found. Skipping build step."
fi

log "📂 Moving docker-compose.yml to $BASE_DIR..."
mv "$TEMP_DIR/docker-compose.yml" "$BASE_DIR/" || { log "ERROR: Failed to move docker-compose.yml"; notify_github "failure" "Failed to move docker-compose.yml"; exit 1; }

log "🛠️ Checking volumes..."
VOLUMES=$(grep -oP '(?<=- \./)[^:]+' "$BASE_DIR/docker-compose.yml")

for VOL in $VOLUMES; do
    SRC="$TEMP_DIR/$VOL"
    DEST="$BASE_DIR/$VOL"

    if [ -e "$SRC" ]; then
        log "📁 Moving volume $SRC to $DEST..."
        mv "$SRC" "$DEST" || log "ERROR: Failed to move $SRC, skipping..."
    else
        log "❌ Volume $SRC not found, skipping..."
    fi

    if [ ! -e "$DEST" ]; then
        log "📁 Creating empty volume at $DEST..."
        mkdir -p "$DEST"
        chmod 777 -R "$DEST"
    fi
done

log "🛠️ Cleaning temporary directories and unused images..."
rm -rf "$TEMP_DIR"
docker images -f "dangling=true" -q | xargs -r docker rmi -f

cd "$BASE_DIR" || { log "ERROR: Failed to access base directory"; notify_github "failure" "Failed to access base directory"; exit 1; }

log "🔄 Restarting containers with Docker Compose..."
docker-compose down && docker-compose up -d || { log "ERROR: Docker Compose failed"; notify_github "failure" "Docker Compose failed"; exit 1; }

log "✅ Deployment completed successfully!"
notify_github "success" "Deployment completed successfully"
exit 0
