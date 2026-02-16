#!/bin/bash

# Docker operations

# Global flag to track if Docker image was built
DOCKER_IMAGE_BUILT=false

# Get Docker image name (from .autodeploy.ini or default to service name)
get_image_name() {
    if [ -n "$AUTODEPLOY_IMAGE_NAME" ]; then
        echo "$AUTODEPLOY_IMAGE_NAME"
    else
        echo "$SERVICE"
    fi
}

# Clone external repositories before main build
# This makes external repo files available in the temp directory for the main build
# Format: user/repo or user/repo:branch (defaults to main if branch not specified)
# Repos are cloned into temp_dir/external-repos/
clone_external_repos() {
    [ ${#AUTODEPLOY_EXTERNAL_REPOS[@]} -eq 0 ] && return 0
    
    log "📦 Cloning external repositories..."
    
    local temp_dir="$1"
    local external_repos_dir="$temp_dir/external-repos"
    mkdir -p "$external_repos_dir"
    
    for repo_spec in "${AUTODEPLOY_EXTERNAL_REPOS[@]}"; do
        repo_spec="$(trim "$repo_spec")"
        [ -z "$repo_spec" ] && continue
        
        # Parse repo spec: user/repo or user/repo:branch
        local repo_name=""
        local repo_branch="main"
        
        if [[ "$repo_spec" == *":"* ]]; then
            repo_name="${repo_spec%%:*}"
            repo_branch="${repo_spec#*:}"
        else
            repo_name="$repo_spec"
        fi
        
        # Extract repo name for directory
        local repo_dir_name=$(basename "$repo_name")
        local repo_clone_dir="$external_repos_dir/$repo_dir_name"
        
        log "📦 Cloning repository: $repo_name (branch: $repo_branch)"
        
        # Clone the repository
        local repo_url="git@github.com:${repo_name}.git"
        if ! run_logged_command "Clone external repo" "git clone --depth=1 --branch \"$repo_branch\" \"$repo_url\" \"$repo_clone_dir\""; then
            log "⚠️ Failed to clone $repo_name with branch $repo_branch, trying main branch..."
            # Try main branch as fallback
            if ! run_logged_command "Clone external repo (main)" "git clone --depth=1 --branch main \"$repo_url\" \"$repo_clone_dir\""; then
                log "❌ Failed to clone $repo_name, skipping..."
                continue
            fi
        fi
        
        log "✅ Repository cloned: $repo_name -> $repo_clone_dir"
    done
    
    log "✅ External repositories cloned and available in temp directory"
}

# Build Docker image
build_docker_image() {
    local service="$1"
    local temp_dir="$2"
    
    if [ ! -f "$temp_dir/Dockerfile" ]; then
        log "⚠️ No Dockerfile found. Skipping build step."
        DOCKER_IMAGE_BUILT=false
        return 0
    fi
    
    # Get image name (from .autodeploy.ini or default to service name)
    local image_name=$(get_image_name)
    
    if [ "$image_name" != "$service" ]; then
        log "🐳 Using custom image name: $image_name (from .autodeploy.ini)"
    fi
    
    log "🔨 Building new Docker image: ${image_name}..."
    
    # Enable BuildKit for better performance and caching
    export DOCKER_BUILDKIT=1
    
    # Limit to 2 CPUs using taskset (if available)
    local cpu_limit=""
    if command -v taskset &> /dev/null; then
        cpu_limit="taskset -c 0-1 "
        log "⚙️ Limiting build to 2 CPUs (cores 0-1)"
    fi
    
    # Build command with proper buildx flags (--rm and --force-rm are not supported by buildx)
    local docker_build_cmd="${cpu_limit}docker buildx build"
    docker_build_cmd+=" --memory=5g --memory-swap=9g"
    
    # Try to use cache from existing local image (ignore errors if image doesn't exist)
    if docker image inspect "${image_name}:latest" &>/dev/null; then
        docker_build_cmd+=" --cache-from ${image_name}:latest"
        log "📦 Using build cache from: ${image_name}:latest"
    fi
    
    docker_build_cmd+=" --load -t ${image_name}:new"
    
    # Add build arguments from environment variables
    log "📦 Adding build arguments from secrets..."
    while IFS='=' read -r -d '' key value; do
        if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            docker_build_cmd+=" --build-arg ${key}=\"${value}\""
        fi
    done < <(env -0)
    
    docker_build_cmd+=" $temp_dir"
    
    if ! run_command_realtime "Docker build" "$docker_build_cmd"; then
        log "❌ ERROR: Docker build failed"
        DOCKER_IMAGE_BUILT=false
        return 1
    fi
    
    log "✅ New image built successfully: ${image_name}:new"
    DOCKER_IMAGE_BUILT=true
    return 0
}

# Backup existing Docker image
backup_docker_image() {
    local service="$1"
    local image_name=$(get_image_name)
    
    local existing_image=$(docker images -q "$image_name:latest" 2>/dev/null)
    if [ -n "$existing_image" ]; then
        log "💾 Creating backup of current image..."
        run_logged_command "Backup image as :backup" "docker tag \"$image_name:latest\" \"${image_name}:backup\"" || true
        run_logged_command "Backup image as :old" "docker tag \"$image_name\" \"${image_name}:old\"" || true
        log "✅ Backup created"
    else
        log "ℹ️ No existing image to backup (first deployment?)"
    fi
}

# Tag new Docker image
tag_docker_image() {
    local service="$1"
    local image_name=$(get_image_name)
    
    log "🏷️ Tagging new image..."
    
    if ! run_logged_command "Tag image as latest" "docker tag \"${image_name}:new\" \"$image_name:latest\""; then
        log "❌ ERROR: Failed to tag image as latest"
        return 1
    fi
    
    if ! run_logged_command "Tag image as base name" "docker tag \"${image_name}:new\" \"$image_name\""; then
        log "❌ ERROR: Failed to tag image"
        return 1
    fi
    
    # Remove the temporary 'new' tag
    run_logged_command "Remove temporary tag" "docker rmi \"${image_name}:new\"" 2>/dev/null || true
    
    log "✅ Image tagged successfully: $image_name"
    return 0
}

# Rollback to backup image
rollback_docker_image() {
    local service="$1"
    local image_name=$(get_image_name)
    
    local backup_image=$(docker images -q "${image_name}:backup" 2>/dev/null)
    if [ -z "$backup_image" ]; then
        log "⚠️ No backup image found. Cannot rollback."
        return 1
    fi
    
    log "🔄 Attempting ROLLBACK to previous working image..."
    
    # Restore the backup image
    run_logged_command "Restore backup as :latest" "docker tag \"${image_name}:backup\" \"$image_name:latest\""
    run_logged_command "Restore backup as base name" "docker tag \"${image_name}:backup\" \"$image_name\""
    
    log "✅ Rollback completed: $image_name"
    return 0
}

# Clean up old Docker images
cleanup_docker_images() {
    local service="$1"
    local image_name=$(get_image_name)
    
    log "🧹 Cleaning unused/dangling images..."
    docker images -f "dangling=true" -q | xargs -r docker rmi -f 2>/dev/null || log "ℹ️ No dangling images to remove"
    
    # Remove backup images now that deployment was successful
    local backup_image=$(docker images -q "${image_name}:backup" 2>/dev/null)
    if [ -n "$backup_image" ]; then
        log "🗑️ Removing backup image (deploy successful)..."
        docker rmi "${image_name}:backup" 2>/dev/null || log "⚠️ Could not remove backup image"
        docker rmi "${image_name}:old" 2>/dev/null || true
    fi
    
    # Remove old untagged images
    local old_images=$(docker images "$image_name" --filter "dangling=false" --format "{{.ID}} {{.Tag}}" | grep -v "latest" | grep -v "backup" | awk '{print $1}' | head -n 5)
    if [ -n "$old_images" ]; then
        log "🗑️ Removing old versions of $image_name..."
        echo "$old_images" | xargs -r docker rmi -f 2>/dev/null || log "⚠️ Some old images are still in use"
    fi
}

# Stop buildx builder containers to free up RAM
cleanup_buildx_builder() {
    log "🧹 Stopping buildx builder containers..."
    
    # Find all buildx builder containers
    local buildx_containers=$(docker ps --filter "ancestor=moby/buildkit:buildx-stable-1" --format "{{.Names}}" 2>/dev/null)
    
    if [ -z "$buildx_containers" ]; then
        log "ℹ️ No buildx builder containers running"
        return 0
    fi
    
    # Stop each builder container
    while IFS= read -r container_name; do
        if [ -n "$container_name" ]; then
            log "🛑 Stopping buildx container: $container_name"
            docker stop "$container_name" >/dev/null 2>&1 || log "⚠️ Could not stop $container_name"
        fi
    done <<< "$buildx_containers"
    
    log "✅ Buildx builders stopped (will auto-start on next build)"
}
