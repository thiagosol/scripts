#!/bin/bash

# Logging with Loki integration

# Loki configuration
LOKI_URL="${LOKI_URL:-http://localhost:3100/loki/api/v1/push}"
LOG_DIR="/opt/auto-deploy/logs"
LOG_FILE=""
DEPLOY_START_TIME=""
LOKI_BUFFER_FILE=""
LAST_SENT_LINE=0
LOKI_SENDER_PID=""

# Initialize logging for deployment
init_logging() {
    local service="$1"
    local branch="$2"
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Generate unique log file name with timestamp
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    LOG_FILE="$LOG_DIR/${service}_${branch}_${timestamp}.log"
    LOKI_BUFFER_FILE="/tmp/loki-buffer-$$.txt"
    
    # Record start time in nanoseconds
    DEPLOY_START_TIME=$(date +%s%N)
    
    # Initialize sent line counter
    LAST_SENT_LINE=0
    echo "0" > "$LOKI_BUFFER_FILE"
    
    log "📝 Logging to: $LOG_FILE"
    log "📡 Loki endpoint: $LOKI_URL"
    
    # Start periodic Loki sender in background
    start_loki_sender &
    LOKI_SENDER_PID=$!
}

# Enhanced log function that sends to both console and file
# Loki sending is handled by periodic background process
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="$timestamp - $message"
    
    # Console output (always)
    echo "$log_line"
    
    # File output (if log file is set)
    if [ -n "$LOG_FILE" ]; then
        echo "$log_line" >> "$LOG_FILE"
    fi
    
    # Loki sending is handled by periodic background process (every 10s)
    # This avoids duplicates and reduces API calls
}

# Execute command and capture output to logging system
# Usage: run_logged_command "description" command args...
run_logged_command() {
    local description="$1"
    shift
    local cmd="$@"
    
    log "▶️ Executing: $description"
    log "   Command: $cmd"
    
    # Create temporary files for stdout and stderr
    local tmp_stdout=$(mktemp)
    local tmp_stderr=$(mktemp)
    local exit_code=0
    
    # Execute command and capture output
    if eval "$cmd" > "$tmp_stdout" 2> "$tmp_stderr"; then
        exit_code=0
    else
        exit_code=$?
    fi
    
    # Log stdout (if any)
    if [ -s "$tmp_stdout" ]; then
        while IFS= read -r line; do
            log "  │ $line"
        done < "$tmp_stdout"
    fi
    
    # Log stderr (if any)
    if [ -s "$tmp_stderr" ]; then
        while IFS= read -r line; do
            log "  ⚠ $line"
        done < "$tmp_stderr"
    fi
    
    # Clean up
    rm -f "$tmp_stdout" "$tmp_stderr"
    
    # Log result
    if [ $exit_code -eq 0 ]; then
        log "✅ Command completed successfully"
    else
        log "❌ Command failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

# Execute command with real-time logging (for long-running commands)
# Usage: run_command_realtime "description" command args...
run_command_realtime() {
    local description="$1"
    shift
    local cmd="$@"
    
    log "▶️ Executing: $description"
    
    # Execute command and pipe output through logging
    eval "$cmd" 2>&1 | while IFS= read -r line; do
        log "  │ $line"
    done
    
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ]; then
        log "✅ Command completed successfully"
    else
        log "❌ Command failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

# Periodic Loki sender (runs in background every 10s)
start_loki_sender() {
    while true; do
        sleep 10
        send_new_logs_to_loki
    done
}

# Send only new (unsent) logs to Loki
send_new_logs_to_loki() {
    [ -z "$LOG_FILE" ] && return 0
    [ ! -f "$LOG_FILE" ] && return 0
    [ -z "$SERVICE" ] && return 0
    
    # Read last sent line number
    local last_sent=0
    if [ -f "$LOKI_BUFFER_FILE" ]; then
        last_sent=$(cat "$LOKI_BUFFER_FILE" 2>/dev/null || echo "0")
    fi
    
    # Count total lines in log file
    local total_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    
    # No new lines to send
    [ "$total_lines" -le "$last_sent" ] && return 0
    
    # Calculate how many new lines we have
    local new_lines=$((total_lines - last_sent))
    
    # Read only new lines (skip already sent lines)
    local labels="{service=\"${SERVICE}\",type=\"deploy\",branch=\"${BRANCH}\",environment=\"${ENVIRONMENT:-unknown}\",git_user=\"${GIT_USER:-unknown}\"}"
    local values="["
    local count=0
    local batch_size=100
    local line_num=0
    
    while IFS= read -r line; do
        ((line_num++))
        
        # Skip already sent lines
        [ $line_num -le $last_sent ] && continue
        
        # Extract timestamp and message
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ -\ (.*)$ ]]; then
            local log_timestamp="${BASH_REMATCH[1]}"
            local log_message="${BASH_REMATCH[2]}"
            
            # Convert to nanoseconds
            local nano_ts=$(date -d "$log_timestamp" +%s%N 2>/dev/null || echo "$DEPLOY_START_TIME")
            
            # Escape quotes and backslashes in message
            log_message="${log_message//\\/\\\\}"
            log_message="${log_message//\"/\\\"}"
            
            if [ $count -gt 0 ]; then
                values+=","
            fi
            values+="[\"$nano_ts\",\"$log_message\"]"
            
            ((count++))
            
            # Send batch if size reached
            if [ $count -ge $batch_size ]; then
                values+="]"
                local payload="{\"streams\":[{\"stream\":$labels,\"values\":$values}]}"
                curl -s -X POST "$LOKI_URL" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
                values="["
                count=0
            fi
        fi
    done < "$LOG_FILE"
    
    # Send remaining logs
    if [ $count -gt 0 ]; then
        values+="]"
        local payload="{\"streams\":[{\"stream\":$labels,\"values\":$values}]}"
        curl -s -X POST "$LOKI_URL" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
    fi
    
    # Update last sent line number
    echo "$total_lines" > "$LOKI_BUFFER_FILE"
}

# Send any remaining logs to Loki (called at the end of deploy)
send_remaining_logs_to_loki() {
    # Stop the periodic sender
    if [ -n "$LOKI_SENDER_PID" ]; then
        kill "$LOKI_SENDER_PID" 2>/dev/null || true
    fi
    
    # Send any remaining logs that weren't sent yet
    send_new_logs_to_loki
    
    # Clean up buffer file
    rm -f "$LOKI_BUFFER_FILE" 2>/dev/null || true
}

# Cleanup old log files (keep last 30 days)
cleanup_old_logs() {
    if [ -d "$LOG_DIR" ]; then
        find "$LOG_DIR" -name "*.log" -type f -mtime +30 -delete 2>/dev/null || true
        log "🧹 Old log files cleaned up (>30 days)"
    fi
}
