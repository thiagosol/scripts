#!/bin/bash

# Configuration and parameter parsing

# Parse command line arguments
# Usage: parse_arguments "$@"
parse_arguments() {
    # Required positional parameter
    SERVICE="$1"
    
    # Shift to process optional parameters
    shift 1
    
    # Default values
    GIT_USER="thiagosol"
    BRANCH="main"
    
    # Optional key=value parameters
    declare -g -A DEPLOY_OPTIONS
    
    for arg in "$@"; do
        if [[ "$arg" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            DEPLOY_OPTIONS["$key"]="$value"
            log "📋 Optional parameter: $key=$value"
        else
            log "⚠️ Invalid optional parameter format: $arg (expected KEY=VALUE)"
        fi
    done
    
    # Override defaults with optional parameters
    if [ -n "${DEPLOY_OPTIONS[GIT_USER]}" ]; then
        GIT_USER="${DEPLOY_OPTIONS[GIT_USER]}"
    fi
    
    if [ -n "${DEPLOY_OPTIONS[BRANCH]}" ]; then
        BRANCH="${DEPLOY_OPTIONS[BRANCH]}"
    fi
    
    # GitHub Check Runs parameters (optional)
    if [ -n "${DEPLOY_OPTIONS[APP_ID_TOKEN]}" ]; then
        APP_ID_TOKEN="${DEPLOY_OPTIONS[APP_ID_TOKEN]}"
        export APP_ID_TOKEN
    fi
    
    if [ -n "${DEPLOY_OPTIONS[COMMIT_AFTER]}" ]; then
        HEAD_SHA="${DEPLOY_OPTIONS[COMMIT_AFTER]}"
        export HEAD_SHA
    fi
    
    # Validate required parameters
    if [ -z "$SERVICE" ]; then
        log "❌ ERROR: Missing required parameter!"
        log "Usage: $0 <service-name> [OPTION=value...]"
        log ""
        log "Required parameters:"
        log "  service-name    Name of the service to deploy"
        log ""
        log "Optional parameters:"
        log "  GIT_USER=<user>      GitHub username/organization (default: thiagosol)"
        log "  BRANCH=<branch>      Git branch to deploy (default: main)"
        log "  ENVIRONMENT=<env>    Deployment environment (prod, dev, staging)"
        log "                       If not provided, determined from branch:"
        log "                         main/master → prod"
        log "                         dev/develop → dev"
        log "                         staging     → staging"
        log "  APP_ID_TOKEN=<token> GitHub token for Check Runs API (optional)"
        log "  COMMIT_AFTER=<sha>       Git commit SHA for Check Runs (optional)"
        log ""
        log "Examples:"
        log "  $0 my-service"
        log "  $0 my-service BRANCH=dev"
        log "  $0 my-service GIT_USER=otheruser BRANCH=main"
        log "  $0 my-service BRANCH=dev ENVIRONMENT=staging"
        log ""
        log "Secrets will be loaded automatically from thiagosol/secrets repository"
        return 1
    fi
    
    # Determine environment
    if [ -n "${DEPLOY_OPTIONS[ENVIRONMENT]}" ]; then
        ENVIRONMENT="${DEPLOY_OPTIONS[ENVIRONMENT]}"
        log "🌍 Using provided environment: $ENVIRONMENT"
    else
        ENVIRONMENT=$(get_environment_from_branch "$BRANCH")
        log "🌍 Environment determined from branch '$BRANCH': $ENVIRONMENT"
    fi
    
    # Export global variables
    export SERVICE
    export GIT_USER
    export BRANCH
    export ENVIRONMENT
    
    return 0
}

# Initialize deployment paths and variables
init_deployment_config() {
    local service="$1"
    local git_user="$2"
    local branch="$3"
    
    export BASE_DIR="/opt/auto-deploy/$service/$ENVIRONMENT"
    export TEMP_DIR="$BASE_DIR/temp"
    export LOCK_FILE="$BASE_DIR/.deploy.lock"
    export GIT_REPO="git@github.com:$git_user/$service.git"
    export GIT_SSH_COMMAND="ssh -i /opt/auto-deploy/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    
    # Create base directory if it doesn't exist
    mkdir -p "$BASE_DIR"
    
    log "📁 Base directory: $BASE_DIR"
    log "🔧 Service: $service | User: $git_user | Branch: $branch | Env: $ENVIRONMENT"
}
