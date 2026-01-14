#!/bin/bash

# Git operations

# Clone repository
clone_repository() {
    local service="$1"
    local git_repo="$2"
    local branch="$3"
    local temp_dir="$4"
    
    log "📥 Cloning repository $git_repo (branch: $branch)..."
    
    if ! run_logged_command "Git clone" "git clone --depth=1 --branch \"$branch\" \"$git_repo\" \"$temp_dir\""; then
        log "❌ ERROR: Git clone failed"
        return 1
    fi
    
    log "✅ Repository cloned successfully"
    return 0
}

# Prepare temporary directory
prepare_temp_directory() {
    local temp_dir="$1"
    
    # Clean existing temp directory
    if [ -d "$temp_dir" ]; then
        sudo chown -R "$(whoami)":"$(whoami)" "$temp_dir" 2>/dev/null || true
        rm -rf "$temp_dir"
    fi
    
    # Create fresh temp directory
    mkdir -p "$temp_dir"
    log "📂 Temporary directory prepared: $temp_dir"
}
