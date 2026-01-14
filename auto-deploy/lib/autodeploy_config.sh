#!/bin/bash

# AutoDeploy configuration (.autodeploy.ini)

AUTODEPLOY_COMPOSE_FILE=""
AUTODEPLOY_COPY_LIST=()
AUTODEPLOY_RENDER_LIST=()

# Read .autodeploy.ini configuration file
read_autodeploy_ini() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    
    log "⚙️ Loading AutoDeploy config: $cfg"
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
                    AUTODEPLOY_COMPOSE_FILE="${line#compose_file=}"
                    AUTODEPLOY_COMPOSE_FILE="$(trim "$AUTODEPLOY_COMPOSE_FILE")"
                fi
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
    done < "$cfg"
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
