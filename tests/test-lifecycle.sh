#!/usr/bin/env bash
# Testes dos comandos de ciclo de vida (upgrade/backup/restore/uninstall) via
# --dry-run contra um $INSTALL_DIR fake pré-semeado — sem tocar volumes/containers
# de verdade (precisa de `docker compose version` disponível, já que
# detect_compose() roda mesmo sob --dry-run; nenhuma operação de dado é real).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/olt-install.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

seed_install_dir() {
  # seed_install_dir DIR DB_MODE — simula uma instalação já existente sem
  # precisar rodar `install` de verdade.
  local dir="$1" db_mode="$2" profiles_line=""
  mkdir -p "$dir"
  [ "$db_mode" = self-hosted ] && profiles_line="COMPOSE_PROFILES=self-hosted-db"
  cat > "$dir/.env" <<EOF
IMAGE_TAG=v1.0.0
OLT_SYSTEM_SECRET_KEY_BASE=fakesecret0000000000000000000000000000000000000000000000000000
OLT_SYSTEM_ENCRYPTION_KEY=ZmFrZS1lbmNyeXB0aW9uLWtleS0zMi1ieXRlcy1sb25nISE=
OLT_SYSTEM_HOST=example.com
OLT_SYSTEM_CORS_ORIGINS=http://example.com
OLT_WEB_API_BASE_URL=http://example.com:4000
OLT_WEB_HTTP_PORT=80
OLT_SYSTEM_DB_HOST=db
OLT_SYSTEM_DB_PORT=5432
OLT_SYSTEM_DB_USER=olt_system
OLT_SYSTEM_DB_PASSWORD=fakepassword
OLT_SYSTEM_DB_NAME=olt_system_prod
${profiles_line}
EOF
  chmod 600 "$dir/.env"
  printf 'services: {}\n' > "$dir/docker-compose.yml"
}

# run_cmd CMD... — captura stdout+stderr e status sem deixar `set -e` do
# runner de teste abortar no meio (o comando testado costuma retornar != 0 de
# propósito nos casos "expect_failure").
run_cmd() {
  set +e
  OUT="$("$INSTALL_SH" "$@" 2>&1)"
  STATUS=$?
  set -e
}

expect_success_containing() {
  local desc="$1" needle="$2"
  shift 2
  run_cmd "$@"
  if [ "$STATUS" -eq 0 ] && [[ "$OUT" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (status=%s)\n' "$desc" "$STATUS"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    FAIL=$((FAIL + 1))
  fi
}

expect_failure_containing() {
  local desc="$1" needle="$2"
  shift 2
  run_cmd "$@"
  if [ "$STATUS" -ne 0 ] && [[ "$OUT" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (status=%s)\n' "$desc" "$STATUS"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    FAIL=$((FAIL + 1))
  fi
}

DIR_SELFHOSTED="$TMPROOT/selfhosted-install"
DIR_EXTERNAL="$TMPROOT/external-install"
DIR_EMPTY="$TMPROOT/empty-install"
seed_install_dir "$DIR_SELFHOSTED" self-hosted
seed_install_dir "$DIR_EXTERNAL" external
mkdir -p "$DIR_EMPTY"

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
expect_success_containing "backup --dry-run (self-hosted) lista o volume postgres_data" \
  "volume: postgres_data" backup --dir "$DIR_SELFHOSTED" --dry-run -y

expect_success_containing "backup --dry-run (external) avisa que o Postgres não entra no backup" \
  "banco externo" backup --dir "$DIR_EXTERNAL" --dry-run -y

expect_failure_containing "backup sem instalação existente morre" \
  "Nenhuma instalação encontrada" backup --dir "$DIR_EMPTY" --dry-run -y

# nada deve ser escrito em disco por um --dry-run
[ ! -d "$DIR_SELFHOSTED/backups" ] \
  && { printf 'ok   - backup --dry-run não cria %s/backups\n' "$DIR_SELFHOSTED"; PASS=$((PASS + 1)); } \
  || { printf 'FAIL - backup --dry-run criou %s/backups\n' "$DIR_SELFHOSTED"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# upgrade
# ---------------------------------------------------------------------------
expect_success_containing "upgrade --dry-run mostra a transição de tag" \
  "v1.0.0 → v2.0.0" upgrade --dir "$DIR_SELFHOSTED" --tag v2.0.0 --dry-run -y

expect_failure_containing "upgrade sem instalação existente morre" \
  "Nenhuma instalação encontrada" upgrade --dir "$DIR_EMPTY" --tag v2.0.0 --dry-run -y

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------
expect_failure_containing "restore de arquivo inexistente morre com mensagem clara" \
  "Arquivo de backup não encontrado" restore /caminho/que/nao/existe.tgz --dir "$DIR_SELFHOSTED" --dry-run -y

expect_failure_containing "restore sem argumento morre pedindo o arquivo" \
  "Uso: olt-install.sh restore" restore --dir "$DIR_SELFHOSTED" --dry-run -y

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
expect_success_containing "uninstall --dry-run sem --purge preserva volumes (mensagem)" \
  "volumes e dados preservados" uninstall --dir "$DIR_SELFHOSTED" --dry-run -y

CONFIG_NONINTERACTIVE="$TMPROOT/purge.answers"
: > "$CONFIG_NONINTERACTIVE"
expect_failure_containing "uninstall --purge em modo não-interativo recusa e morre" \
  "exige confirmação interativa" uninstall --purge --dir "$DIR_SELFHOSTED" -c "$CONFIG_NONINTERACTIVE"

expect_failure_containing "uninstall sem instalação existente morre" \
  "Nenhuma instalação encontrada" uninstall --dir "$DIR_EMPTY" --dry-run -y

# ---------------------------------------------------------------------------
printf '\n%s/%s testes passaram.\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
