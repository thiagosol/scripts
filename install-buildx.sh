#!/bin/bash

#==============================================================================
# Script de Instalação do Docker Buildx
#==============================================================================

set -e

echo "🚀 Instalando Docker Buildx..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Verificar versão do Docker (precisa ser 19.03+)
echo "📋 Verificando versão do Docker..."
docker --version

# 2. Criar diretório de plugins
echo "📁 Criando diretório de plugins..."
mkdir -p ~/.docker/cli-plugins

# 3. Baixar o buildx (versão mais recente)
echo "📥 Baixando buildx..."
BUILDX_VERSION=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
echo "   Versão: $BUILDX_VERSION"

curl -L "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
  -o ~/.docker/cli-plugins/docker-buildx

# 4. Dar permissão de execução
echo "🔑 Configurando permissões..."
chmod +x ~/.docker/cli-plugins/docker-buildx

# 5. Verificar instalação
echo "✅ Verificando instalação..."
docker buildx version

# 6. Criar e usar builder (recomendado para melhor performance)
echo "🔧 Configurando builder..."
docker buildx create --name mybuilder --use --bootstrap 2>/dev/null || \
  docker buildx use mybuilder 2>/dev/null || \
  echo "ℹ️  Builder já existe"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Docker Buildx instalado com sucesso!"
echo ""
echo "🎯 Próximos passos:"
echo "   1. Voltar os scripts ao normal (com DOCKER_BUILDKIT=1)"
echo "   2. Rodar o deploy normalmente"
echo ""
echo "💡 Benefícios:"
echo "   - Builds até 2x mais rápidos"
echo "   - Cache inteligente e paralelo"
echo "   - Melhor uso de recursos"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
