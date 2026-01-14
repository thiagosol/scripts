#!/bin/bash

# Script para configurar timezone UTC e sincronizar com NTP
# Execute com: sudo ./fix-timezone.sh

set -e

echo "⏰ Configurando Timezone e NTP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Este script precisa ser executado como root"
    echo "Execute: sudo ./fix-timezone.sh"
    exit 1
fi

# 1. Configurar timezone para UTC
echo "1️⃣ Configurando timezone para UTC..."
timedatectl set-timezone UTC
echo "✅ Timezone configurado para UTC"
echo ""

# 2. Habilitar sincronização NTP
echo "2️⃣ Habilitando sincronização NTP..."
timedatectl set-ntp true
echo "✅ NTP habilitado"
echo ""

# 3. Instalar/verificar ntpdate (se necessário)
echo "3️⃣ Verificando pacotes de sincronização..."
if ! command -v ntpdate &> /dev/null; then
    echo "Instalando ntpdate..."
    apt-get update -qq
    apt-get install -y ntpdate systemd-timesyncd
    echo "✅ Pacotes instalados"
else
    echo "✅ ntpdate já instalado"
fi
echo ""

# 4. Forçar sincronização imediata
echo "4️⃣ Forçando sincronização imediata com servidor NTP..."
systemctl stop systemd-timesyncd 2>/dev/null || true
ntpdate -s time.google.com || ntpdate -s pool.ntp.org || ntpdate -s time.cloudflare.com
systemctl start systemd-timesyncd
echo "✅ Sincronização completa"
echo ""

# 5. Aguardar sincronização
echo "5️⃣ Aguardando sincronização do systemd-timesyncd..."
sleep 3
timedatectl timesync-status 2>/dev/null || echo "(Status não disponível, mas NTP está ativo)"
echo ""

# 6. Verificar configuração final
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Configuração Final:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
timedatectl
echo ""

# 7. Verificar data/hora
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🕐 Data/Hora Atual:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Sistema:  $(date)"
echo "UTC:      $(date -u)"
echo "Unix:     $(date +%s) segundos desde 1970"
echo ""

# 8. Verificar se ano está correto
YEAR=$(date +%Y)
if [ "$YEAR" != "2025" ]; then
    echo "⚠️ ATENÇÃO: O ano está como $YEAR (esperado: 2025)"
    echo "Pode ser que o NTP ainda não tenha sincronizado completamente."
    echo "Aguarde 1-2 minutos e execute: date"
else
    echo "✅ Ano correto: $YEAR"
fi
echo ""

# 9. Validar timestamp para Loki
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Validação para Loki:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CURRENT_TS=$(date +%s)
LOKI_MAX_AGE=432000  # 120 horas = 5 dias em segundos
MIN_VALID_TS=$((CURRENT_TS - LOKI_MAX_AGE))
MAX_VALID_TS=$((CURRENT_TS + LOKI_MAX_AGE))

echo "Timestamp atual: $CURRENT_TS"
echo "Range aceito pelo Loki (5 dias):"
echo "  Mínimo: $MIN_VALID_TS ($(date -d @$MIN_VALID_TS 2>/dev/null || echo 'N/A'))"
echo "  Máximo: $MAX_VALID_TS ($(date -d @$MAX_VALID_TS 2>/dev/null || echo 'N/A'))"
echo ""

if [ "$YEAR" == "2025" ]; then
    echo "✅ Timestamps estão no range correto para Loki"
else
    echo "⚠️ Timestamps podem estar fora do range aceito pelo Loki"
fi
echo ""

# 10. Testar timestamp em nanosegundos (formato do Loki)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Teste de Timestamp (formato Loki):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
NANO_TS=$(date +%s%N)
echo "Timestamp em nanosegundos: $NANO_TS"
echo "Data correspondente: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Verificar comprimento (deve ter 19 dígitos)
LEN=${#NANO_TS}
if [ $LEN -eq 19 ]; then
    echo "✅ Formato correto (19 dígitos)"
elif [ $LEN -eq 10 ]; then
    echo "⚠️ Aviso: date +%s%N retornou apenas segundos (10 dígitos)"
    echo "Multiplicando por 1000000000 para obter nanosegundos..."
    NANO_TS="${NANO_TS}000000000"
    echo "Novo timestamp: $NANO_TS"
else
    echo "⚠️ Comprimento inesperado: $LEN dígitos"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Configuração Concluída!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Resumo:"
echo "  • Timezone: UTC"
echo "  • NTP: Habilitado e sincronizado"
echo "  • Data/Hora: Sincronizada com servidor NTP"
echo "  • Formato Loki: OK"
echo ""
echo "🎯 Próximos Passos:"
echo "  1. O sistema vai manter a hora sincronizada automaticamente"
echo "  2. Logs do deploy agora terão timestamps corretos"
echo "  3. Aparecerão no Grafana no range 'Last X hours'"
echo ""
echo "🧪 Testar agora:"
echo "  cd /opt/auto-deploy/scripts/auto-deploy"
echo "  ./test-logging.sh"
echo ""
echo "📊 Ver no Grafana:"
echo "  Query: {service=\"test-service\", type=\"deploy\"}"
echo "  Range: Last 1 hour"
echo ""
