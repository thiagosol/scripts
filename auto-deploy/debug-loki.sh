#!/bin/bash

# Debug Loki connection and test sending logs

echo "🔍 Loki Debug Tool"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 1: Check if Loki is accessible
echo "Test 1: Checking Loki endpoint..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOKI_URLS=(
    "http://localhost:3100"
    "http://loki:3100"
    "http://172.23.0.200:3100"
)

for url in "${LOKI_URLS[@]}"; do
    echo -n "Testing $url/ready ... "
    if curl -s -f "$url/ready" >/dev/null 2>&1; then
        echo "✅ ACCESSIBLE"
        WORKING_URL="$url"
    else
        echo "❌ NOT ACCESSIBLE"
    fi
done

echo ""

if [ -z "$WORKING_URL" ]; then
    echo "❌ No Loki endpoint is accessible!"
    echo ""
    echo "Suggestions:"
    echo "  1. Check if Loki container is running:"
    echo "     docker ps | grep loki"
    echo ""
    echo "  2. Check Loki logs:"
    echo "     docker logs loki"
    echo ""
    echo "  3. If Loki is in a container, you may need to use the container name or IP"
    echo "     Update LOKI_URL in lib/logging.sh"
    echo ""
    exit 1
fi

echo "✅ Using working URL: $WORKING_URL"
echo ""

# Test 2: Send a simple log entry
echo "Test 2: Sending test log to Loki..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get current timestamp in nanoseconds
NANO_TS=$(date +%s%N)
echo "Timestamp: $NANO_TS ($(date '+%Y-%m-%d %H:%M:%S'))"

# Create payload
PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "service": "debug-test",
        "type": "debug",
        "branch": "main"
      },
      "values": [
        ["$NANO_TS", "🧪 Debug test message from debug-loki.sh"]
      ]
    }
  ]
}
EOF
)

echo ""
echo "Payload:"
echo "$PAYLOAD"
echo ""

# Send to Loki with verbose output
echo "Sending to $WORKING_URL/loki/api/v1/push ..."
RESPONSE=$(curl -v -X POST "$WORKING_URL/loki/api/v1/push" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1)

echo ""
echo "Response:"
echo "$RESPONSE"
echo ""

if echo "$RESPONSE" | grep -q "HTTP.*204\|HTTP.*200"; then
    echo "✅ Log sent successfully!"
else
    echo "❌ Failed to send log"
    echo ""
    echo "Common issues:"
    echo "  1. Loki is rejecting old samples (check timestamp)"
    echo "  2. Network connectivity issue"
    echo "  3. Loki configuration issue"
fi

echo ""

# Test 3: Query Loki to see if log arrived
echo "Test 3: Querying Loki for the test log..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 2  # Give Loki time to process

QUERY='{service="debug-test"}'
START_TIME=$(($(date +%s) - 300))  # Last 5 minutes
END_TIME=$(date +%s)

echo "Query: $QUERY"
echo "Time range: Last 5 minutes"
echo ""

QUERY_URL="$WORKING_URL/loki/api/v1/query_range?query=$(echo $QUERY | jq -sRr @uri)&start=${START_TIME}000000000&end=${END_TIME}000000000"

echo "Querying: $QUERY_URL"
echo ""

RESULT=$(curl -s "$QUERY_URL")

if echo "$RESULT" | grep -q "Debug test message"; then
    echo "✅ Log found in Loki!"
    echo ""
    echo "Result:"
    echo "$RESULT" | jq '.'
else
    echo "❌ Log NOT found in Loki"
    echo ""
    echo "Raw response:"
    echo "$RESULT" | jq '.'
    echo ""
    echo "This could mean:"
    echo "  1. Loki rejected the timestamp (too old or too new)"
    echo "  2. Loki ingestion delay (wait a bit longer)"
    echo "  3. Loki configuration issue"
fi

echo ""

# Test 4: Check Loki logs
echo "Test 4: Checking Loki container logs..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if docker ps | grep -q loki; then
    echo "Last 20 lines of Loki logs:"
    echo ""
    docker logs loki --tail 20
else
    echo "⚠️ Loki container not found"
    echo ""
    echo "Check if Loki is running:"
    echo "  docker ps -a | grep loki"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Debug completed!"
echo ""
echo "If logs are not appearing in Grafana:"
echo "  1. Use the working URL: $WORKING_URL"
echo "  2. Update LOKI_URL in lib/logging.sh"
echo "  3. Check timestamp (should be current time, not future)"
echo "  4. Check Loki logs for errors"
echo ""
