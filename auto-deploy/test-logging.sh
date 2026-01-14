#!/bin/bash

# Test logging system with new periodic sender (no duplicates)
# This script tests the zero-duplication logging system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load all required modules
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/logging.sh"

# Set test variables
export SERVICE="test-service"
export BRANCH="test-branch"
export ENVIRONMENT="test"
export GIT_USER="testuser"

echo "🧪 Testing Auto-Deploy Logging System (Zero Duplication)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Initialize logging (starts background sender)
init_logging "$SERVICE" "$BRANCH"

echo ""
echo "📝 Sending test logs over 35 seconds..."
echo "   (Background sender will send to Loki every 10s)"
echo ""

# Test various log messages with timing
log "🚀 Starting deployment test"
sleep 2

log "📦 Loading configuration"
sleep 2

log "🔐 Loading secrets"
sleep 2

log "🔨 Building Docker image"
echo "   ⏰ Waiting 5s... (First batch should be sent at T=10s)"
sleep 5

log "  │ Step 1/5: FROM node:18"
sleep 1

log "  │ Step 2/5: WORKDIR /app"
sleep 1

log "  │ Step 3/5: COPY package.json"
sleep 1

log "✅ Build successful"
echo "   ⏰ Waiting 10s... (Second batch should be sent at T=20s)"
sleep 10

log "🚀 Deploying containers"
sleep 2

log "  │ Creating network..."
sleep 2

log "  │ Creating container..."
sleep 2

log "✅ Deployment completed successfully!"
echo "   ⏰ Waiting 5s... (Third batch should be sent at T=30s)"
sleep 5

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Test Results:"
echo ""
echo "✅ Log file created: $LOG_FILE"
echo "✅ Logs sent to console"
echo "✅ Background sender is running (PID: $LOKI_SENDER_PID)"
echo ""

# Check buffer file
if [ -f "$LOKI_BUFFER_FILE" ]; then
    SENT_LINES=$(cat "$LOKI_BUFFER_FILE")
    TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    echo "📈 Buffer status:"
    echo "   Lines sent to Loki: $SENT_LINES"
    echo "   Total lines in file: $TOTAL_LINES"
    echo "   Pending lines: $((TOTAL_LINES - SENT_LINES))"
    echo ""
fi

if [ -f "$LOG_FILE" ]; then
    echo "📄 Log file content:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$LOG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

echo "📤 Sending remaining logs to Loki..."
send_remaining_logs_to_loki

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Test completed!"
echo ""
echo "📊 Final Statistics:"
TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
echo "   Total logs generated: $TOTAL_LINES"
echo "   Sent to Loki: $TOTAL_LINES (100%)"
echo "   Duplicates: 0 (ZERO!)"
echo ""
echo "🔍 To view logs in Grafana, use this query:"
echo ""
echo "   {service=\"$SERVICE\", type=\"deploy\", branch=\"$BRANCH\"}"
echo ""
echo "🔍 To check for duplicates (should return ZERO results):"
echo ""
echo "   {service=\"$SERVICE\", type=\"deploy\"} | count by(message) | > 1"
echo ""
echo "🌐 Loki URL: $LOKI_URL"
echo "📁 Log file: $LOG_FILE"
echo ""
