#!/bin/bash

#==============================================================================
# Auto-Deploy Script v2.0
# 
# Automated deployment script with modular architecture
#
# Usage:
#   ./deploy.sh <service-name> <git-user> <branch> [OPTION=value...]
#
# Required Parameters:
#   service-name    Name of the service to deploy
#   git-user        GitHub username/organization
#   branch          Git branch to deploy
#
# Optional Parameters:
#   ENVIRONMENT=<env>    Override environment (prod, dev, staging)
#
# Examples:
#   ./deploy.sh my-service thiagosol main
#   ./deploy.sh my-service thiagosol dev ENVIRONMENT=staging
#==============================================================================

set -o pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load all library modules
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/git.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/compose.sh"
source "$SCRIPT_DIR/lib/volumes.sh"
source "$SCRIPT_DIR/lib/autodeploy_config.sh"
source "$SCRIPT_DIR/lib/notifications.sh"

#==============================================================================
# Main deployment flow
#==============================================================================

main() {
    # Parse command line arguments FIRST (before logging)
    if ! parse_arguments "$@"; then
        exit 1
    fi
    
    # Initialize deployment configuration
    init_deployment_config "$SERVICE" "$GIT_USER" "$BRANCH"
    
    # Initialize logging system EARLY (so all logs have timestamps)
    init_logging "$SERVICE" "$BRANCH"
    
    log "🚀 Starting Auto-Deploy v2.0"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Record start time for duration calculation
    DEPLOY_START=$(date +%s)
    
    # Create GitHub Check Run (if APP_ID_TOKEN provided)
    create_github_check "$SERVICE" "$HEAD_SHA" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" || true
    
    # Setup lock trap for cleanup
    setup_lock_trap
    
    # Acquire deployment lock
    if ! acquire_lock "$SERVICE"; then
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Another deployment is already in progress" || true
        exit 2
    fi
    
    # Load secrets from GitHub repository
    if ! load_secrets "$SERVICE"; then
        log "❌ ERROR: Failed to load secrets"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Failed to load secrets from GitHub repository" || true
        exit 1
    fi
    
    # Prepare temporary directory
    prepare_temp_directory "$TEMP_DIR"
    
    # Clone repository
    if ! clone_repository "$SERVICE" "$GIT_REPO" "$BRANCH" "$TEMP_DIR"; then
        log "❌ Deploy failed: Git clone failed"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Git clone failed for branch ${BRANCH}" || true
        exit 1
    fi
    
    # Apply service-specific secrets (must be after clone)
    apply_service_secrets "$TEMP_DIR"
    
    # Read autodeploy configuration
    read_autodeploy_ini "$TEMP_DIR/.autodeploy.ini"
    
    # Check if this is a Docker-based deployment
    if [ ! -f "$TEMP_DIR/Dockerfile" ] && [ -z "$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'docker-compose*.yml' -print -quit)" ]; then
        log "⚠️ No Dockerfile or docker-compose.yml found. Copying files and finishing deployment."
        cp -r "$TEMP_DIR/"* "$BASE_DIR/"
        find "$BASE_DIR" -type f -name "*.sh" -exec chmod +x {} \;
        rm -rf "$TEMP_DIR"
        log "✅ Deployment completed without Docker!"
        exit 0
    fi
    
    # Build Docker image
    if ! build_docker_image "$SERVICE" "$TEMP_DIR"; then
        log "❌ Deploy failed: Docker build failed"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Docker image build failed" || true
        exit 1
    fi
    
    # Backup current image before replacing
    backup_docker_image "$SERVICE"
    
    # Tag new image
    if ! tag_docker_image "$SERVICE"; then
        log "❌ Deploy failed: Failed to tag image"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Failed to tag Docker image" || true
        exit 1
    fi
    
    # Prepare compose file
    if ! prepare_compose_file "$TEMP_DIR" "$BASE_DIR" "$AUTODEPLOY_COMPOSE_FILE"; then
        log "❌ Deploy failed: No docker-compose file found"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "docker-compose.yml not found in repository" || true
        exit 1
    fi
    COMPOSE_BASENAME="$COMPOSE_FILE_BASENAME"
    
    # Process volumes
    process_volumes "$TEMP_DIR" "$BASE_DIR" "$COMPOSE_BASENAME"
    
    # Copy extra configured paths
    copy_extra_paths "$TEMP_DIR" "$BASE_DIR"
    
    # Copy secrets directory if exists
    copy_secrets_directory "$TEMP_DIR" "$BASE_DIR"
    
    # Render files with environment variables
    render_files_list "$BASE_DIR"
    
    # Clean up temporary directory
    log "🛠️ Cleaning temporary directories..."
    rm -rf "$TEMP_DIR"
    
    # Deploy with Docker Compose (zero-downtime)
    if ! deploy_with_compose "$SERVICE" "$BASE_DIR" "$COMPOSE_BASENAME"; then
        # Rollback on failure
        if rollback_docker_image "$SERVICE"; then
            rollback_with_compose "$SERVICE" "$BASE_DIR" "$COMPOSE_BASENAME"
        fi
        log "❌ Deploy failed: Docker Compose failed to start - rollback attempted"
        complete_github_check_failure "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "Docker Compose failed to start containers (rollback attempted)" || true
        exit 1
    fi
    
    # Clean up old images
    cleanup_docker_images "$SERVICE"
    
    # Calculate deployment duration
    DEPLOY_END=$(date +%s)
    DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))
    DEPLOY_DURATION_STR="${DEPLOY_DURATION}s"
    if [ $DEPLOY_DURATION -ge 60 ]; then
        DEPLOY_DURATION_STR="$((DEPLOY_DURATION / 60))m $((DEPLOY_DURATION % 60))s"
    fi
    
    # Success!
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Deployment completed successfully!"
    log "📦 Service: $SERVICE"
    log "🌍 Environment: $ENVIRONMENT"
    log "🌿 Branch: $BRANCH"
    log "👤 Git User: $GIT_USER"
    log "⏱️ Duration: $DEPLOY_DURATION_STR"
    
    # Update GitHub Check Run (success)
    complete_github_check_success "$SERVICE" "$ENVIRONMENT" "$BRANCH" "$GIT_USER" "$DEPLOY_DURATION_STR" || true
    
    # Send any remaining logs to Loki
    send_remaining_logs_to_loki
    
    # Cleanup old logs
    cleanup_old_logs
    
    exit 0
}

# Run main function
main "$@"
