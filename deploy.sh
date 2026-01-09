#!/bin/bash

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# ----------------------------
# AutoDeploy config (.autodeploy.ini)
# ----------------------------
AUTODEPLOY_COMPOSE_FILE=""
AUTODEPLOY_COPY_LIST=()
AUTODEPLOY_RENDER_LIST=()

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # ltrim
  s="${s%"${s##*[![:space:]]}"}"   # rtrim
  echo "$s"
}

read_autodeploy_ini() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0

  log "⚙️ Loading AutoDeploy config: $cfg"
  local section=""

  while IFS= read -r raw || [ -n "$raw" ]; do
    # remove comments ; or #
    local line="${raw%%#*}"
    line="${line%%;*}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    case "$section" in
      settings)
        if [[ "$line" == compose_file=* ]]; then
          AUTODEPLOY_COMPOSE_FILE="${line#compose_file=}"
          AUTODEPLOY_COMPOSE_FILE="$(trim "$AUTODEPLOY_COMPOSE_FILE")"
        fi
        ;;
      copy)
        AUTODEPLOY_COPY_LIST+=("$line")
        ;;
      render)
        AUTODEPLOY_RENDER_LIST+=("$line")
        ;;
      *)
        # ignore unknown sections
        ;;
    esac
  done < "$cfg"
}

copy_extra_paths() {
  local src_root="$1"
  local dst_root="$2"

  [ "${#AUTODEPLOY_COPY_LIST[@]}" -eq 0 ] && return 0
  log "📦 Copying extra paths (from [copy]) to base dir..."

  for rel in "${AUTODEPLOY_COPY_LIST[@]}"; do
    local src="$src_root/$rel"
    local dst="$dst_root/$rel"

    if [ -e "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      # cp -a preserva estrutura/perms
      cp -a "$src" "$dst" 2>/dev/null || cp -a "$src" "$(dirname "$dst")/"
      log "✅ Copied: $rel"
    else
      log "⚠️ Not found to copy: $rel"
    fi
  done
}

render_files_list() {
  local base_dir="$1"
  [ "${#AUTODEPLOY_RENDER_LIST[@]}" -eq 0 ] && return 0

  log "🧩 Rendering placeholders in files from [render]..."

  for rel in "${AUTODEPLOY_RENDER_LIST[@]}"; do
    local f="$base_dir/$rel"
    if [ ! -f "$f" ]; then
      log "⚠️ Render target not found (skipping): $rel"
      continue
    fi

    if ! grep -Iq . "$f"; then
      log "⚠️ Non-text file (skipping): $rel"
      continue
    fi

    # Replace ${VAR} only if VAR exists in ENV; else keep ${VAR}
    perl -i -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$f"
    log "✅ Rendered: $rel"
  done
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
            -d "{\"event_type\": \"deploy_finished\", \"client_payload\": {\"status\": \"$status\", \"message\": \"$message\", \"service\": \"$SERVICE\",  \"run_id\": \"$GITHUB_RUN_ID\"}}"
    fi
}

# Define variables
SERVICE=$1
GIT_USER=${2:-thiagosol}
BRANCH="main"
BASE_DIR="/opt/auto-deploy/$SERVICE"    
TEMP_DIR="$BASE_DIR/temp"
GIT_REPO="git@github.com:$GIT_USER/$SERVICE.git"

shift 2

# Export all passed variables (so GH_TOKEN is available)
for VAR in "$@"; do
    if [[ "$VAR" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
        export "$VAR"
    else
        log "⚠️ Skipping invalid variable: $VAR"
    fi
done

if [ -d "$TEMP_DIR" ]; then
  sudo chown -R "$(whoami)":"$(whoami)" "$TEMP_DIR"
  rm -rf "$TEMP_DIR"
fi

mkdir -p "$TEMP_DIR"

cd "$TEMP_DIR" || { log "ERROR: Failed to access temp directory"; notify_github "failure" "Failed to access temp directory"; exit 1; }

log "📥 Cloning repository $GIT_REPO (branch: $BRANCH)..."
export GIT_SSH_COMMAND="ssh -i /opt/auto-deploy/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git clone --depth=1 --branch "$BRANCH" "$GIT_REPO" . || { log "ERROR: Git clone failed"; notify_github "failure" "Git clone failed"; exit 1; }

read_autodeploy_ini "$TEMP_DIR/.autodeploy.ini"

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
    DOCKER_BUILD_CMD="docker build --memory=6g --rm --force-rm -t $SERVICE"

    for VAR in "$@"; do
        DOCKER_BUILD_CMD+=" --build-arg $VAR"
    done

    DOCKER_BUILD_CMD+=" $TEMP_DIR"

    eval "$DOCKER_BUILD_CMD" || { log "ERROR: Docker build failed"; notify_github "failure" "Docker build failed"; exit 1; }
else
    log "⚠️ No Dockerfile found. Skipping build step."
fi


# Choose compose file
if [ -n "$AUTODEPLOY_COMPOSE_FILE" ]; then
  COMPOSE_SRC="$TEMP_DIR/$AUTODEPLOY_COMPOSE_FILE"
else
  COMPOSE_SRC="$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'docker-compose*.yml' | head -n 1)"
fi

if [ -z "$COMPOSE_SRC" ] || [ ! -f "$COMPOSE_SRC" ]; then
  log "ERROR: No docker-compose file found"
  notify_github "failure" "No docker-compose file found"
  exit 1
fi

COMPOSE_BASENAME="$(basename "$COMPOSE_SRC")"
log "📂 Moving $COMPOSE_BASENAME to $BASE_DIR..."
mv "$COMPOSE_SRC" "$BASE_DIR/$COMPOSE_BASENAME" || { log "ERROR: Failed to move compose"; notify_github "failure" "Failed to move compose"; exit 1; }

log "🛠️ Checking volumes..."
VOLUMES=$(grep -oP '(?<=- \./)[^:]+' "$BASE_DIR/docker-compose.yml")

for VOL in $VOLUMES; do
    SRC="$TEMP_DIR/$VOL"
    DEST="$BASE_DIR/$VOL"

    if [ -e "$SRC" ]; then
        if [ -e "$DEST" ]; then
            log "📁 Volume $DEST already exists, copying contents..."
            cp -r "$SRC"/* "$DEST/" || log "⚠️ Error copying contents of $SRC, skipping..."
        else
            log "📁 Moving volume $SRC to $DEST..."
            mv "$SRC" "$DEST" || log "⚠️ Error moving $SRC, skipping..."
        fi
    else
        log "❌ Volume $SRC not found, skipping..."
    fi

    if [ ! -e "$DEST" ]; then
        log "📁 Creating empty volume at $DEST..."
        mkdir -p "$DEST"
        chmod 777 -R "$DEST"
    fi
done

# Copy extra configured paths (not bound to compose volumes)
copy_extra_paths "$TEMP_DIR" "$BASE_DIR"

# Now render only the configured files in base dir
render_files_list "$BASE_DIR"

log "🛠️ Cleaning temporary directories and unused images..."
rm -rf "$TEMP_DIR"
docker images -f "dangling=true" -q | xargs -r docker rmi -f

cd "$BASE_DIR" || { log "ERROR: Failed to access base directory"; notify_github "failure" "Failed to access base directory"; exit 1; }

log "🔄 Restarting containers with Docker Compose..."
docker-compose -f "$COMPOSE_BASENAME" down && docker-compose -f "$COMPOSE_BASENAME" up -d \
  || { log "ERROR: Docker Compose failed"; notify_github "failure" "Docker Compose failed"; exit 1; }

log "✅ Deployment completed successfully!"
notify_github "success" "Deployment completed successfully"
exit 0
