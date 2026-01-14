#!/bin/bash

# Secrets management

# Load secrets from GitHub repository
load_secrets() {
    local service="$1"
    local secrets_dir="/tmp/deploy-secrets-$$"
    local secrets_repo="git@github.com:thiagosol/secrets.git"
    
    log "🔐 Loading secrets from GitHub repository..."
    
    # Clone secrets repository
    if ! run_logged_command "Clone secrets repository" "git clone --depth=1 \"$secrets_repo\" \"$secrets_dir\""; then
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
    local count=0
    while IFS="=" read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            export "$key=$value"
            log "✅ Exported: $key"
            ((count++))
        fi
    done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$secrets_dir/secrets.json")
    
    # Clean up secrets directory
    rm -rf "$secrets_dir"
    
    log "✅ Secrets loaded successfully! ($count variables exported)"
    return 0
}

# Export all environment variables as Docker build args
build_docker_args() {
    local build_cmd="$1"
    
    # Pass all exported environment variables as build args
    while IFS='=' read -r -d '' key value; do
        if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            build_cmd+=" --build-arg ${key}=\"${value}\""
        fi
    done < <(env -0)
    
    echo "$build_cmd"
}
