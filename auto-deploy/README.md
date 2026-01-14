# Auto-Deploy v2.0 🚀

Sistema modular de deployment automatizado com suporte a Docker, rollback automático e zero-downtime.

## 📁 Estrutura

```
auto-deploy/
├── deploy.sh                    # Script principal (orquestrador)
├── lib/                         # Módulos de funções
│   ├── utils.sh                 # Funções utilitárias (log, trim, etc)
│   ├── config.sh                # Parsing de parâmetros e configuração
│   ├── lock.sh                  # Gerenciamento de locks de deploy
│   ├── secrets.sh               # Carregamento de secrets do GitHub
│   ├── git.sh                   # Operações Git
│   ├── docker.sh                # Build, backup e rollback de imagens
│   ├── compose.sh               # Operações Docker Compose
│   ├── volumes.sh               # Gerenciamento de volumes
│   ├── autodeploy_config.sh     # Leitura de .autodeploy.ini
│   └── notifications.sh         # Notificações GitHub Actions
└── README.md                    # Este arquivo
```

## 🚀 Uso

### Sintaxe Básica

```bash
./deploy.sh <service-name> [OPTION=value...]
```

### Parâmetros Obrigatórios

1. **service-name**: Nome do serviço a ser deployado

### Parâmetros Opcionais (key=value, **ordem não importa!** 🔀)

- **GIT_USER=<user>**: Usuário/organização do GitHub (default: `thiagosol`)
- **BRANCH=<branch>**: Branch Git para deploy (default: `main`)
- **ENVIRONMENT=<env>**: Override do ambiente (prod, dev, staging)
  - Se não fornecido, é determinado automaticamente pela branch:
    - `main` ou `master` → `prod`
    - `dev`, `develop`, `development` → `dev`
    - `staging`, `stage` → `staging`
- **APP_ID_TOKEN=<token>**: GitHub token para criar Check Runs (opcional)
- **COMMIT_AFTER=<sha>**: Commit SHA para associar o Check Run (opcional)

> 💡 **Dica**: Você pode passar os parâmetros opcionais em **qualquer ordem**! O parser identifica automaticamente cada `KEY=VALUE`.

### GitHub Check Runs Integration 🔍

Quando `APP_ID_TOKEN` e `COMMIT_AFTER` são fornecidos, o script cria automaticamente um **GitHub Check Run** chamado "🚀 Container Deployment" que:
- Mostra status `in_progress` durante o deploy
- Atualiza para `success` ou `failure` ao final
- Inclui link para logs no Grafana
- Exibe duração, ambiente e detalhes do deploy

### Exemplos

```bash
# Deploy básico (usa defaults: main branch, thiagosol user, prod env)
./deploy.sh my-service

# Deploy de branch específica
./deploy.sh my-service BRANCH=dev

# Deploy com usuário diferente
./deploy.sh my-service GIT_USER=otheruser BRANCH=main

# Deploy com override de ambiente
./deploy.sh my-service BRANCH=dev ENVIRONMENT=staging

# Deploy completo com todas as opções (ordem não importa!)
./deploy.sh my-service BRANCH=dev ENVIRONMENT=staging GIT_USER=thiagosol
./deploy.sh my-service ENVIRONMENT=prod BRANCH=main
./deploy.sh my-service GIT_USER=otheruser

# Deploy com GitHub Check Runs (integração CI/CD)
./deploy.sh my-service \
  BRANCH=main \
  APP_ID_TOKEN=ghp_xxxxxxxxxxxx \
  COMMIT_AFTER=f11293328f79c2cc1c6de6a39299eb14ca600e79
```

## ✨ Funcionalidades

### 📊 Sistema de Logging Integrado com Loki
- **Triplo logging**: Console + Arquivo + Loki simultaneamente
- **Captura TUDO**: Outputs completos de git clone, docker build, docker-compose, etc.
- **Labels organizadas**: `service`, `type=deploy`, `branch`, `environment`, `git_user`
- **Arquivo de log por deploy**: `/opt/auto-deploy/logs/{service}_{branch}_{timestamp}.log`
- **Real-time streaming**: Vê progresso do docker build linha por linha
- **Envio em batch para Loki**: No final do deploy, todos os logs são enviados
- **Limpeza automática**: Remove logs com mais de 30 dias
- **Non-blocking**: Envio para Loki não bloqueia o deploy

Logs podem ser consultados no Grafana com queries como:
```logql
{service="my-service", type="deploy", branch="main"}
{service="my-service", type="deploy", environment="prod"}
{type="deploy", git_user="thiagosol"}
```

### 🔐 Carregamento Automático de Secrets
- Clona automaticamente o repositório `thiagosol/secrets`
- Lê `secrets.json` e exporta todas as variáveis
- Passa variáveis como `--build-arg` para Docker build
- Disponibiliza para substituição em arquivos (render)

### 🔒 Sistema de Locks
- Previne deploys simultâneos do mesmo serviço
- Detecta e remove locks órfãos automaticamente
- Lock por PID com verificação de processo ativo

### 🐳 Build e Deploy Inteligente
- **Zero-downtime**: Build da imagem ANTES de derrubar containers
- **Backup automático**: Salva imagem atual antes de substituir
- **Rollback automático**: Restaura versão anterior em caso de falha
- **Rolling update**: Docker Compose substitui containers sem derrubá-los

### 🌍 Ambientes Dinâmicos
- Determina ambiente automaticamente pela branch
- Permite override manual via parâmetro `ENVIRONMENT`
- Exporta variável `$ENVIRONMENT` para uso em configs

### 📦 Configuração via `.autodeploy.ini`
Suporta arquivo de configuração no repositório do serviço:

```ini
[settings]
compose_file=docker-compose.prod.yml

[copy]
scripts/
config/app.conf

[render]
config/app.conf
nginx/nginx.conf
```

- **[settings]**: Configurações gerais (arquivo compose customizado)
- **[copy]**: Arquivos/pastas extras para copiar
- **[render]**: Arquivos para substituição de variáveis `${VAR}`

## 🔄 Fluxo de Deploy

```
1. Parse de parâmetros e validação ✅
2. Determinação do ambiente (prod/dev/staging) 🌍
3. Aquisição de lock 🔒
4. Carregamento de secrets do GitHub 🔐
5. Clone do repositório Git 📥
6. Leitura de .autodeploy.ini ⚙️
7. Build da nova imagem Docker 🔨
8. Backup da imagem atual 💾
9. Tag da nova imagem 🏷️
10. Preparação do docker-compose 📂
11. Processamento de volumes 📁
12. Cópia de arquivos extras 📦
13. Render de variáveis em arquivos 🧩
14. Rolling update com Docker Compose 🚀
    └─ Se falhar: Rollback automático 🔄
15. Limpeza de imagens antigas 🧹
16. Notificação GitHub Actions 🔔
17. Release do lock 🔓
```

## 🛡️ Proteções e Segurança

- ✅ **Lock por serviço**: Deploys paralelos de serviços diferentes funcionam
- ✅ **Bloqueio de deploys simultâneos**: Mesmo serviço não pode ter 2 deploys ao mesmo tempo
- ✅ **Trap de limpeza**: Lock sempre removido (erro, sucesso ou Ctrl+C)
- ✅ **Rollback automático**: Falha no deploy restaura versão anterior
- ✅ **Secrets isoladas**: Cada processo tem suas próprias variáveis
- ✅ **Validação de parâmetros**: Verifica se todos os parâmetros obrigatórios foram fornecidos

## 📊 Logs e Monitoramento

Todos os logs incluem timestamp no formato:
```
2025-01-14 10:30:00 - 🚀 Starting Auto-Deploy v2.0
2025-01-14 10:30:01 - 🔒 Deployment lock acquired for 'my-service' (PID: 12345)
2025-01-14 10:30:02 - 🔐 Loading secrets from GitHub repository...
```

## 🎯 Exit Codes

- `0`: Deploy bem-sucedido
- `1`: Erro durante deploy (build falhou, compose falhou, etc)
- `2`: Deploy bloqueado (outro deploy em andamento)

## 🔧 Requisitos

- Git
- Docker
- Docker Compose
- jq (para parsing de JSON)
- Acesso SSH ao GitHub configurado em `/opt/auto-deploy/.ssh/id_ed25519`

## 📝 Notas

- O script deve ser executado no servidor de deploy
- Secrets são carregadas do repositório `thiagosol/secrets`
- O arquivo `secrets.json` deve estar na raiz do repositório de secrets
- Variáveis de ambiente em MAIÚSCULAS são passadas como build-args
