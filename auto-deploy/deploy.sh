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
    log "🚀 Starting Auto-Deploy v2.0"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Parse command line arguments
    if ! parse_arguments "$@"; then
        exit 1
    fi
    
    # Initialize deployment configuration
    init_deployment_config "$SERVICE" "$GIT_USER" "$BRANCH"
    
    # Initialize logging system
    init_logging "$SERVICE" "$BRANCH"
    
    # Setup lock trap for cleanup
    setup_lock_trap
    
    # Acquire deployment lock
    if ! acquire_lock "$SERVICE"; then
        exit 2
    fi
    
    # Load secrets from GitHub repository
    if ! load_secrets "$SERVICE"; then
        log "❌ ERROR: Failed to load secrets"
        notify_github "$SERVICE" "failure" "Failed to load secrets from repository"
        exit 1
    fi
    
    # Prepare temporary directory
    prepare_temp_directory "$TEMP_DIR"
    
    # Clone repository
    if ! clone_repository "$SERVICE" "$GIT_REPO" "$BRANCH" "$TEMP_DIR"; then
        notify_github "$SERVICE" "failure" "Git clone failed"
        exit 1
    fi
    
    # Read autodeploy configuration
    read_autodeploy_ini "$TEMP_DIR/.autodeploy.ini"
    
    # Check if this is a Docker-based deployment
    if [ ! -f "$TEMP_DIR/Dockerfile" ] && [ -z "$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'docker-compose*.yml' -print -quit)" ]; then
        log "⚠️ No Dockerfile or docker-compose.yml found. Copying files and finishing deployment."
        cp -r "$TEMP_DIR/"* "$BASE_DIR/"
        find "$BASE_DIR" -type f -name "*.sh" -exec chmod +x {} \;
        rm -rf "$TEMP_DIR"
        log "✅ Deployment completed without Docker!"
        notify_github "$SERVICE" "success" "Deployment completed without Docker"
        exit 0
    fi
    
    # Build Docker image
    if ! build_docker_image "$SERVICE" "$TEMP_DIR"; then
        notify_github "$SERVICE" "failure" "Docker build failed"
        exit 1
    fi
    
    # Backup current image before replacing
    backup_docker_image "$SERVICE"
    
    # Tag new image
    if ! tag_docker_image "$SERVICE"; then
        notify_github "$SERVICE" "failure" "Failed to tag image"
        exit 1
    fi
    
    # Prepare compose file
    COMPOSE_BASENAME=$(prepare_compose_file "$TEMP_DIR" "$BASE_DIR" "$AUTODEPLOY_COMPOSE_FILE")
    if [ -z "$COMPOSE_BASENAME" ]; then
        notify_github "$SERVICE" "failure" "No docker-compose file found"
        exit 1
    fi
    
    # Process volumes
    process_volumes "$TEMP_DIR" "$BASE_DIR" "$COMPOSE_BASENAME"
    
    # Copy extra configured paths
    copy_extra_paths "$TEMP_DIR" "$BASE_DIR"
    
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
        notify_github "$SERVICE" "failure" "Docker Compose failed to start - rollback attempted"
        exit 1
    fi
    
    # Clean up old images
    cleanup_docker_images "$SERVICE"
    
    # Success!
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Deployment completed successfully!"
    log "📦 Service: $SERVICE"
    log "🌍 Environment: $ENVIRONMENT"
    log "🌿 Branch: $BRANCH"
    log "👤 Git User: $GIT_USER"
    
    # Send any remaining logs to Loki
    send_remaining_logs_to_loki
    
    # Cleanup old logs
    cleanup_old_logs
    
    # Notify GitHub
    notify_github "$SERVICE" "success" "Deployment completed successfully in $ENVIRONMENT"
    
    exit 0
}

# Run main function
main "$@"
