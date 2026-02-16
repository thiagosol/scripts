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

# Global variable to store exported image paths for docker-container driver
declare -A EXPORTED_IMAGE_PATHS
EXPORTED_IMAGES_TEMP_DIR=""

# Load external images into buildx builder before build
# This ensures external images are available during build stages (e.g., COPY --from, FROM)
# Buildx uses a separate builder container, so we need to explicitly load local images
# For local-only images with docker-container driver, we export and use type=local cache
# Supports both local images (already on server) and remote images (will be pulled)
load_external_images() {
    [ ${#AUTODEPLOY_EXTERNAL_IMAGES[@]} -eq 0 ] && return 0
    
    log "📥 Loading external images into buildx builder..."
    
    # Create a temporary directory for exported images (needs to persist until main build)
    EXPORTED_IMAGES_TEMP_DIR=$(mktemp -d)
    # This will be cleaned up after the main build completes
    
    # Create a temporary directory for dummy Dockerfiles (can be cleaned up immediately)
    local temp_dockerfile_dir=$(mktemp -d)
    trap "rm -rf '$temp_dockerfile_dir'" RETURN
    
    for image in "${AUTODEPLOY_EXTERNAL_IMAGES[@]}"; do
        image="$(trim "$image")"
        [ -z "$image" ] && continue
        
        # First, check if image already exists locally (could be a local-only image)
        if docker image inspect "$image" >/dev/null 2>&1; then
            log "🔄 Loading local image into buildx builder: $image"
            
            # For docker-container driver, we need to make the image available in the builder
            # The best approach is to do a build that uses --load, which makes buildx access
            # the local daemon to get the base image, then it becomes available in builder cache
            
            local safe_image_name="${image//\//_}"
            safe_image_name="${safe_image_name//:/_}"
            local dummy_dockerfile="$temp_dockerfile_dir/Dockerfile.$safe_image_name"
            
            # Create a minimal Dockerfile that uses the local image
            echo "FROM $image" > "$dummy_dockerfile"
            echo "RUN echo 'Preloading image into buildx'" >> "$dummy_dockerfile"
            
            # Do a build with --load - this forces buildx to access the local daemon
            # to get the base image, making it available in the builder cache
            local temp_tag="buildx-preload-$(date +%s)-$RANDOM"
            local build_output=$(mktemp)
            
            log "  📦 Preloading image into buildx builder cache..."
            
            # The key issue: docker-container driver tries registry first, then local daemon
            # We need to force buildx to load from local daemon by doing a build that requires it
            # Using --load forces buildx to access local daemon to store the result
            
            # Try building with --load - this should make buildx access local daemon for the base image
            # when using docker-container driver with proper socket access
            local build_success=false
            if docker buildx build --load -f "$dummy_dockerfile" -t "$temp_tag" "$temp_dockerfile_dir" >"$build_output" 2>&1; then
                build_success=true
                docker rmi "$temp_tag" >/dev/null 2>&1 || true
                log "  ✓ Image preloaded into buildx builder: $image"
            else
                # Check the error - if it's about not finding the image, we need a different approach
                local error_content=$(cat "$build_output" 2>/dev/null || echo "")
                
                if echo "$error_content" | grep -qi "failed to solve\|pull access denied\|repository does not exist\|authorization failed"; then
                    log "  ⚠️ Buildx cannot resolve local image (docker-container driver)"
                    log "  🔧 Exporting image for use with --cache-from type=local..."
                    
                    # For docker-container driver, we need to export the image and use type=local
                    # Use the persistent directory so the tar survives until main build
                    local image_tar="$EXPORTED_IMAGES_TEMP_DIR/${safe_image_name}.tar"
                    if docker save "$image" -o "$image_tar" 2>/dev/null; then
                        # Store the path for use in the main build
                        EXPORTED_IMAGE_PATHS["$image"]="$image_tar"
                        log "  ✓ Image exported: $image"
                        log "  ℹ️  Will use type=local cache in main build"
                    else
                        log "  ❌ Failed to export image: $image"
                        log "  💡 Please ensure image exists: docker images | grep $(echo $image | cut -d: -f1)"
                    fi
                else
                    log "  ⚠️ Build failed (may still work in main build): $image"
                fi
            fi
            
            rm -f "$build_output" >/dev/null 2>&1 || true
            docker rmi "$temp_tag" >/dev/null 2>&1 || true
            continue
        fi
        
        # Image doesn't exist locally, try to pull it
        log "📥 Pulling external image from registry: $image"
        
        # Pull the image to make it available locally
        if ! run_logged_command "Pull image $image" "docker pull \"$image\""; then
            log "⚠️ Failed to pull image: $image"
            log "ℹ️  Image may be local-only or will be created during build"
            continue
        fi
        
        # After pulling, also try to load it into buildx builder (optional, --cache-from should work)
        log "🔄 Image pulled successfully: $image"
        # Pulled images should be accessible via --cache-from, so we don't need to force load them
    done
    
    log "✅ External images loaded into buildx builder context"
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
    
    # Add external images as --cache-from to force buildx to load them into builder context
    # For docker-container driver with local images, use type=local with exported tar files
    if [ ${#AUTODEPLOY_EXTERNAL_IMAGES[@]} -gt 0 ]; then
        log "📥 Adding external images to buildx context via --cache-from..."
        for ext_image in "${AUTODEPLOY_EXTERNAL_IMAGES[@]}"; do
            ext_image="$(trim "$ext_image")"
            [ -z "$ext_image" ] && continue
            
            # Check if image exists locally (including local-only images)
            if docker image inspect "$ext_image" >/dev/null 2>&1; then
                # If we exported this image (for docker-container driver), use type=local
                if [ -n "${EXPORTED_IMAGE_PATHS[$ext_image]}" ] && [ -f "${EXPORTED_IMAGE_PATHS[$ext_image]}" ]; then
                    docker_build_cmd+=" --cache-from type=local,src=${EXPORTED_IMAGE_PATHS[$ext_image]}"
                    log "  ✓ Added as type=local cache: $ext_image"
                else
                    # Regular --cache-from (works for docker driver or if image was preloaded)
                    docker_build_cmd+=" --cache-from $ext_image"
                    log "  ✓ Added to build context: $ext_image"
                fi
            else
                log "  ⚠️ Skipping (not found locally): $ext_image"
            fi
        done
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
        # Clean up exported images on failure
        [ -n "$EXPORTED_IMAGES_TEMP_DIR" ] && rm -rf "$EXPORTED_IMAGES_TEMP_DIR" 2>/dev/null || true
        return 1
    fi
    
    # Clean up exported images after successful build
    [ -n "$EXPORTED_IMAGES_TEMP_DIR" ] && rm -rf "$EXPORTED_IMAGES_TEMP_DIR" 2>/dev/null || true
    
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
