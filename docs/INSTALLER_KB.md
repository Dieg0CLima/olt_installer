# KB do `olt_installer`

Este documento registra as decisões de arquitetura do instalador e por que elas são
diferentes das de instaladores anteriores (ex.: `fb-dns-installer`, usado como
referência de estilo/estrutura para este). Não é uma cópia — cada decisão foi
reavaliada contra o que o OLT System realmente precisa.

## 1. Por que um `docker-compose.yml` estático só (sem "papel"/variantes)

Instaladores anteriores (ex.: `fb-dns-installer`) embutem **dois** blocos de compose
inteiros quando a stack tem variantes (lá, `authoritative`/`resolver` — containers
fundamentalmente diferentes). Aqui, a única variação real é "o Postgres é meu ou é de
alguém" — isso é um toggle de UM serviço, não uma stack diferente.

**Regra seguida:** nunca gerar YAML dinamicamente por concatenação condicional, e
nunca duplicar um compose quase-igual só por causa de 1 serviço opcional. A ferramenta
certa pra isso é `profiles:` do próprio Compose — `db` fica atrás de
`profiles: ["self-hosted-db"]`, e o `.env` liga isso via `COMPOSE_PROFILES=self-hosted-db`
(lido automaticamente pelo `docker compose`, o script não precisa saber de nada além
de escrever essa linha). Ver `../olt_docker/docker-compose.prod.yml`.

Consequência prática: `db` **não** tem `depends_on` vindo de `api` — com o serviço
atrás de profile, essa relação é frágil (o comportamento do Compose validando
`depends_on` contra um serviço não-ativado não foi testado a fundo). Confia-se no
`restart: unless-stopped` do `api` + retry nativo do Ecto/Postgrex, e na validação
pós-`up` do próprio instalador (que já espera os containers ficarem saudáveis).

## 2. Compose embutido no script: mesmas 3 condições da referência

1. O heredoc é **sempre** gerado por `scripts/sync-installer.sh`, nunca editado à
   mão — marcado com `# >>> OLT:PROD:BEGIN` / `# <<< OLT:PROD:END`.
2. `tests/test-sync.sh` valida que o heredoc bate com a fonte
   (`../olt_docker/docker-compose.prod.yml`).
3. Delimitador de heredoc **quoted** (`<<'OLT_COMPOSE_EOF'`) — `${VAR}` sobrevive até
   o Docker Compose interpolar, nunca expande no momento da geração do script.

## 3. Imagens vêm de um registry (GHCR), não build no host de destino

Decisão explícita do usuário (não a recomendação inicial, que era "build a partir do
fonte no servidor"). Consequência: **este trabalho incluiu montar o CI que publica as
imagens** (`.github/workflows/publish.yml` em `olt_system` e `olt_web`) — sem isso o
instalador não teria imagem nenhuma pra puxar. `check_registry()` falha cedo e com
mensagem clara (`docker login ghcr.io` + confirmar que a tag existe) se o pré-flight
não conseguir acessar a imagem — GHCR trata pacotes vinculados a repositório privado
como privados por padrão, então login é esperado, não um bug.

## 4. Falta um endpoint de health-check real — adicionado

`olt_system` não tinha NENHUM endpoint de liveness/readiness antes deste trabalho
(gap já identificado na avaliação do fluxo de deploy). `GET /health` foi adicionado
(`Web.HealthController`, público, sem tocar banco) especificamente para o
`check_http`/`wait_healthy` do instalador terem algo real para checar via HTTP. É
liveness, não readiness — nunca falha por causa do banco, só confirma que
`Web.Endpoint` está de pé.

Decisão de NÃO adicionar `HEALTHCHECK` no `Dockerfile.prod`: `wait_healthy()` já trata
"sem healthcheck Docker" como um resultado OK (mesmo comportamento herdado da
referência) — validar via `curl` do HOST contra a porta publicada é mais simples que
adicionar `curl`/`wget` só pra isso na imagem runtime (que hoje não tem nenhum
utilitário HTTP, ver `olt_system/Dockerfile.prod`).

## 5. Migração de banco: `Web.Release.migrate/0`, sempre, idempotente

Já existia desde a ADR `0031-release-de-producao.md` (`olt_system`), criada
especificamente para este cenário: migração como passo EXPLÍCITO depois do deploy,
nunca acoplada ao boot do container. `run_migration()` chama
`docker compose exec -T api bin/olt_system eval "Web.Release.migrate()"` com um
retry curto (o container pode levar um instante pra aceitar `exec` logo após o
`up -d`). Como `Ecto.Migrator.run/4` não faz nada quando já está tudo aplicado, é
seguro chamar em `install` E em `upgrade` sem precisar distinguir "banco novo" de
"banco existente" — simplifica o fluxo em relação a checar isso explicitamente.

## 6. Sem armadilha de porta privilegiada (nada equivalente à porta 53/systemd-resolved)

A stack não compete por nenhuma porta que o sistema operacional já usa por padrão.
O pré-flight verifica só as portas reais que a própria stack vai ocupar (frontend,
API, Postgres se self-hosted) — sem lógica de "desabilitar serviço do SO" nenhuma.

## 7. Gotcha real de bash encontrado e corrigido: `[ cond ] && cmd` como último
   comando de uma função, sob `set -e`

`env_lines()` originalmente terminava com:

```bash
[ "$DB_MODE" = self-hosted ] && printf 'COMPOSE_PROFILES=self-hosted-db\n'
```

Quando `DB_MODE` != `self-hosted` (modo `external`, testado primeiro), o teste `[ ]`
retorna falso, `&&` nunca roda o `printf`, e o status de saída da função inteira vira
1 (o do último comando executado) — mesmo sem nada de errado ter acontecido. Como
essa função é usada em `env_lines | sed ...` dentro de `write_env()`, e o script roda
com `pipefail`, a pipeline inteira "falha" e o script morre com
"olt-install.sh terminou com erro" **antes mesmo de rodar `docker compose up`** —
só apareceu rodando `install --dry-run` de verdade no modo `external`. Corrigido
trocando por um `if`/`fi` de verdade (que sempre retorna 0 quando a condição é falsa
e não há `else`). `containers_for_mode()`/`volumes_for_mode()` já tinham um
`return 0` explícito no final, o que as protegia do mesmo problema por acidente —
mantido, mas o `if` de verdade é a forma preferida daqui pra frente: mais clara sobre
a intenção, não depende de lembrar de colar um `return 0`.

**Regra pra qualquer função nova**: se o último comando de uma função pode
legitimamente ser "falso" sem que isso signifique erro (um `[ cond ] && algo`
opcional), ou é um `if`/`fi` completo, ou termina com `return 0` explícito — nunca
deixe um `&&`/`||` sem rede de segurança ser o último comando executado.
