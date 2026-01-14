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
    
    # URL-encode the LogQL query
    local query="{service=\"${service}\",type=\"deploy\",environment=\"${environment}\",branch=\"${branch}\",git_user=\"${git_user}\"}"
    
    # Grafana explore URL with dynamic labels
    echo "https://log.thiagosol.com/explore?orgId=1&left=%7B%22datasource%22%3A%22a0d36381-92c9-4a2b-ba29-d9bbb0090398%22%2C%22queries%22%3A%5B%7B%22expr%22%3A%22${query}%22%7D%5D%2C%22range%22%3A%7B%22from%22%3A%22now-1h%22%2C%22to%22%3A%22now%22%7D%7D"
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
    
    # Create check run
    local http_code=$(curl -s -w "\n%{http_code}" -X POST "https://api.github.com/repos/thiagosol/${service}/check-runs" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "{
            \"name\": \"🚀 Container Deployment\",
            \"head_sha\": \"${head_sha}\",
            \"status\": \"in_progress\",
            \"details_url\": \"${grafana_url}\",
            \"output\": {
                \"title\": \"Deploying ${service} to ${environment}\",
                \"summary\": \"**Service:** \`${service}\`\\n**Branch:** \`${branch}\`\\n**Environment:** \`${environment}\`\\n**User:** \`${git_user}\`\\n\\n🔄 Building Docker image and deploying containers...\\n\\n📊 [View live logs in Grafana](${grafana_url})\"
            }
        }" 2>&1)
    
    # Split response and HTTP code
    local response=$(echo "$http_code" | head -n -1)
    local code=$(echo "$http_code" | tail -n 1)
    
    log "🌐 GitHub API Response:"
    log "   HTTP Code: $code"
    
    # Extract check run ID from response
    GITHUB_CHECK_RUN_ID=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    
    if [ "$code" = "201" ] && [ -n "$GITHUB_CHECK_RUN_ID" ]; then
        log "✅ GitHub Check Run created (ID: $GITHUB_CHECK_RUN_ID)"
        return 0
    else
        log "❌ Failed to create GitHub Check Run (non-critical)"
        log "   HTTP Code: $code"
        log "   Full Response:"
        echo "$response" | while IFS= read -r line; do
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
    
    # Update check run with success
    local http_code=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.github.com/repos/thiagosol/${service}/check-runs/${GITHUB_CHECK_RUN_ID}" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "{
            \"status\": \"completed\",
            \"conclusion\": \"success\",
            \"details_url\": \"${grafana_url}\",
            \"output\": {
                \"title\": \"✅ Deployment successful: ${service}/${branch}\",
                \"summary\": \"**Service:** \`${service}\`\\n**Branch:** \`${branch}\`\\n**Environment:** \`${environment}\`\\n**User:** \`${git_user}\`\\n**Duration:** ${deploy_duration}\\n\\n✅ Docker image built successfully\\n✅ Containers updated with zero-downtime\\n✅ Health checks passed\\n\\n📊 [View deployment logs in Grafana](${grafana_url})\"
            }
        }" 2>&1)
    
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
    
    # Update check run with failure
    local http_code=$(curl -s -w "\n%{http_code}" -X PATCH "https://api.github.com/repos/thiagosol/${service}/check-runs/${GITHUB_CHECK_RUN_ID}" \
        -H "Authorization: token ${APP_ID_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/vnd.github+json" \
        -d "{
            \"status\": \"completed\",
            \"conclusion\": \"failure\",
            \"details_url\": \"${grafana_url}\",
            \"output\": {
                \"title\": \"❌ Deployment failed: ${service}/${branch}\",
                \"summary\": \"**Service:** \`${service}\`\\n**Branch:** \`${branch}\`\\n**Environment:** \`${environment}\`\\n**User:** \`${git_user}\`\\n\\n❌ **Error:** ${error_message}\\n\\nThe deployment has been rolled back to the previous version (if available).\\n\\n📊 [View error logs in Grafana](${grafana_url})\\n\\n**Troubleshooting:**\\n- Check Docker build logs\\n- Verify environment variables\\n- Review docker-compose configuration\"
            }
        }" 2>&1)
    
    local code=$(echo "$http_code" | tail -n 1)
    
    if [ "$code" = "200" ]; then
        log "❌ GitHub Check Run completed (failure)"
    else
        log "⚠️ Failed to update GitHub Check Run (HTTP $code)"
    fi
}
