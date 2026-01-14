#!/bin/bash

# Teste com debug do sender em background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Limpar logs de debug anteriores
rm -f /tmp/loki-sender-debug.log
rm -f /tmp/loki-errors.log

# Load modules
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/logging.sh"

# Set variables
export SERVICE="test-service"
export BRANCH="test-branch"
export ENVIRONMENT="test"
export GIT_USER="testuser"

echo "🧪 Teste com Debug do Sender"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Configuração:"
echo "  SERVICE: $SERVICE"
echo "  LOKI_URL: ${LOKI_URL:-http://loki:3100/loki/api/v1/push}"
echo ""

# Initialize logging
init_logging "$SERVICE" "$BRANCH"

echo ""
echo "📝 Gerando logs..."
echo ""

# Generate logs
log "🚀 Test 1"
sleep 2
log "📦 Test 2"
sleep 2
log "🔨 Test 3"
sleep 2
log "✅ Test 4"

echo ""
echo "⏰ Aguardando 15 segundos (sender roda a cada 10s)..."
sleep 15

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Debug do Sender:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f /tmp/loki-sender-debug.log ]; then
    cat /tmp/loki-sender-debug.log
else
    echo "❌ Arquivo de debug não foi criado!"
    echo "Isso significa que send_new_logs_to_loki() nunca foi chamada."
    echo ""
    echo "Verificando processo sender:"
    ps aux | grep -v grep | grep loki_sender || echo "Processo não encontrado!"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "❌ Erros (se houver):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f /tmp/loki-errors.log ]; then
    cat /tmp/loki-errors.log
else
    echo "✅ Nenhum erro registrado"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 Status do Buffer:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$LOKI_BUFFER_FILE" ]; then
    SENT=$(cat "$LOKI_BUFFER_FILE")
    TOTAL=$(wc -l < "$LOG_FILE")
    echo "Linhas enviadas: $SENT"
    echo "Total de linhas: $TOTAL"
    echo "Pendentes: $((TOTAL - SENT))"
else
    echo "❌ Buffer file não existe: $LOKI_BUFFER_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📄 Conteúdo do Log File:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat "$LOG_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Variáveis de Ambiente (no sender):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "PID do sender: $LOKI_SENDER_PID"
echo "LOG_FILE: $LOG_FILE"
echo "LOKI_BUFFER_FILE: $LOKI_BUFFER_FILE"
echo "SERVICE: $SERVICE"
echo "BRANCH: $BRANCH"

echo ""
echo "📤 Forçando envio dos logs restantes..."
send_remaining_logs_to_loki

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Teste concluído!"
echo ""
echo "Ver debug completo:"
echo "  cat /tmp/loki-sender-debug.log"
echo ""
echo "Ver erros:"
echo "  cat /tmp/loki-errors.log"
echo ""
echo "Query no Grafana:"
echo "  {service=\"$SERVICE\", type=\"deploy\"}"
echo ""
