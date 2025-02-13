## Scripts

# Deploy
📌 Como Usar

1️- Dê permissão de execução no script:
```
chmod +x deploy.sh
```

2️ Execute o deploy com:
```
./deploy.sh nome-do-servico branch VAR1=valor1 VAR2=valor2 ...
```

📌 O que o Script Faz?

* Cria o diretório /opt/{serviço} e baixa o código do GitHub.
* Apaga todas as imagens antigas do serviço.
* Para e remove os containers antigos que estavam rodando.
* Constrói uma nova imagem Docker, passando variáveis de ambiente opcionais.
* Move o docker-compose.yml para /opt/{serviço}.
* Verifica os volumes do docker-compose e cria os que faltam.
* Sobe os containers com docker-compose up -d.
* Remove arquivos temporários.
