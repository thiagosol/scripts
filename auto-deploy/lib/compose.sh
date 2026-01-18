#!/bin/bash

# Docker Compose operations

# Get project name (custom or default)
get_project_name() {
    if [ -n "$AUTODEPLOY_PROJECT_NAME" ]; then
        echo "$AUTODEPLOY_PROJECT_NAME"
    else
        echo "${SERVICE}-${ENVIRONMENT}"
    fi
}

# Deploy with Docker Compose (zero-downtime) - Single file
deploy_single_compose() {
    local service="$1"
    local base_dir="$2"
    local compose_file="$3"
    local project_name="$4"
    
    log "📄 Deploying: $compose_file"
    
    # Verify compose file exists
    if [ ! -f "$base_dir/$compose_file" ]; then
        log "❌ ERROR: Compose file not found: $base_dir/$compose_file"
        return 1
    fi
    
    # Build multi-file command if needed
    local compose_cmd="docker-compose -p \"$project_name\" -f \"$compose_file\""
    
    if run_command_realtime "Docker Compose Up ($compose_file)" "$compose_cmd up -d --remove-orphans"; then
        log "✅ Deployed successfully: $compose_file"
        return 0
    else
        log "❌ ERROR: Failed to deploy: $compose_file"
        return 1
    fi
}

# Deploy with Docker Compose (zero-downtime) - Multiple files support
deploy_with_compose() {
    local service="$1"
    local base_dir="$2"
    shift 2
    local compose_files=("$@")  # Array of compose files
    
    log "🚀 Deploying with Docker Compose..."
    log "   Service: $service"
    log "   Base dir: $base_dir"
    log "   Compose files: ${#compose_files[@]}"
    
    cd "$base_dir" || {
        log "❌ ERROR: Failed to access base directory: $base_dir"
        return 1
    }
    
    log "📍 Current directory: $(pwd)"
    
    local project_name=$(get_project_name)
    log "🏷️ Docker Compose project name: $project_name"
    
    # Deploy each compose file
    local failed=0
    for compose_file in "${compose_files[@]}"; do
        if ! deploy_single_compose "$service" "$base_dir" "$compose_file" "$project_name"; then
            ((failed++))
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log "✅ All compose files deployed successfully! (${#compose_files[@]} file(s))"
        return 0
    else
        log "❌ ERROR: $failed/${#compose_files[@]} compose file(s) failed to deploy"
        return 1
    fi
}

# Rollback deployment with compose
rollback_with_compose() {
    local service="$1"
    local base_dir="$2"
    shift 2
    local compose_files=("$@")  # Array of compose files
    
    log "🔄 Rolling back deployment..."
    log "   Compose files: ${#compose_files[@]}"
    
    cd "$base_dir" || {
        log "❌ ERROR: Failed to access base directory for rollback"
        return 1
    }
    
    local project_name=$(get_project_name)
    log "🏷️ Docker Compose project name: $project_name"
    
    # Try to rollback each compose file
    local failed=0
    for compose_file in "${compose_files[@]}"; do
        log "📄 Rolling back: $compose_file"
        
        if [ ! -f "$base_dir/$compose_file" ]; then
            log "⚠️ Compose file not found for rollback: $compose_file"
            ((failed++))
            continue
        fi
        
        local compose_cmd="docker-compose -p \"$project_name\" -f \"$compose_file\""
        if run_command_realtime "Docker Compose Rollback ($compose_file)" "$compose_cmd up -d --remove-orphans"; then
            log "✅ Rolled back successfully: $compose_file"
        else
            log "❌ Rollback failed: $compose_file"
            ((failed++))
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log "✅ Rollback successful! Service restored to previous version."
        # Clean the failed 'new' image
        docker images "${service}" --format "{{.ID}}" | head -n 1 | xargs -r docker rmi -f 2>/dev/null || true
        return 0
    else
        log "❌ CRITICAL: Rollback failed for $failed/${#compose_files[@]} file(s)!"
        return 1
    fi
}

# Global array to store compose file basenames
declare -a COMPOSE_FILE_BASENAMES

# Find and move compose files
# Returns:
#   0 - Compose file(s) found and prepared
#   2 - No compose file found (not an error, just build-only mode)
#   1 - Error moving/preparing compose file
prepare_compose_files() {
    local temp_dir="$1"
    local base_dir="$2"
    
    COMPOSE_FILE_BASENAMES=()  # Reset array
    
    log "📂 Preparing compose files..."
    
    # Determine which files to look for
    if [ ${#AUTODEPLOY_COMPOSE_FILES[@]} -gt 0 ]; then
        # Use configured files from .autodeploy.ini
        log "📋 Using configured compose files from .autodeploy.ini"
        for compose_file in "${AUTODEPLOY_COMPOSE_FILES[@]}"; do
            local compose_src="$temp_dir/$compose_file"
            
            if [ ! -f "$compose_src" ]; then
                log "⚠️ Configured compose file not found: $compose_file"
                continue
            fi
            
            local basename="$(basename "$compose_src")"
            log "📄 Moving $basename to $base_dir..."
            
            if ! mv "$compose_src" "$base_dir/$basename"; then
                log "❌ ERROR: Failed to move compose file: $basename"
                return 1
            fi
            
            COMPOSE_FILE_BASENAMES+=("$basename")
            log "✅ Ready: $basename"
        done
    else
        # Auto-discover docker-compose*.yml files
        log "🔍 Auto-discovering docker-compose*.yml files..."
        while IFS= read -r compose_src; do
            [ -z "$compose_src" ] && continue
            
            local basename="$(basename "$compose_src")"
            log "📄 Moving $basename to $base_dir..."
            
            if ! mv "$compose_src" "$base_dir/$basename"; then
                log "❌ ERROR: Failed to move compose file: $basename"
                return 1
            fi
            
            COMPOSE_FILE_BASENAMES+=("$basename")
            log "✅ Ready: $basename"
        done < <(find "$temp_dir" -maxdepth 1 -type f -name 'docker-compose*.yml')
    fi
    
    # Check if any files were found
    if [ ${#COMPOSE_FILE_BASENAMES[@]} -eq 0 ]; then
        log "⚠️ No docker-compose files found in $temp_dir"
        log "ℹ️ Running in BUILD-ONLY mode (image will be built but not deployed)"
        return 2  # Not an error, just no compose
    fi
    
    log "✅ Prepared ${#COMPOSE_FILE_BASENAMES[@]} compose file(s)"
    return 0
}
