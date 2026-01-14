#!/bin/bash

# Utility functions
# Note: log() function is defined in logging.sh

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    echo "$s"
}

# Determine environment based on branch
get_environment_from_branch() {
    local branch="$1"
    case "$branch" in
        main|master)
            echo "prod"
            ;;
        dev|develop|development)
            echo "dev"
            ;;
        staging|stage)
            echo "staging"
            ;;
        *)
            echo "dev"  # default
            ;;
    esac
}
