#!/bin/bash

# Teste simples e direto - SEM sender em background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Variáveis
export SERVICE="test-service"
export BRANCH="test-branch"
export ENVIRONMENT="test"
export GIT_USER="testuser"

# URL do Loki (VERIFICAR!)
LOKI_URL="${LOKI_URL:-http://loki:3100/loki/api/v1/push}"

echo "🧪 Teste Direto de Logging (SEM background sender)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Configuração:"
echo "  SERVICE: $SERVICE"
echo "  BRANCH: $BRANCH"
echo "  ENVIRONMENT: $ENVIRONMENT"
echo "  LOKI_URL: $LOKI_URL"
echo ""

# Criar arquivo de log
LOG_DIR="/opt/auto-deploy/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${SERVICE}_${BRANCH}_$(date +%Y%m%d_%H%M%S).log"

echo "📝 Log file: $LOG_FILE"
echo ""

# Função de log simples
log_to_file() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $msg" | tee -a "$LOG_FILE"
}

# Gerar alguns logs
log_to_file "🚀 Test 1: Starting"
log_to_file "📦 Test 2: Loading"
log_to_file "🔨 Test 3: Building"
log_to_file "✅ Test 4: Complete"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 Enviando logs para Loki..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Preparar labels
LABELS=$(cat <<EOF
{
  "service": "$SERVICE",
  "type": "deploy",
  "branch": "$BRANCH",
  "environment": "$ENVIRONMENT",
  "git_user": "$GIT_USER"
}
EOF
)

echo "Labels:"
echo "$LABELS" | jq '.'
echo ""

# Ler logs e criar payload
VALUES="["
count=0

while IFS= read -r line; do
    # Extrair timestamp e mensagem
    if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ -\ (.*)$ ]]; then
        log_ts="${BASH_REMATCH[1]}"
        log_msg="${BASH_REMATCH[2]}"
        
        # Converter para nanosegundos
        nano_ts=$(date -d "$log_ts" +%s%N 2>/dev/null || date +%s%N)
        
        # Escapar mensagem
        log_msg="${log_msg//\\/\\\\}"
        log_msg="${log_msg//\"/\\\"}"
        
        if [ $count -gt 0 ]; then
            VALUES+=","
        fi
        VALUES+="[\"$nano_ts\",\"$log_msg\"]"
        
        ((count++))
    fi
done < "$LOG_FILE"

VALUES+="]"

echo "Logs a enviar: $count"
echo ""

# Criar payload completo
PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": $LABELS,
      "values": $VALUES
    }
  ]
}
EOF
)

echo "Payload (primeiros 500 chars):"
echo "$PAYLOAD" | head -c 500
echo ""
echo "..."
echo ""

# Enviar para Loki (COM verbose)
echo "Enviando para: $LOKI_URL"
echo ""

HTTP_CODE=$(curl -v -w "%{http_code}" -o /tmp/loki-test-response.txt \
    -X POST "$LOKI_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1 | tee /tmp/loki-test-verbose.txt | tail -1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Resultado:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "HTTP Code: $HTTP_CODE"
echo ""

if [ "$HTTP_CODE" == "204" ] || [ "$HTTP_CODE" == "200" ]; then
    echo "✅ Logs enviados com SUCESSO!"
else
    echo "❌ FALHA ao enviar logs!"
    echo ""
    echo "Response:"
    cat /tmp/loki-test-response.txt
    echo ""
    echo "Verbose output:"
    cat /tmp/loki-test-verbose.txt
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Verificando no Loki..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sleep 2  # Aguardar processamento

LOKI_QUERY_URL="${LOKI_URL%/loki/api/v1/push}"
QUERY="{service=\"$SERVICE\"}"
START_TIME=$(($(date +%s) - 300))
END_TIME=$(date +%s)

echo "Query: $QUERY"
echo "Time range: Last 5 minutes"
echo ""

QUERY_RESULT=$(curl -s -G "$LOKI_QUERY_URL/loki/api/v1/query_range" \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=${START_TIME}000000000" \
    --data-urlencode "end=${END_TIME}000000000")

echo "Resultado da query:"
echo "$QUERY_RESULT" | jq '.'
echo ""

# Contar logs encontrados
FOUND_COUNT=$(echo "$QUERY_RESULT" | jq -r '.data.result[0].values | length' 2>/dev/null || echo "0")

if [ "$FOUND_COUNT" -gt 0 ]; then
    echo "✅ SUCESSO! Encontrados $FOUND_COUNT logs no Loki!"
    echo ""
    echo "Logs:"
    echo "$QUERY_RESULT" | jq -r '.data.result[0].values[] | .[1]'
else
    echo "❌ Nenhum log encontrado no Loki"
    echo ""
    echo "Possíveis problemas:"
    echo "  1. URL do Loki incorreta"
    echo "  2. Timestamp fora do range"
    echo "  3. Erro no envio (ver HTTP code acima)"
    echo "  4. Aguardar mais tempo (Loki pode ter delay)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Comandos úteis:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Ver verbose output do curl:"
echo "  cat /tmp/loki-test-verbose.txt"
echo ""
echo "Ver response do Loki:"
echo "  cat /tmp/loki-test-response.txt"
echo ""
echo "Ver arquivo de log:"
echo "  cat $LOG_FILE"
echo ""
echo "Query no Grafana:"
echo "  {service=\"$SERVICE\", type=\"deploy\"}"
echo ""
echo "Query com LogQL:"
echo "  curl -G '$LOKI_QUERY_URL/loki/api/v1/query_range' \\"
echo "    --data-urlencode 'query={service=\"$SERVICE\"}' \\"
echo "    --data-urlencode 'start=${START_TIME}000000000' \\"
echo "    --data-urlencode 'end=${END_TIME}000000000' | jq '.'"
echo ""
