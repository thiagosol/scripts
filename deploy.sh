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

# 🚀 Verificar se o Dockerfile existe antes de continuar
if [ ! -f "$DIR_TEMP/Dockerfile" ]; then

    log "⚠️ Nenhum Dockerfile encontrado. Apenas copiando arquivos para $DIR_BASE e finalizando."
    cp -r "$DIR_TEMP/"* "$DIR_BASE/"
    find "$DIR_BASE" -type f -name "*.sh" -exec chmod +x {} \;
    rm -rf "$DIR_TEMP"
    log "✅ Deploy sem docker finalizado!"
    exit 0
fi

# 🚀 Remover imagens antigas
log "🔥 Removendo imagens antigas..."
IMAGEM_EXISTENTE=$(docker images -q "$SERVICO")
if [ -n "$IMAGEM_EXISTENTE" ]; then
    log "📌 Encontrado: removendo containers e imagens..."
    docker ps -q --filter "ancestor=$SERVICO" | xargs -r docker stop
    docker ps -aq --filter "ancestor=$SERVICO" | xargs -r docker rm
    docker rmi -f "$SERVICO"
fi

# 🚀 Criar o build da nova imagem
log "🔨 Construindo a nova imagem..."
DOCKER_BUILD_CMD="docker build --rm --force-rm -t $SERVICO ."

# Passar variáveis de ambiente para o build
shift 2
for VAR in "$@"; do
    DOCKER_BUILD_CMD+=" --build-arg $VAR"
done

eval "$DOCKER_BUILD_CMD"

# 🚀 Mover `docker-compose.yml` para a raiz do diretório de trabalho
log "📂 Movendo docker-compose.yml para $DIR_BASE"
mv "$DIR_TEMP/docker-compose.yml" "$DIR_BASE/"

log "🛠️ Verificando volumes..."
VOLUMES=$(grep -oP '(?<=- \./)[^:]+' "$DIR_BASE/docker-compose.yml")

for VOL in $VOLUMES; do
    ORIGEM="$DIR_TEMP/$VOL"
    DESTINO="$DIR_BASE/$VOL"

    # Se o volume for um arquivo ou diretório e existir na pasta temp, move ele
    if [ -e "$ORIGEM" ]; then
        log "📁 Movendo volume $ORIGEM para $DESTINO"
        mv "$ORIGEM" "$DESTINO" || log "⚠️ Erro ao mover $ORIGEM, ignorando..."
    else
        log "❌ Volume $ORIGEM não encontrado no temp, ignorando..."
    fi

    # Se o destino ainda não existir, cria um diretório vazio
    if [ ! -e "$DESTINO" ]; then
        log "📁 Criando volume vazio em $DESTINO"
        mkdir -p "$DESTINO"
        chmod 777 -R "$DESTINO"
    fi
done

# 🛠️ Limpeza final
log "🛠️ Limpeza dos diretórios temporários e imagens..."
rm -rf "$DIR_TEMP"
docker images -f "dangling=true" -q | xargs -r docker rmi -f

# 🚀 Subir os containers
cd "$DIR_BASE" || exit 1
log "🚀 Iniciando o serviço..."
docker-compose up -d

log "✅ Deploy finalizado!"
