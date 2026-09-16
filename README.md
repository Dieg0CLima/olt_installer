# olt_installer

Instalador de produção do OLT System: backend (`olt_system`) + frontend (`olt_web`) +
Postgres opcional, via imagens publicadas no GHCR.

Script auto-contido (`olt-install.sh`) — o `docker-compose.prod.yml` real de
[`olt_docker`](../olt_docker) vem embutido nele. Não é preciso clonar nenhum repo no
servidor de destino: basta copiar esse um arquivo.

Fundamentação, decisões de arquitetura e adaptações em relação a instaladores
anteriores estão em [`docs/INSTALLER_KB.md`](docs/INSTALLER_KB.md).

## Status

`install`, `doctor`, `upgrade`, `backup`, `restore` e `uninstall` implementados.

## Baixar

```bash
curl -fsSL https://raw.githubusercontent.com/Dieg0CLima/olt_installer/master/olt-install.sh -o olt-install.sh
chmod +x olt-install.sh
```

As imagens (`ghcr.io/dieg0clima/olt_system`/`olt_web`) são privadas — `docker login
ghcr.io` (token com escopo `read:packages`) antes de instalar, ou peça pra tornar os
pacotes públicos.

## Uso

```bash
# Instalação interativa (pergunta diretório, tag, host público, CORS, modo de banco)
sudo ./olt-install.sh install

# Não-interativa, com arquivo de respostas
sudo ./olt-install.sh install -c olt.answers -y

# Prévia sem tocar em nada (não precisa de root nem de docker login)
./olt-install.sh install --dir /tmp/teste --dry-run

# Escreve os arquivos mas não sobe a stack
sudo ./olt-install.sh install --no-start

# Diagnóstico read-only de uma instalação existente
sudo ./olt-install.sh doctor --dir /opt/olt-system

# Atualiza a tag de imagem — faz backup antes, sobe, valida, oferece rollback
# automático se a validação falhar
sudo ./olt-install.sh upgrade --tag v1.1.0 --dir /opt/olt-system

# Arquiva .env, docker-compose.yml e (se self-hosted) o volume do Postgres
sudo ./olt-install.sh backup --dir /opt/olt-system

# Restaura um backup — SOBRESCREVE o que estiver em --dir, com backup
# automático do que já existir antes de aplicar
sudo ./olt-install.sh restore /opt/olt-system/backups/olt-system-backup-*.tgz

# Para e remove os containers; volumes ficam
sudo ./olt-install.sh uninstall --dir /opt/olt-system

# Remove TUDO (volumes + config no host) — irreversível, sempre pede
# confirmação digitada do hostname mesmo com -y
sudo ./olt-install.sh uninstall --purge --dir /opt/olt-system
```

### Arquivo de respostas (`--config`/`-c`)

Formato `KEY=VALUE`, uma por linha, comentários com `#`. Só as chaves abaixo são
aceitas — qualquer outra é ignorada com aviso (o parser não usa `source`, não roda
código do arquivo):

```
INSTALL_DIR=/opt/olt-system
IMAGE_TAG=v1.0.0
OLT_SYSTEM_HOST=olt.exemplo.com.br
OLT_SYSTEM_CORS_ORIGINS=https://olt.exemplo.com.br
OLT_WEB_API_BASE_URL=https://api.olt.exemplo.com.br
OLT_WEB_HTTP_PORT=80
DB_MODE=external                        # external | self-hosted
OLT_SYSTEM_DB_HOST=postgres.interno
OLT_SYSTEM_DB_PORT=5432
OLT_SYSTEM_DB_USER=olt_system
OLT_SYSTEM_DB_PASSWORD=...              # só faz sentido com DB_MODE=external
OLT_SYSTEM_DB_NAME=olt_system_prod
```

`OLT_SYSTEM_SECRET_KEY_BASE` e `OLT_SYSTEM_ENCRYPTION_KEY` **não** precisam ir no
arquivo de respostas: são gerados automaticamente na primeira instalação e
preservados nas seguintes (rodar `install` de novo sobre o mesmo `--dir` não gera
segredos novos — ver `secret_or_keep` em `olt-install.sh`). No modo `self-hosted`,
`OLT_SYSTEM_DB_PASSWORD` também é gerado e preservado do mesmo jeito.

## O que o `install` faz, em ordem

1. Detecta SO/arquitetura/Compose v2 (recusa Compose v1).
2. Pergunta (ou lê de `--config`) diretório, tag de imagem, host público, URL da
   API, CORS, porta do frontend e modo de banco (externo ou self-hosted).
3. Pré-flight: root, comandos (`docker openssl curl ss`), daemon do Docker, espaço
   em disco, portas livres (80/frontend, 4000/API, 5432 só se self-hosted),
   alcançabilidade do Postgres externo (se for o caso), acesso ao GHCR para as 2
   imagens.
4. Mostra um resumo e pede confirmação.
5. Escreve `$INSTALL_DIR/docker-compose.yml` (o bloco embutido) e `$INSTALL_DIR/.env`
   (`chmod 600`, com backup timestamped se já existia).
6. `docker compose pull` → `docker compose up -d`.
7. Roda a migração do banco (`docker compose exec api bin/olt_system eval
   "Web.Release.migrate()"` — idempotente, seguro rodar sempre).
8. Valida (`GET /health` da API, `GET /` do frontend).

Todo esse fluxo é dry-run-aware (`-n`/`--dry-run`): nada é escrito em disco nem
executado de verdade, e checagens que dependem do ambiente real (root, login no
registry, portas livres, Postgres externo alcançável) viram aviso em vez de erro
fatal, para que o preview funcione mesmo numa máquina de dev sem esse setup.

## Backup — o que entra e o que fica de fora

`backup`/`upgrade`/`uninstall --purge` arquivam `.env`, `docker-compose.yml`,
`manifest.json` e, **só no modo `self-hosted`**, o volume `postgres_data`. No modo
`external`, o Postgres não é nosso — o backup avisa isso em destaque e não tenta
arquivar dados que não administra.

`install` fixa `COMPOSE_PROJECT_NAME=olt-system` no `.env` — é isso que garante que
`docker volume inspect`/`docker run` em `backup`/`restore` achem o volume certo (o
Compose sempre prefixa volume com o nome do projeto).

## Manutenção do próprio instalador

O bloco de `docker-compose.yml` embutido em `olt-install.sh` (entre os marcadores
`# >>> OLT:PROD:BEGIN` e `# <<< OLT:PROD:END`) é **gerado** — nunca edite-o à mão.
Fonte da verdade: [`../olt_docker/docker-compose.prod.yml`](../olt_docker/docker-compose.prod.yml)
(repo irmão deste, no mesmo workspace).

```bash
# depois de mudar docker-compose.prod.yml em olt_docker:
scripts/sync-installer.sh          # regenera o bloco embutido

# em CI / antes de commitar: só valida, não escreve nada
scripts/sync-installer.sh --check
```

## Testes

```bash
tests/test-sync.sh          # o bloco embutido bate com a fonte?
tests/test-preflight.sh     # validadores, geradores de segredo, idempotência do
                             # .env, parser de --config — sem Docker, sem root
tests/test-lifecycle.sh     # upgrade/backup/restore/uninstall via --dry-run contra
                             # um $INSTALL_DIR fake — sem tocar volume/container real
shellcheck -s bash -S warning olt-install.sh scripts/*.sh tests/*.sh
```

`test-lifecycle.sh` não exercita o caminho real de `docker volume`/`docker run`
(exigiria Docker + a imagem `alpine:3` de verdade) — isso fica para teste manual num
host de teste ou instalação real.

## Como as imagens chegam no GHCR

`olt_system` e `olt_web` publicam via `.github/workflows/publish.yml` em cada repo —
build de `Dockerfile.prod`, push pra `ghcr.io/dieg0clima/olt_system` e
`ghcr.io/dieg0clima/olt_web` a cada push em `master` (tags `latest`/`sha-<curto>`) e a
cada tag `v*` (a tag vira o nome da imagem, é essa que `--tag` usa).

## Fora do escopo

- Onde o servidor de destino roda (VPS/Fly/k8s), TLS/reverse proxy — decisão de infra
  que ainda não foi tomada (ver ADR `0031-release-de-producao.md` em `olt_system`).
- CI/CD deste próprio repo (`olt_installer`) — só os testes locais acima por enquanto.
