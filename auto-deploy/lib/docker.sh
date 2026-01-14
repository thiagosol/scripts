#!/bin/bash

# Docker operations

# Build Docker image
build_docker_image() {
    local service="$1"
    local temp_dir="$2"
    
    if [ ! -f "$temp_dir/Dockerfile" ]; then
        log "⚠️ No Dockerfile found. Skipping build step."
        return 0
    fi
    
    log "🔨 Building new Docker image..."
    
    # Enable BuildKit for better performance and caching
    export DOCKER_BUILDKIT=1
    
    local docker_build_cmd="docker build --memory=6g --rm --force-rm"
    docker_build_cmd+=" --cache-from ${service}:latest"
    docker_build_cmd+=" -t ${service}:new"
    
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
        return 1
    fi
    
    log "✅ New image built successfully!"
    return 0
}

# Backup existing Docker image
backup_docker_image() {
    local service="$1"
    
    local existing_image=$(docker images -q "$service:latest" 2>/dev/null)
    if [ -n "$existing_image" ]; then
        log "💾 Creating backup of current image..."
        run_logged_command "Backup image as :backup" "docker tag \"$service:latest\" \"${service}:backup\"" || true
        run_logged_command "Backup image as :old" "docker tag \"$service\" \"${service}:old\"" || true
        log "✅ Backup created"
    else
        log "ℹ️ No existing image to backup (first deployment?)"
    fi
}

# Tag new Docker image
tag_docker_image() {
    local service="$1"
    
    log "🏷️ Tagging new image..."
    
    if ! run_logged_command "Tag image as latest" "docker tag \"${service}:new\" \"$service:latest\""; then
        log "❌ ERROR: Failed to tag image as latest"
        return 1
    fi
    
    if ! run_logged_command "Tag image as service name" "docker tag \"${service}:new\" \"$service\""; then
        log "❌ ERROR: Failed to tag image"
        return 1
    fi
    
    # Remove the temporary 'new' tag
    run_logged_command "Remove temporary tag" "docker rmi \"${service}:new\"" 2>/dev/null || true
    
    log "✅ Image tagged successfully"
    return 0
}

# Rollback to backup image
rollback_docker_image() {
    local service="$1"
    
    local backup_image=$(docker images -q "${service}:backup" 2>/dev/null)
    if [ -z "$backup_image" ]; then
        log "⚠️ No backup image found. Cannot rollback."
        return 1
    fi
    
    log "🔄 Attempting ROLLBACK to previous working image..."
    
    # Restore the backup image
    run_logged_command "Restore backup as :latest" "docker tag \"${service}:backup\" \"$service:latest\""
    run_logged_command "Restore backup as service name" "docker tag \"${service}:backup\" \"$service\""
    
    log "✅ Rollback completed"
    return 0
}

# Clean up old Docker images
cleanup_docker_images() {
    local service="$1"
    
    log "🧹 Cleaning unused/dangling images..."
    docker images -f "dangling=true" -q | xargs -r docker rmi -f 2>/dev/null || log "ℹ️ No dangling images to remove"
    
    # Remove backup images now that deployment was successful
    local backup_image=$(docker images -q "${service}:backup" 2>/dev/null)
    if [ -n "$backup_image" ]; then
        log "🗑️ Removing backup image (deploy successful)..."
        docker rmi "${service}:backup" 2>/dev/null || log "⚠️ Could not remove backup image"
        docker rmi "${service}:old" 2>/dev/null || true
    fi
    
    # Remove old untagged images
    local old_images=$(docker images "$service" --filter "dangling=false" --format "{{.ID}} {{.Tag}}" | grep -v "latest" | grep -v "backup" | awk '{print $1}' | head -n 5)
    if [ -n "$old_images" ]; then
        log "🗑️ Removing old versions of $service..."
        echo "$old_images" | xargs -r docker rmi -f 2>/dev/null || log "⚠️ Some old images are still in use"
    fi
}
