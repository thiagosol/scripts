#!/bin/bash

# GitHub notifications

# Send webhook to GitHub Actions
notify_github() {
    local service="$1"
    local status="$2"
    local message="$3"
    
    if [ -z "$GH_TOKEN" ]; then
        log "ℹ️ GH_TOKEN not available, skipping GitHub notification"
        return 0
    fi
    
    log "🔔 Notifying GitHub Actions: $status"
    
    curl -X POST "https://api.github.com/repos/thiagosol/$service/dispatches" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: token $GH_TOKEN" \
        -d "{\"event_type\": \"deploy_finished\", \"client_payload\": {\"status\": \"$status\", \"message\": \"$message\", \"service\": \"$service\", \"run_id\": \"$GITHUB_RUN_ID\", \"environment\": \"$ENVIRONMENT\"}}" \
        2>/dev/null
    
    if [ $? -eq 0 ]; then
        log "✅ GitHub notification sent"
    else
        log "⚠️ Failed to send GitHub notification (non-critical)"
    fi
}
