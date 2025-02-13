#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

DIR_CERTS="/opt/auto-deploy/scripts/cert-https"
DIR_TRAEFIK="/opt/auto-deploy/traefik-proxy"

log "🔴 Parando o Traefik..."
docker-compose -f "$DIR_TRAEFIK/docker-compose.yml" down

log "📖 Lendo domínio do arquivo de configuração..."
DOMINIO=$(head -n 1 "$DIR_CERTS/domains.txt")

if [ -z "$DOMINIO" ]; then
    log "❌ ERRO: Nenhum domínio encontrado em $DIR_CERTS/domains.txt"
    exit 1
fi

log "🛑 Verificando e removendo containers em execução da imagem certbot/certbot..."

CONTAINERS=$(docker ps -q --filter "ancestor=certbot/certbot")
if [ -n "$CONTAINERS" ]; then
    log "🛑 Containers encontrados, parando e removendo..."
    docker stop $CONTAINERS && docker rm $CONTAINERS
else
    log "✅ Nenhum container ativo da imagem certbot/certbot encontrado."
fi

log "🗑️ Removendo certificados antigos..."
sudo rm -rf "$DIR_CERTS/letsencrypt"

log "🔐 Solicitando novo certificado para: $DOMINIO"
expect <<EOF
    spawn sudo docker run -it --rm --name certbot \
        -v "$DIR_CERTS/letsencrypt:/etc/letsencrypt" \
        -v "$DIR_CERTS/letsencrypt-lib:/var/lib/letsencrypt" \
        -p 80:80 -p 443:443 certbot/certbot certonly

    expect "Select the appropriate number"
    send "1\n"

    expect "Enter email address"
    send "contato@thiagosol.com\n"

    expect "You must agree in order to register with the ACME server. Do you agree?"
    send "Y\n"
    
    expect "Would you be willing, once your first certificate is successfully issued"
    send "Y\n"

    expect "Please enter the domain name"
    send "$DOMINIO\n"
    
    expect eof
EOF

if [ $? -ne 0 ]; then
    log "❌ ERRO: Certbot falhou ao gerar o certificado."
    log "🚀 Reiniciando o Traefik..."
    docker-compose -f "$DIR_TRAEFIK/docker-compose.yml" up
    exit 1
fi

log "✅ Certificado gerado com sucesso!"

log "📂 Copiando certificados para o Traefik..."
sudo cp "$DIR_CERTS/letsencrypt/live/thiagosol.com/fullchain.pem" /opt/auto-deploy/certs/https/fullchain.pem
sudo cp "$DIR_CERTS/letsencrypt/live/thiagosol.com/privkey.pem" /opt/auto-deploy/certs/https/privkey.pem

log "🚀 Reiniciando o Traefik..."
docker-compose -f /opt/sol-apis/traefik/docker-compose.yml up -d

sudo rm -rf "$DIR_CERTS/letsencrypt"
sudo rm -rf "$DIR_CERTS/letsencrypt-lib"

log "✅ Certificado atualizado e Traefik reiniciado com sucesso!"
