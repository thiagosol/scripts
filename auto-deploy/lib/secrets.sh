#!/bin/bash

# Secrets management

# Global variable to store service-specific secrets temporarily
SERVICE_SECRETS_CACHE_DIR=""

# Load secrets from GitHub repository
load_secrets() {
    local service="$1"
    local environment="${ENVIRONMENT:-prod}"
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
    
    # Check if service-specific secrets exist and cache them
    local service_secrets_path="$secrets_dir/$service/$environment"
    if [ -d "$service_secrets_path" ]; then
        log "📂 Found service-specific secrets for $service/$environment"
        
        # Cache secrets in a temporary location (outside TEMP_DIR)
        SERVICE_SECRETS_CACHE_DIR="/tmp/deploy-service-secrets-$$"
        mkdir -p "$SERVICE_SECRETS_CACHE_DIR"
        
        # Copy all contents to cache
        if cp -r "$service_secrets_path/"* "$SERVICE_SECRETS_CACHE_DIR/" 2>/dev/null; then
            log "✅ Service-specific secrets cached temporarily"
        else
            log "⚠️ Service secrets directory exists but is empty"
            rm -rf "$SERVICE_SECRETS_CACHE_DIR"
            SERVICE_SECRETS_CACHE_DIR=""
        fi
    else
        log "ℹ️ No service-specific secrets found at $service/$environment (optional, skipping)"
    fi
    
    # Clean up secrets repository clone
    rm -rf "$secrets_dir"
    
    return 0
}

# Apply cached service-specific secrets to TEMP_DIR
# Must be called AFTER clone_repository
apply_service_secrets() {
    local temp_dir="$1"
    
    if [ -z "$SERVICE_SECRETS_CACHE_DIR" ] || [ ! -d "$SERVICE_SECRETS_CACHE_DIR" ]; then
        log "ℹ️ No service-specific secrets to apply"
        return 0
    fi
    
    log "📂 Applying service-specific secrets..."
    
    # Create secrets directory in temp
    local dest_secrets_dir="$temp_dir/secrets"
    mkdir -p "$dest_secrets_dir"
    
    # Copy cached secrets to temp/secrets
    if cp -r "$SERVICE_SECRETS_CACHE_DIR/"* "$dest_secrets_dir/" 2>/dev/null; then
        log "✅ Service-specific secrets applied to $dest_secrets_dir"
    else
        log "⚠️ Failed to apply service secrets"
    fi
    
    # Clean up cache
    rm -rf "$SERVICE_SECRETS_CACHE_DIR"
    SERVICE_SECRETS_CACHE_DIR=""
    
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
