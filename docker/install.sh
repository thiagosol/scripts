#!/bin/bash

set -e  # Para o script caso algum comando falhe

LOKI_IP="172.23.0.200"  
LOG_NET_GATEWAY="172.23.0.1"  
LOG_NET_SUBNET="172.23.0.0/24" 

echo "🔍 Verificando se o Docker está instalado..."
if ! command -v docker &> /dev/null; then
    echo "📦 Instalando Docker..."
    sudo apt update
    sudo apt install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
else
    echo "✅ Docker já está instalado."
fi

echo "🔍 Verificando se o Docker Compose está instalado..."
if ! command -v docker-compose &> /dev/null; then
    echo "📦 Instalando Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
else
    echo "✅ Docker Compose já está instalado."
fi

echo "🔍 Verificando e criando redes Docker..."
if ! docker network ls | grep -q "logging-network"; then
    echo "🌐 Criando a rede 'logging-network' com gateway e IP fixo..."
    sudo docker network create --subnet=$LOG_NET_SUBNET --gateway=$LOG_NET_GATEWAY logging-network
else
    echo "✅ Rede 'logging-network' já existe."
fi
if ! docker network ls | grep -q "external-sol-apis"; then
    echo "🌐 Criando a rede 'external-sol-apis' (aceita conexões externas)..."
    docker network create --driver=bridge --attachable external-sol-apis
else
    echo "✅ Rede 'external-sol-apis' já existe."
fi
if ! docker network ls | grep -q "wetty-network"; then
    echo "🌐 Criando a rede 'wetty-network'"
    docker network create --attachable wetty-network
else
    echo "✅ Rede 'wetty-network' já existe."
fi
if ! docker network ls | grep -q "chat-network"; then
    echo "🌐 Criando a rede 'chat-network'"
    docker network create --attachable chat-network
else
    echo "✅ Rede 'chat-network' já existe."
fi

echo "🔍 Atualizando '/etc/hosts' com o IP fixo do Loki..."
sudo sed -i "/loki/d" /etc/hosts
echo "$LOKI_IP loki" | sudo tee -a /etc/hosts

echo "🔄 Reiniciando Docker para aplicar mudanças..."
sudo systemctl restart docker

echo "🎉 Setup concluído com sucesso!"
