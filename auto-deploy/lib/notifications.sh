#!/bin/bash

# GitHub Check Runs integration

# Global variable to store check run ID
GITHUB_CHECK_RUN_ID=""

# Generate dynamic Grafana URL for logs
generate_grafana_url() {
    local service="$1"
    local environment="$2"
    local branch="$3"
    local git_user="$4"
    
    # Simple Grafana URL without complex encoding
    # User can filter by labels manually in Grafana UI
    echo "https://log.thiagosol.com/explore"
}

# Create GitHub Check Run at deploy start
create_github_check() {
    local service="$1"
    local head_sha="$2"
    local environment="$3"
    local branch="$4"
    local git_user="$5"
    
    # Check if APP_ID_TOKEN is provided
    if [ -z "$APP_ID_TOKEN" ]; then
        log "ℹ️ APP_ID_TOKEN not provided, skipping GitHub Check Run"
        return 0
    fi
    
    log "🔍 Creating GitHub Check Run..."
    
    # Generate Grafana URL
    local grafana_url=$(generate_grafana_url "$service" "$environment" "$branch" "$git_user")
    
    # Debug info
    log "🔍 GitHub Check Run parameters:"
    log "   Service: $service"
    log "   HEAD SHA: $head_sha"
    log "   Environment: $environment"
    log "   Branch: $branch"
    log "   User: $git_user"
    log "   Token: ${APP_ID_TOKEN:0:7}... (${#APP_ID_TOKEN} chars)"
    
    # Build JSON payload in single line to avoid parsing issues
    local summary="Service: ${service} | Branch: ${branch} | Environment: ${environment} | User: ${git_user}\\n\\nBuilding Docker image and deploying containers..."
    local json_payload="{\"name\":\"Container Deployment\",\"head_sha\":\"${head_sha}\",\"status\":\"in_progress\",\"details_url\":\"${grafana_url}\",\"output\":{\"title\":\"Deploying ${service} to ${environment}\",\"summary\":\"${summary}\"}}"
    
    # Create check run
    local http_code=$(curl -s -w "\n%{http_code}" -X POST "https://api.github.com/repos/thiagosol/${service}/check-runs" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "${json_payload}" 2>&1)
    
    # Split response and HTTP code
    local response=$(echo "$http_code" | head -n -1)
    local code=$(echo "$http_code" | tail -n 1)
    
    log "🌐 GitHub API Response:"
    log "   HTTP Code: $code"
    
    # Extract check run ID from response (root level "id" field)
    if command -v jq &> /dev/null; then
        # Use jq if available (more reliable)
        GITHUB_CHECK_RUN_ID=$(echo "$response" | jq -r '.id' 2>/dev/null)
    else
        # Fallback: parse JSON manually (get first "id" at root level)
        GITHUB_CHECK_RUN_ID=$(echo "$response" | grep -m 1 '"id":' | grep -o '[0-9]\+' | head -1)
    fi
    
    if [ "$code" = "201" ] && [ -n "$GITHUB_CHECK_RUN_ID" ] && [ "$GITHUB_CHECK_RUN_ID" != "null" ]; then
        log "✅ GitHub Check Run created (ID: $GITHUB_CHECK_RUN_ID)"
        return 0
    else
        log "❌ Failed to create GitHub Check Run (non-critical)"
        log "   HTTP Code: $code"
        log "   Extracted ID: ${GITHUB_CHECK_RUN_ID:-empty}"
        
        # Show first 500 chars of response for debugging
        log "   Response preview:"
        echo "$response" | head -c 500 | while IFS= read -r line; do
            log "     $line"
        done
        
        # Parse common errors
        if echo "$response" | grep -q "Bad credentials"; then
            log "   ❌ Error: Invalid or expired GitHub token"
        elif echo "$response" | grep -q "Not Found"; then
            log "   ❌ Error: Repository not found or no access"
        elif echo "$response" | grep -q "Resource not accessible"; then
            log "   ❌ Error: Token lacks 'checks:write' permission"
        elif echo "$response" | grep -q "No commit found"; then
            log "   ❌ Error: Commit SHA not found in repository"
        fi
        
        return 1
    fi
}

# Update GitHub Check Run on success
complete_github_check_success() {
    local service="$1"
    local environment="$2"
    local branch="$3"
    local git_user="$4"
    local deploy_duration="$5"
    
    [ -z "$GITHUB_CHECK_RUN_ID" ] && return 0
    [ -z "$APP_ID_TOKEN" ] && return 0
    
    log "✅ Updating GitHub Check Run (success)..."
    
    # Generate Grafana URL
    local grafana_url=$(generate_grafana_url "$service" "$environment" "$branch" "$git_user")
    
    # Build JSON payload in single line
    local summary="Service: ${service} | Branch: ${branch} | Environment: ${environment} | User: ${git_user} | Duration: ${deploy_duration}\\n\\nDocker image built successfully\\nContainers updated with zero-downtime\\nHealth checks passed"
    local json_payload="{\"status\":\"completed\",\"conclusion\":\"success\",\"details_url\":\"${grafana_url}\",\"output\":{\"title\":\"Deployment successful: ${service}/${branch}\",\"summary\":\"${summary}\"}}"
    
    # Update check run with success
    local http_code=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.github.com/repos/thiagosol/${service}/check-runs/${GITHUB_CHECK_RUN_ID}" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "${json_payload}" 2>&1)
    
    local code=$(echo "$http_code" | tail -n 1)
    
    if [ "$code" = "200" ]; then
        log "✅ GitHub Check Run completed (success)"
    else
        log "⚠️ Failed to update GitHub Check Run (HTTP $code)"
    fi
}

# Update GitHub Check Run on failure
complete_github_check_failure() {
    local service="$1"
    local environment="$2"
    local branch="$3"
    local git_user="$4"
    local error_message="$5"
    
    [ -z "$GITHUB_CHECK_RUN_ID" ] && return 0
    [ -z "$APP_ID_TOKEN" ] && return 0
    
    log "❌ Updating GitHub Check Run (failure)..."
    
    # Generate Grafana URL
    local grafana_url=$(generate_grafana_url "$service" "$environment" "$branch" "$git_user")
    
    # Build JSON payload in single line
    local summary="Service: ${service} | Branch: ${branch} | Environment: ${environment} | User: ${git_user}\\n\\nError: ${error_message}\\n\\nThe deployment has been rolled back to the previous version (if available)."
    local json_payload="{\"status\":\"completed\",\"conclusion\":\"failure\",\"details_url\":\"${grafana_url}\",\"output\":{\"title\":\"Deployment failed: ${service}/${branch}\",\"summary\":\"${summary}\"}}"
    
    # Update check run with failure
    local http_code=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.github.com/repos/thiagosol/${service}/check-runs/${GITHUB_CHECK_RUN_ID}" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "${json_payload}" 2>&1)
    
    local code=$(echo "$http_code" | tail -n 1)
    
    if [ "$code" = "200" ]; then
        log "❌ GitHub Check Run completed (failure)"
    else
        log "⚠️ Failed to update GitHub Check Run (HTTP $code)"
    fi
}
