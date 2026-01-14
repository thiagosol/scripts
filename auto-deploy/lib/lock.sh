#!/bin/bash

# Deployment lock management

# Acquire deployment lock
acquire_lock() {
    local service="$1"
    local lock_file="$LOCK_FILE"
    
    # Check for existing lock (another deploy in progress)
    if [ -f "$lock_file" ]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        local lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null)
        local current_time=$(date +%s)
        local lock_age=$((current_time - lock_time))
        
        # Check if the process is still running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "🔒 DEPLOY BLOCKED: Another deployment for '$service' is already in progress (PID: $lock_pid)"
            log "⏳ Please wait for the current deployment to finish."
            return 2
        elif [ $lock_age -lt 3600 ]; then
            # Lock exists but process is dead, and lock is less than 1 hour old
            log "⚠️ Found stale lock file from $(date -d @$lock_time 2>/dev/null || date -r $lock_time 2>/dev/null)"
            log "🔓 Removing stale lock and proceeding..."
            rm -f "$lock_file"
        else
            # Lock is very old (> 1 hour), definitely stale
            log "⚠️ Found very old lock file, removing..."
            rm -f "$lock_file"
        fi
    fi
    
    # Create lock file with current PID
    echo $$ > "$lock_file"
    log "🔒 Deployment lock acquired for '$service' (PID: $$)"
    
    return 0
}

# Release deployment lock
release_lock() {
    # Stop Loki sender if running
    if [ -n "$LOKI_SENDER_PID" ]; then
        kill "$LOKI_SENDER_PID" 2>/dev/null || true
    fi
    
    # Send any remaining logs before exiting
    if type send_remaining_logs_to_loki &>/dev/null; then
        send_remaining_logs_to_loki 2>/dev/null || true
    fi
    
    # Release lock
    if [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
        log "🔓 Releasing deployment lock..."
        rm -f "$LOCK_FILE"
    fi
}

# Setup trap to always release lock on exit
setup_lock_trap() {
    trap release_lock EXIT INT TERM
}
