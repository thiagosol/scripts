#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

DIR_CERTS="/opt/auto-deploy/scripts/cert-https"

log "🔴 Parando o Traefik..."
docker-compose -f /opt/sol-apis/traefik/docker-compose.yml down

log "🗑️ Removendo certificados antigos..."
rm -rf "$DIR_CERTS/letsencrypt/live/thiagosol.com"

log "📖 Lendo domínio do arquivo de configuração..."
DOMINIO=$(head -n 1 "$DIR_CERTS/domains.txt")

if [ -z "$DOMINIO" ]; then
    log "❌ ERRO: Nenhum domínio encontrado em $DIR_CERTS/domains.txt"
    exit 1
fi

log "🔐 Solicitando novo certificado para: $DOMINIO"

sudo docker run -i --rm --name certbot \
    -v "$DIR_CERTS/letsencrypt:/etc/letsencrypt" \
    -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
    -p 80:80 -p 443:443 certbot/certbot certonly \
    | { sleep 10; echo "1"; sleep 10; echo "$DOMINIO"; }

if [ $? -ne 0 ]; then
    log "❌ ERRO: Certbot falhou ao gerar o certificado."
    exit 1
fi

log "✅ Certificado gerado com sucesso!"

log "📂 Copiando certificados para o Traefik..."
cp "$DIR_CERTS/letsencrypt/live/thiagosol.com/fullchain.pem" /opt/sol-apis/traefik/data/certs/fullchain.pem
cp "$DIR_CERTS/letsencrypt/live/thiagosol.com/privkey.pem" /opt/sol-apis/traefik/data/certs/privkey.pem

log "🚀 Reiniciando o Traefik..."
docker-compose -f /opt/sol-apis/traefik/docker-compose.yml up -d

log "✅ Certificado atualizado e Traefik reiniciado com sucesso!"
