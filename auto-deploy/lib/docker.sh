#!/bin/bash

# Docker operations

# Global flag to track if Docker image was built
DOCKER_IMAGE_BUILT=false

# Get Docker image name (from .autodeploy.ini or default to service name)
get_image_name() {
    local image_name=""
    
    if [ -n "$AUTODEPLOY_IMAGE_NAME" ]; then
        image_name="$AUTODEPLOY_IMAGE_NAME"
        log "🐳 Using custom image name from .autodeploy.ini: $image_name"
    else
        image_name="$SERVICE"
        log "🐳 Using default image name (service): $image_name"
    fi
    
    echo "$image_name"
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
    
    log "🔨 Building new Docker image: ${image_name}..."
    
    # Enable BuildKit for better performance and caching
    export DOCKER_BUILDKIT=1
    
    local docker_build_cmd="docker build --memory=6g --rm --force-rm"
    docker_build_cmd+=" --cache-from ${image_name}:latest"
    docker_build_cmd+=" -t ${image_name}:new"
    
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
