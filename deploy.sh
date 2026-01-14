#!/bin/bash

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to clean up lock file on exit
cleanup_lock() {
    if [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
        log "🔓 Removing deployment lock..."
        rm -f "$LOCK_FILE"
    fi
}

# Set trap to always clean up lock on exit (success, error, or interrupt)
trap cleanup_lock EXIT INT TERM

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

# Function to load secrets from GitHub repository
load_secrets() {
    local secrets_dir="/tmp/deploy-secrets-$$"
    local secrets_repo="git@github.com:thiagosol/secrets.git"
    local environment="prod"  # Always prod for legacy deploy.sh
    
    log "🔐 Loading secrets from GitHub repository..."
    
    # Clone secrets repository
    export GIT_SSH_COMMAND="ssh -i /opt/auto-deploy/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    
    if ! git clone --depth=1 "$secrets_repo" "$secrets_dir" 2>/dev/null; then
        log "❌ ERROR: Failed to clone secrets repository"
        rm -rf "$secrets_dir"
        return 1
    fi
    
    # Check if secrets.json exists
    if [ ! -f "$secrets_dir/secrets.json" ]; then
        log "❌ ERROR: secrets.json not found in repository"
        rm -rf "$secrets_dir"
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log "❌ ERROR: jq is not installed. Please install jq to parse JSON."
        rm -rf "$secrets_dir"
        return 1
    fi
    
    # Read and export all secrets from JSON
    log "📦 Exporting secrets as environment variables..."
    while IFS="=" read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            export "$key=$value"
            log "✅ Exported: $key"
        fi
    done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$secrets_dir/secrets.json")
    
    log "✅ Secrets loaded successfully!"
    
    # Copy service-specific secrets if they exist (always using prod environment)
    local service_secrets_path="$secrets_dir/$SERVICE/$environment"
    if [ -d "$service_secrets_path" ]; then
        log "📂 Found service-specific secrets for $SERVICE/$environment"
        
        # Create secrets directory in temp
        local dest_secrets_dir="$TEMP_DIR/secrets"
        mkdir -p "$dest_secrets_dir"
        
        # Copy all contents from service/environment to temp/secrets
        if cp -r "$service_secrets_path/"* "$dest_secrets_dir/" 2>/dev/null; then
            log "✅ Copied service-specific secrets to $dest_secrets_dir"
        else
            log "⚠️ Service secrets directory exists but is empty"
        fi
    else
        log "ℹ️ No service-specific secrets found at $SERVICE/$environment (optional, skipping)"
    fi
    
    # Clean up secrets repository clone
    rm -rf "$secrets_dir"
    
    return 0
}

# Function to copy secrets directory from temp to base
copy_secrets_directory() {
    local temp_secrets="$TEMP_DIR/secrets"
    local base_secrets="$BASE_DIR/secrets"
    
    if [ -d "$temp_secrets" ]; then
        log "🔐 Processing secrets directory..."
        
        # Create base secrets directory if it doesn't exist
        mkdir -p "$base_secrets"
        
        # Copy all contents from temp/secrets to base/secrets
        if cp -r "$temp_secrets/"* "$base_secrets/" 2>/dev/null; then
            log "✅ Secrets directory copied to $base_secrets"
        else
            log "⚠️ Secrets directory exists but is empty"
        fi
    else
        log "ℹ️ No secrets directory in repository (optional, skipping)"
    fi
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
BRANCH=main
GIT_USER=thiagosol
BASE_DIR="/opt/auto-deploy/$SERVICE"    
TEMP_DIR="$BASE_DIR/temp"
LOCK_FILE="$BASE_DIR/.deploy.lock"
GIT_REPO="git@github.com:$GIT_USER/$SERVICE.git"

# Check if service name was provided
if [ -z "$SERVICE" ]; then
    log "❌ ERROR: Service name is required!"
    log "Usage: $0 <service-name> [git-user]"
    log "Secrets will be loaded automatically from thiagosol/secrets repository"
    exit 1
fi

# Create base directory if it doesn't exist
mkdir -p "$BASE_DIR"

# Check for existing lock (another deploy in progress)
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))
    
    # Check if the process is still running
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "🔒 DEPLOY BLOCKED: Another deployment for '$SERVICE' is already in progress (PID: $LOCK_PID)"
        log "⏳ Please wait for the current deployment to finish."
        exit 2
    elif [ $LOCK_AGE -lt 3600 ]; then
        # Lock exists but process is dead, and lock is less than 1 hour old
        log "⚠️ Found stale lock file from $(date -d @$LOCK_TIME 2>/dev/null || date -r $LOCK_TIME 2>/dev/null)"
        log "🔓 Removing stale lock and proceeding..."
        rm -f "$LOCK_FILE"
    else
        # Lock is very old (> 1 hour), definitely stale
        log "⚠️ Found very old lock file, removing..."
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file with current PID
echo $$ > "$LOCK_FILE"
log "🔒 Deployment lock acquired for '$SERVICE' (PID: $$)"

# Load secrets from GitHub repository
if ! load_secrets; then
    log "❌ ERROR: Failed to load secrets"
    notify_github "failure" "Failed to load secrets from repository"
    exit 1
fi

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

# Build new image FIRST (without stopping anything)
if [ -f "$TEMP_DIR/Dockerfile" ]; then
    log "🔨 Building new Docker image..."
    DOCKER_BUILD_CMD="docker build --memory=6g --rm --force-rm -t ${SERVICE}:new"

    # Pass all exported environment variables as build args
    log "📦 Adding build arguments from secrets..."
    while IFS='=' read -r -d '' key value; do
        if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            DOCKER_BUILD_CMD+=" --build-arg ${key}=\"${value}\""
        fi
    done < <(env -0)

    DOCKER_BUILD_CMD+=" $TEMP_DIR"

    eval "$DOCKER_BUILD_CMD" || { log "ERROR: Docker build failed"; notify_github "failure" "Docker build failed"; exit 1; }
    
    log "✅ New image built successfully!"
    
    # Backup the old image before replacing it
    EXISTING_IMAGE=$(docker images -q "$SERVICE:latest" 2>/dev/null)
    if [ -n "$EXISTING_IMAGE" ]; then
        log "💾 Creating backup of current image..."
        docker tag "$SERVICE:latest" "${SERVICE}:backup" 2>/dev/null || true
        docker tag "$SERVICE" "${SERVICE}:old" 2>/dev/null || true
    fi
    
    # Tag the new image with the service name
    docker tag "${SERVICE}:new" "$SERVICE:latest" || { log "ERROR: Failed to tag image"; notify_github "failure" "Failed to tag image"; exit 1; }
    docker tag "${SERVICE}:new" "$SERVICE" || { log "ERROR: Failed to tag image"; notify_github "failure" "Failed to tag image"; exit 1; }
    
    # Remove the temporary 'new' tag
    docker rmi "${SERVICE}:new" 2>/dev/null || true
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

# Copy secrets directory if exists
copy_secrets_directory

# Now render only the configured files in base dir
render_files_list "$BASE_DIR"

log "🛠️ Cleaning temporary directories..."
rm -rf "$TEMP_DIR"

cd "$BASE_DIR" || { log "ERROR: Failed to access base directory"; notify_github "failure" "Failed to access base directory"; exit 1; }

log "🚀 Updating containers with Docker Compose (zero-downtime)..."
# Using 'up -d' without 'down' allows Docker Compose to do a rolling update
# It will stop the old container and start the new one minimizing downtime
if ! docker-compose -f "$COMPOSE_BASENAME" up -d --remove-orphans; then
    log "❌ ERROR: Docker Compose failed to start with new image!"
    
    # Check if we have a backup to rollback
    BACKUP_IMAGE=$(docker images -q "${SERVICE}:backup" 2>/dev/null)
    if [ -n "$BACKUP_IMAGE" ]; then
        log "🔄 Attempting ROLLBACK to previous working image..."
        
        # Restore the backup image
        docker tag "${SERVICE}:backup" "$SERVICE:latest"
        docker tag "${SERVICE}:backup" "$SERVICE"
        
        # Try to start with the old image
        if docker-compose -f "$COMPOSE_BASENAME" up -d --remove-orphans; then
            log "✅ Rollback successful! Service restored to previous version."
            # Clean the failed 'new' image
            docker images "${SERVICE}" --format "{{.ID}}" | head -n 1 | xargs -r docker rmi -f 2>/dev/null || true
        else
            log "❌ CRITICAL: Rollback also failed!"
        fi
    else
        log "⚠️ No backup image found. Cannot rollback."
    fi
    
    notify_github "failure" "Docker Compose failed to start - rollback attempted"
    exit 1
fi

log "✅ Containers updated successfully!"

log "🧹 Cleaning unused/dangling images..."
docker images -f "dangling=true" -q | xargs -r docker rmi -f || log "⚠️ No dangling images to remove"

# Remove backup images now that deployment was successful
BACKUP_IMAGE=$(docker images -q "${SERVICE}:backup" 2>/dev/null)
if [ -n "$BACKUP_IMAGE" ]; then
    log "🗑️ Removing backup image (deploy successful)..."
    docker rmi "${SERVICE}:backup" 2>/dev/null || log "⚠️ Could not remove backup image"
    docker rmi "${SERVICE}:old" 2>/dev/null || true
fi

# Remove old untagged images
OLD_IMAGES=$(docker images "$SERVICE" --filter "dangling=false" --format "{{.ID}} {{.Tag}}" | grep -v "latest" | grep -v "backup" | awk '{print $1}' | head -n 5)
if [ -n "$OLD_IMAGES" ]; then
    log "🗑️ Removing old versions of $SERVICE..."
    echo "$OLD_IMAGES" | xargs -r docker rmi -f 2>/dev/null || log "⚠️ Some old images are still in use"
fi

log "✅ Deployment completed successfully!"
notify_github "success" "Deployment completed successfully"
exit 0
