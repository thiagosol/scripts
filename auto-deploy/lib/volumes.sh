#!/bin/bash

# Volume management

# Copy secrets directory if it exists in temp
copy_secrets_directory() {
    local temp_dir="$1"
    local base_dir="$2"
    
    local temp_secrets="$temp_dir/secrets"
    local base_secrets="$base_dir/secrets"
    
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

# Process Docker volumes from docker-compose.yml
process_volumes() {
    local temp_dir="$1"
    local base_dir="$2"
    local compose_file="$3"
    
    log "🛠️ Checking volumes..."
    
    local volumes=$(grep -oP '(?<=- \./)[^:]+' "$base_dir/$compose_file" 2>/dev/null)
    
    if [ -z "$volumes" ]; then
        log "ℹ️ No local volumes found in docker-compose"
        return 0
    fi
    
    for vol in $volumes; do
        local src="$temp_dir/$vol"
        local dest="$base_dir/$vol"
        
        if [ -e "$src" ]; then
            if [ -e "$dest" ]; then
                log "📁 Volume $dest already exists, copying contents..."
                cp -r "$src"/* "$dest/" 2>/dev/null || log "⚠️ Error copying contents of $src, skipping..."
            else
                log "📁 Moving volume $src to $dest..."
                mv "$src" "$dest" || log "⚠️ Error moving $src, skipping..."
            fi
        else
            log "⚠️ Volume $src not found in repository, skipping..."
        fi
        
        # Ensure volume directory exists
        if [ ! -e "$dest" ]; then
            log "📁 Creating empty volume at $dest..."
            mkdir -p "$dest"
            chmod 777 -R "$dest"
        fi
    done
    
    log "✅ Volumes processed"
    return 0
}
