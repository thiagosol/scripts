#!/bin/bash

# Docker Compose operations

# Deploy with Docker Compose (zero-downtime)
deploy_with_compose() {
    local service="$1"
    local base_dir="$2"
    local compose_file="$3"
    
    cd "$base_dir" || {
        log "❌ ERROR: Failed to access base directory"
        return 1
    }
    
    log "🚀 Updating containers with Docker Compose (zero-downtime)..."
    
    # Using 'up -d' without 'down' allows Docker Compose to do a rolling update
    # It will stop the old container and start the new one minimizing downtime
    if run_command_realtime "Docker Compose Up" "docker-compose -f \"$compose_file\" up -d --remove-orphans"; then
        log "✅ Containers updated successfully!"
        return 0
    else
        log "❌ ERROR: Docker Compose failed to start with new image!"
        return 1
    fi
}

# Rollback deployment with compose
rollback_with_compose() {
    local service="$1"
    local base_dir="$2"
    local compose_file="$3"
    
    cd "$base_dir" || return 1
    
    # Try to start with the old image
    if run_command_realtime "Docker Compose Rollback" "docker-compose -f \"$compose_file\" up -d --remove-orphans"; then
        log "✅ Rollback successful! Service restored to previous version."
        # Clean the failed 'new' image
        docker images "${service}" --format "{{.ID}}" | head -n 1 | xargs -r docker rmi -f 2>/dev/null || true
        return 0
    else
        log "❌ CRITICAL: Rollback also failed!"
        return 1
    fi
}

# Find and move compose file
prepare_compose_file() {
    local temp_dir="$1"
    local base_dir="$2"
    local autodeploy_compose_file="$3"
    
    local compose_src=""
    
    # Choose compose file
    if [ -n "$autodeploy_compose_file" ]; then
        compose_src="$temp_dir/$autodeploy_compose_file"
    else
        compose_src="$(find "$temp_dir" -maxdepth 1 -type f -name 'docker-compose*.yml' | head -n 1)"
    fi
    
    if [ -z "$compose_src" ] || [ ! -f "$compose_src" ]; then
        log "❌ ERROR: No docker-compose file found"
        return 1
    fi
    
    local compose_basename="$(basename "$compose_src")"
    log "📂 Moving $compose_basename to $base_dir..."
    
    if ! mv "$compose_src" "$base_dir/$compose_basename"; then
        log "❌ ERROR: Failed to move compose file"
        return 1
    fi
    
    # Return the basename for later use
    echo "$compose_basename"
    return 0
}
