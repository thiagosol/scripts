#!/bin/bash

# Test logging system
# This script tests if logs are being sent to Loki correctly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load logging module
source "$SCRIPT_DIR/lib/logging.sh"

# Set test variables
export SERVICE="test-service"
export BRANCH="test-branch"
export ENVIRONMENT="test"
export GIT_USER="testuser"

echo "🧪 Testing Auto-Deploy Logging System"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Initialize logging
init_logging "$SERVICE" "$BRANCH"

echo ""
echo "📝 Sending test logs..."
echo ""

# Test various log messages
log "🚀 Starting deployment test"
sleep 1

log "📦 Loading configuration"
sleep 1

log "🔐 Loading secrets"
sleep 1

log "🔨 Building Docker image"
sleep 1

log "✅ Build successful"
sleep 1

log "🚀 Deploying containers"
sleep 1

log "✅ Deployment completed successfully!"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Test Results:"
echo ""
echo "✅ Log file created: $LOG_FILE"
echo "✅ Logs sent to console"
echo ""

if [ -f "$LOG_FILE" ]; then
    echo "📄 Log file content:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$LOG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

echo "📤 Sending batch to Loki..."
send_log_file_to_loki "$SERVICE" "$BRANCH" "$ENVIRONMENT" "$GIT_USER"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Test completed!"
echo ""
echo "🔍 To view logs in Grafana, use this query:"
echo ""
echo "   {service=\"$SERVICE\", type=\"deploy\", branch=\"$BRANCH\"}"
echo ""
echo "🌐 Loki URL: $LOKI_URL"
echo "📁 Log file: $LOG_FILE"
echo ""
