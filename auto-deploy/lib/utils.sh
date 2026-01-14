#!/bin/bash

# Utility functions
# Note: log() function is defined in logging.sh

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    echo "$s"
}

# Determine environment based on branch
get_environment_from_branch() {
    local branch="$1"
    case "$branch" in
        main|master)
            echo "prod"
            ;;
        dev|develop|development)
            echo "dev"
            ;;
        staging|stage)
            echo "staging"
            ;;
        *)
            echo "dev"  # default
            ;;
    esac
}

# Set executable permissions for all .sh files in service directory
set_executable_permissions() {
    local base_dir="$1"
    
    if [ ! -d "$base_dir" ]; then
        log "⚠️ Directory $base_dir does not exist, skipping chmod"
        return 0
    fi
    
    local sh_count=$(find "$base_dir" -type f -name "*.sh" 2>/dev/null | wc -l)
    
    if [ "$sh_count" -eq 0 ]; then
        log "ℹ️ No .sh files found in $base_dir"
        return 0
    fi
    
    log "🔧 Setting executable permissions for $sh_count .sh file(s)..."
    find "$base_dir" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log "✅ Executable permissions set successfully"
    else
        log "⚠️ Failed to set some permissions (non-critical)"
    fi
    
    return 0
}
