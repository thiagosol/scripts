#!/bin/bash

# Secrets management

# Load secrets from GitHub repository
load_secrets() {
    local service="$1"
    local environment="${ENVIRONMENT:-prod}"
    local temp_dir="${TEMP_DIR}"
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
    
    log "✅ Secrets loaded successfully! ($count variables exported)"
    
    # Copy service-specific secrets if they exist
    local service_secrets_path="$secrets_dir/$service/$environment"
    if [ -d "$service_secrets_path" ]; then
        log "📂 Found service-specific secrets for $service/$environment"
        
        # Create secrets directory in temp
        local dest_secrets_dir="$temp_dir/secrets"
        mkdir -p "$dest_secrets_dir"
        
        # Copy all contents from service/environment to temp/secrets
        if cp -r "$service_secrets_path/"* "$dest_secrets_dir/" 2>/dev/null; then
            log "✅ Copied service-specific secrets to $dest_secrets_dir"
        else
            log "⚠️ Service secrets directory exists but is empty"
        fi
    else
        log "ℹ️ No service-specific secrets found at $service/$environment (optional, skipping)"
    fi
    
    # Clean up secrets repository clone
    rm -rf "$secrets_dir"
    
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
