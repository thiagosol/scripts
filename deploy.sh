#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

SERVICO=$1
BRANCH=${2:-main}
DIR_BASE="/opt/auto-deploy/$SERVICO"
DIR_TEMP="$DIR_BASE/temp"
GIT_REPO="https://github.com/thiagosol/$SERVICO.git"

mkdir -p "$DIR_TEMP"
cd "$DIR_TEMP" || exit 1

log "📥 Baixando o repositório $GIT_REPO na branch $BRANCH..."
git clone --depth=1 --branch "$BRANCH" "$GIT_REPO" .

if [ ! -f "$DIR_TEMP/Dockerfile" ] && [ -z "$(find "$DIR_TEMP" -maxdepth 1 -type f -name 'docker-compose*.yml' -print -quit)" ]; then
    log "⚠️ Nenhum Dockerfile ou arquivo docker-compose.yml encontrado. Apenas copiando arquivos para $DIR_BASE e finalizando."
    cp -r "$DIR_TEMP/"* "$DIR_BASE/"
    find "$DIR_BASE" -type f -name "*.sh" -exec chmod +x {} \;
    rm -rf "$DIR_TEMP"
    log "✅ Deploy sem docker finalizado!"
    exit 0
fi


log "🔥 Removendo imagens antigas..."
IMAGEM_EXISTENTE=$(docker images -q "$SERVICO")
if [ -n "$IMAGEM_EXISTENTE" ]; then
    log "📌 Encontrado: removendo containers e imagens..."
    docker ps -q --filter "ancestor=$SERVICO" | xargs -r docker stop
    docker ps -aq --filter "ancestor=$SERVICO" | xargs -r docker rm
    docker rmi -f "$SERVICO"
fi

shift 2

if [ -f "$DIR_TEMP/Dockerfile" ]; then
    log "🔨 Construindo a nova imagem..."
    DOCKER_BUILD_CMD="docker build --rm --force-rm -t $SERVICO $DIR_TEMP"

    for VAR in "$@"; do
        DOCKER_BUILD_CMD+=" --build-arg $VAR"
    done

    eval "$DOCKER_BUILD_CMD"
else
    log "⚠️ Nenhum Dockerfile encontrado em $DIR_TEMP. Pulando etapa de build."
fi

log "📂 Movendo docker-compose.yml para $DIR_BASE"
mv "$DIR_TEMP/docker-compose.yml" "$DIR_BASE/"

log "🛠️ Verificando volumes..."
VOLUMES=$(grep -oP '(?<=- \./)[^:]+' "$DIR_BASE/docker-compose.yml")

for VOL in $VOLUMES; do
    ORIGEM="$DIR_TEMP/$VOL"
    DESTINO="$DIR_BASE/$VOL"

    if [ -e "$ORIGEM" ]; then
        log "📁 Movendo volume $ORIGEM para $DESTINO"
        mv "$ORIGEM" "$DESTINO" || log "⚠️ Erro ao mover $ORIGEM, ignorando..."
    else
        log "❌ Volume $ORIGEM não encontrado no temp, ignorando..."
    fi

    if [ ! -e "$DESTINO" ]; then
        log "📁 Criando volume vazio em $DESTINO"
        mkdir -p "$DESTINO"
        chmod 777 -R "$DESTINO"
    fi
done

log "🛠️ Limpeza dos diretórios temporários e imagens..."
rm -rf "$DIR_TEMP"
docker images -f "dangling=true" -q | xargs -r docker rmi -f

cd "$DIR_BASE" || exit 1
log "🔄 Subindo os containers com Docker Compose..."
docker-compose down
ENV_VARS=""
for VAR in "$@"; do
    ENV_VARS+="$(echo "$VAR" | awk -F'=' '{print $1"="$2}') "
done
eval "$ENV_VARS docker-compose up -d"

log "✅ Deploy finalizado!"
