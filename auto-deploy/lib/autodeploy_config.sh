#!/bin/bash

# AutoDeploy configuration (.autodeploy.ini)

AUTODEPLOY_COMPOSE_FILES=()  # Changed to array for multiple files
AUTODEPLOY_IMAGE_NAME=""
AUTODEPLOY_PROJECT_NAME=""   # Custom project name
AUTODEPLOY_COPY_LIST=()
AUTODEPLOY_RENDER_LIST=()
AUTODEPLOY_EXTERNAL_REPOS=()  # External repositories to clone and build before main build

# Read .autodeploy.ini configuration file
read_autodeploy_ini() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    
    log "⚙️ Loading AutoDeploy config: $cfg"
    
    # Create a temporary rendered version of the config file
    local rendered_cfg="${cfg}.rendered"
    
    # Render environment variables in the config file
    if command -v perl &> /dev/null; then
        log "🧩 Rendering variables in .autodeploy.ini..."
        perl -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$cfg" > "$rendered_cfg"
    else
        # Fallback: use envsubst if available, otherwise just copy
        if command -v envsubst &> /dev/null; then
            envsubst < "$cfg" > "$rendered_cfg"
        else
            cp "$cfg" "$rendered_cfg"
            log "⚠️ perl and envsubst not found, using raw config"
        fi
    fi
    
    local section=""
    
    while IFS= read -r raw || [ -n "$raw" ]; do
        # remove comments ; or #
        local line="${raw%%#*}"
        line="${line%%;*}"
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        case "$section" in
            settings)
                if [[ "$line" == compose_file=* ]]; then
                    # Single file (backward compatibility)
                    local file="${line#compose_file=}"
                    file="$(trim "$file")"
                    AUTODEPLOY_COMPOSE_FILES+=("$file")
                    log "📄 Compose file configured: $file"
                elif [[ "$line" == compose_files=* ]]; then
                    # Multiple files (comma-separated or multiple lines)
                    local files="${line#compose_files=}"
                    files="$(trim "$files")"
                    # Split by comma
                    IFS=',' read -ra file_array <<< "$files"
                    for f in "${file_array[@]}"; do
                        f="$(trim "$f")"
                        [ -n "$f" ] && AUTODEPLOY_COMPOSE_FILES+=("$f")
                        log "📄 Compose file configured: $f"
                    done
                elif [[ "$line" == project_name=* ]]; then
                    AUTODEPLOY_PROJECT_NAME="${line#project_name=}"
                    AUTODEPLOY_PROJECT_NAME="$(trim "$AUTODEPLOY_PROJECT_NAME")"
                    log "🏷️ Project name configured: $AUTODEPLOY_PROJECT_NAME"
                elif [[ "$line" == image_name=* ]]; then
                    AUTODEPLOY_IMAGE_NAME="${line#image_name=}"
                    AUTODEPLOY_IMAGE_NAME="$(trim "$AUTODEPLOY_IMAGE_NAME")"
                    log "🐳 Image name configured: $AUTODEPLOY_IMAGE_NAME"
                elif [[ "$line" == external_repo=* ]]; then
                    # Single external repository (format: user/repo or user/repo:branch)
                    local repo="${line#external_repo=}"
                    repo="$(trim "$repo")"
                    AUTODEPLOY_EXTERNAL_REPOS+=("$repo")
                    log "📦 External repository configured: $repo"
                elif [[ "$line" == external_repos=* ]]; then
                    # Multiple external repositories (comma-separated, format: user/repo or user/repo:branch)
                    local repos="${line#external_repos=}"
                    repos="$(trim "$repos")"
                    # Split by comma
                    IFS=',' read -ra repo_array <<< "$repos"
                    for repo in "${repo_array[@]}"; do
                        repo="$(trim "$repo")"
                        [ -n "$repo" ] && AUTODEPLOY_EXTERNAL_REPOS+=("$repo")
                        log "📦 External repository configured: $repo"
                    done
                fi
                ;;
            external_repos)
                # Section for external repositories (one per line, format: user/repo or user/repo:branch)
                local repo="$(trim "$line")"
                [ -n "$repo" ] && AUTODEPLOY_EXTERNAL_REPOS+=("$repo")
                log "📦 External repository configured: $repo"
                ;;
            copy)
                AUTODEPLOY_COPY_LIST+=("$line")
                ;;
            render)
                AUTODEPLOY_RENDER_LIST+=("$line")
                ;;
            *)
                # ignore unknown sections
                ;;
        esac
    done < "$rendered_cfg"
    
    # Clean up temporary file
    rm -f "$rendered_cfg"
    
    # Summary log
    if [ ${#AUTODEPLOY_COMPOSE_FILES[@]} -gt 0 ]; then
        log "📦 Compose files to deploy: ${#AUTODEPLOY_COMPOSE_FILES[@]}"
    fi
    
    if [ -n "$AUTODEPLOY_PROJECT_NAME" ]; then
        log "📦 Using custom project name: $AUTODEPLOY_PROJECT_NAME"
    else
        log "📦 Using default project name: ${SERVICE}-${ENVIRONMENT}"
    fi
    
    if [ -n "$AUTODEPLOY_IMAGE_NAME" ]; then
        log "📦 Using custom image name: $AUTODEPLOY_IMAGE_NAME"
    else
        log "📦 Using default image name: $SERVICE"
    fi
    
    if [ ${#AUTODEPLOY_EXTERNAL_REPOS[@]} -gt 0 ]; then
        log "📦 External repositories to clone: ${#AUTODEPLOY_EXTERNAL_REPOS[@]}"
    fi
}

# Copy extra paths configured in [copy] section
copy_extra_paths() {
    local src_root="$1"
    local dst_root="$2"
    
    [ "${#AUTODEPLOY_COPY_LIST[@]}" -eq 0 ] && return 0
    log "📦 Copying extra paths (from [copy]) to base dir..."
    
    for rel in "${AUTODEPLOY_COPY_LIST[@]}"; do
        local src="$src_root/$rel"
        local dst="$dst_root/$rel"
        
        if [ -e "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            # cp -a preserva estrutura/perms
            cp -a "$src" "$dst" 2>/dev/null || cp -a "$src" "$(dirname "$dst")/"
            log "✅ Copied: $rel"
        else
            log "⚠️ Not found to copy: $rel"
        fi
    done
}

# Render files with environment variable substitution
render_files_list() {
    local base_dir="$1"
    [ "${#AUTODEPLOY_RENDER_LIST[@]}" -eq 0 ] && return 0
    
    log "🧩 Rendering placeholders in files from [render]..."
    
    for rel in "${AUTODEPLOY_RENDER_LIST[@]}"; do
        local f="$base_dir/$rel"
        if [ ! -f "$f" ]; then
            log "⚠️ Render target not found (skipping): $rel"
            continue
        fi
        
        if ! grep -Iq . "$f"; then
            log "⚠️ Non-text file (skipping): $rel"
            continue
        fi
        
        # Replace ${VAR} only if VAR exists in ENV; else keep ${VAR}
        perl -i -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$f"
        log "✅ Rendered: $rel"
    done
}
