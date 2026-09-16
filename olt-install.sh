#!/usr/bin/env bash
# olt-install.sh — instalador de produção do OLT System (backend olt_system +
# frontend olt_web + Postgres opcional). Script auto-contido: o
# docker-compose.prod.yml real de olt_docker vem embutido abaixo (gerado por
# scripts/sync-installer.sh) — não é necessário clonar nenhum repositório no
# servidor de destino, só copiar este arquivo.
#
# Padrões e decisões de arquitetura estão em docs/INSTALLER_KB.md.
# Comandos: install, doctor, upgrade, backup, restore, uninstall.
set -Eeuo pipefail
umask 077

INSTALLER_VERSION="0.1.0"
IMAGE_REPO_NS="ghcr.io/dieg0clima"
DEFAULT_INSTALL_DIR="/opt/olt-system"
DEFAULT_DISK_MB=1024

# ---------------------------------------------------------------------------
# Estado global (com defaults seguros sob `set -u`)
# ---------------------------------------------------------------------------
: "${INSTALL_DIR:=$DEFAULT_INSTALL_DIR}"
: "${IMAGE_TAG:=}"
: "${OLT_SYSTEM_HOST:=}"
: "${OLT_SYSTEM_CORS_ORIGINS:=}"
: "${OLT_WEB_API_BASE_URL:=}"
: "${OLT_WEB_HTTP_PORT:=}"
: "${OLT_SYSTEM_WEB_PORT:=}"
: "${DB_MODE:=}"
: "${OLT_SYSTEM_DB_HOST:=}"
: "${OLT_SYSTEM_DB_PORT:=}"
: "${OLT_SYSTEM_DB_USER:=}"
: "${OLT_SYSTEM_DB_PASSWORD:=}"
: "${OLT_SYSTEM_DB_NAME:=}"
: "${OLT_SYSTEM_SECRET_KEY_BASE:=}"
: "${OLT_SYSTEM_ENCRYPTION_KEY:=}"
: "${OLT_SYSTEM_ADMIN_EMAIL:=}"
: "${OLT_SYSTEM_ADMIN_PASSWORD:=}"
: "${QUIET:=no}"
: "${VERBOSE:=no}"
: "${DRY_RUN:=no}"
: "${ASSUME_YES:=no}"
: "${NON_INTERACTIVE:=no}"
NEW_SECRETS=""
OS_ID=""
OS_VER=""
ARCH=""
COMPOSE=()
COMMAND=""
CONFIG_FILE=""
NO_START=no
PURGE=no
RESTORE_FILE=""
BACKUP_HELPER_IMAGE="alpine:3"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

log()   { [ "$QUIET" = yes ] || printf '%b\n' "$*"; }
ok()    { [ "$QUIET" = yes ] || printf '%b\n' "${C_GREEN}✔${C_RESET} $*"; }
warn()  { printf '%b\n' "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()   { printf '%b\n' "${C_RED}✘${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { [ "$QUIET" = yes ] || printf '%s\n' "────────────────────────────────────────────────────────────"; }
debug() { [ "$VERBOSE" = yes ] && printf '%b\n' "${C_DIM}[debug]${C_RESET} $*" >&2 || true; }

# fail_or_warn MSG — die() em execução real; warn() (e continua) sob --dry-run,
# para que o dry-run funcione mesmo sem root/login no registry/portas livres.
fail_or_warn() {
  local msg="$1"
  if [ "$DRY_RUN" = yes ]; then
    warn "${msg} (--dry-run: continuando mesmo assim)"
    return 0
  fi
  die "$msg"
}

# ---------------------------------------------------------------------------
# run() / write_file() / run_in_dir() — dry-run aware
# ---------------------------------------------------------------------------
run() {
  if [ "$DRY_RUN" = yes ]; then
    printf '  %b[dry-run]%b %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

write_file() {
  # write_file PATH [MODE] — conteúdo vem de stdin
  local path="$1" mode="${2:-644}"
  if [ "$DRY_RUN" = yes ]; then
    printf '  %b[dry-run]%b escreveria %s (mode %s):\n' "$C_DIM" "$C_RESET" "$path" "$mode"
    sed 's/^/      | /'
    return 0
  fi
  install -m "$mode" /dev/null "$path"
  cat > "$path"
}

run_in_dir() {
  # run_in_dir DIR CMD... — como run(), mas primeiro entra em DIR. Sob
  # --dry-run nem tenta o `cd` de verdade: em instalação nova o diretório
  # ainda não existe (foi só "simulado" por write_file/run), então um `cd`
  # real quebraria o dry-run.
  local dir="$1"
  shift
  if [ "$DRY_RUN" = yes ]; then
    printf '  %b[dry-run]%b (cd %s && %s)\n' "$C_DIM" "$C_RESET" "$dir" "$*"
    return 0
  fi
  ( cd "$dir" && "$@" )
}

# ---------------------------------------------------------------------------
# ask() / confirm() / validadores
# ---------------------------------------------------------------------------
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __ans
  if [ "$NON_INTERACTIVE" = yes ]; then
    local cur="${!__var:-}"
    printf -v "$__var" '%s' "${cur:-$__default}"
    return 0
  fi
  if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
    die "Sem terminal disponível para perguntar '${__prompt}'. Use --config/-c ou -y."
  fi
  if [ -n "$__default" ]; then
    printf '%b?%b %s %b[%s]%b: ' "$C_BOLD" "$C_RESET" "$__prompt" "$C_DIM" "$__default" "$C_RESET" >&2
  else
    printf '%b?%b %s: ' "$C_BOLD" "$C_RESET" "$__prompt" >&2
  fi
  IFS= read -r __ans </dev/tty || die "Entrada interrompida (EOF). Use --config para modo não-interativo."
  [ -z "$__ans" ] && __ans="$__default"
  printf -v "$__var" '%s' "$__ans"
}

ask_valid() {
  # ask_valid VAR "prompt" "default" validador "msg de erro"
  local var="$1" prompt="$2" def="$3" fn="$4" msg="$5"
  while :; do
    ask "$var" "$prompt" "$def"
    "$fn" "${!var}" && return 0
    warn "$msg"
    [ "$NON_INTERACTIVE" = yes ] && die "Valor inválido para $var em modo não-interativo (recebido: '${!var}')."
  done
}

confirm() {
  # confirm "pergunta" default(s|n) -> 0 se sim
  local prompt="$1" def="${2:-n}" ans
  [ "$ASSUME_YES" = yes ] && return 0
  if [ "$NON_INTERACTIVE" = yes ]; then
    [ "$def" = s ] && return 0
    return 1
  fi
  [ -e /dev/tty ] || die "Sem terminal para confirmar '${prompt}'. Use -y."
  local hint="s/N"
  [ "$def" = s ] && hint="S/n"
  printf '%b?%b %s %b[%s]%b: ' "$C_BOLD" "$C_RESET" "$prompt" "$C_DIM" "$hint" "$C_RESET" >&2
  IFS= read -r ans </dev/tty || die "Entrada interrompida (EOF)."
  [ -z "$ans" ] && ans="$def"
  case "$ans" in [sSyY]*) return 0 ;; *) return 1 ;; esac
}

is_port()      { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_url()       { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
is_email()     { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]]; }
is_nonempty()  { [ -n "$1" ]; }
is_image_tag() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_db_mode()   { [ "$1" = external ] || [ "$1" = self-hosted ]; }

# ---------------------------------------------------------------------------
# .env: leitura, segredos idempotentes, escrita atômica
# ---------------------------------------------------------------------------
env_get() {
  local key="$1" file="${2:-$INSTALL_DIR/.env}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

gen_hex() { openssl rand -hex "${1:-32}"; }

gen_alnum() {
  local n="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"
  printf '\n'
}

# gen_b64 N — N bytes aleatórios em base64 padrão (não url-safe). Usado só para
# OLT_SYSTEM_ENCRYPTION_KEY: `Persistence.Vault` (olt_system) espera
# `Base.decode64!/1` de 32 bytes crus — nem gen_hex (hex, não base64) nem gen_alnum
# (não é base64 válido em geral) servem aqui.
gen_b64() { openssl rand -base64 "${1:-32}"; }

secret_or_keep() {
  # secret_or_keep VAR gerador...  — usa: env atual → .env existente → gera novo
  local var="$1"; shift
  local cur="${!var:-}"
  [ -z "$cur" ] && cur="$(env_get "$var" || true)"
  if [ -z "$cur" ]; then
    cur="$("$@")"
    NEW_SECRETS="${NEW_SECRETS} ${var}"
  fi
  printf -v "$var" '%s' "$cur"
}

env_lines() {
  cat <<EOF
COMPOSE_PROJECT_NAME=olt-system
IMAGE_TAG=${IMAGE_TAG}
OLT_SYSTEM_IMAGE=${IMAGE_REPO_NS}/olt_system:${IMAGE_TAG}
OLT_WEB_IMAGE=${IMAGE_REPO_NS}/olt_web:${IMAGE_TAG}
OLT_SYSTEM_SECRET_KEY_BASE=${OLT_SYSTEM_SECRET_KEY_BASE}
OLT_SYSTEM_ENCRYPTION_KEY=${OLT_SYSTEM_ENCRYPTION_KEY}
OLT_SYSTEM_ADMIN_EMAIL=${OLT_SYSTEM_ADMIN_EMAIL}
OLT_SYSTEM_ADMIN_PASSWORD=${OLT_SYSTEM_ADMIN_PASSWORD}
OLT_SYSTEM_HOST=${OLT_SYSTEM_HOST}
OLT_SYSTEM_CORS_ORIGINS=${OLT_SYSTEM_CORS_ORIGINS}
OLT_SYSTEM_WEB_PORT=${OLT_SYSTEM_WEB_PORT}
OLT_SYSTEM_DB_HOST=${OLT_SYSTEM_DB_HOST}
OLT_SYSTEM_DB_PORT=${OLT_SYSTEM_DB_PORT}
OLT_SYSTEM_DB_USER=${OLT_SYSTEM_DB_USER}
OLT_SYSTEM_DB_PASSWORD=${OLT_SYSTEM_DB_PASSWORD}
OLT_SYSTEM_DB_NAME=${OLT_SYSTEM_DB_NAME}
OLT_WEB_API_BASE_URL=${OLT_WEB_API_BASE_URL}
OLT_WEB_HTTP_PORT=${OLT_WEB_HTTP_PORT}
EOF
  # `if` de verdade, não `[ cond ] && printf ...` — sob `set -e`, um `&&` cujo lado
  # esquerdo é falso e não tem `|| true` vira o ÚLTIMO comando da função com status
  # 1, e esse status vaza pro caller (aqui, `env_lines | sed ...` em write_env,
  # onde `pipefail` faz a pipeline inteira "falhar" mesmo sem nada de errado
  # acontecer de verdade). Achado real rodando `install --dry-run` no modo
  # 'external' (onde a condição é falsa de propósito).
  if [ "$DB_MODE" = self-hosted ]; then
    printf 'COMPOSE_PROFILES=self-hosted-db\n'
  fi
}

write_env() {
  local envf="$INSTALL_DIR/.env" tmp
  if [ "$DRY_RUN" = yes ]; then
    printf '  %b[dry-run]%b escreveria %s (mode 600):\n' "$C_DIM" "$C_RESET" "$envf"
    env_lines | sed 's/^/      | /'
    return 0
  fi
  tmp="$(mktemp "${envf}.XXXXXX")"
  chmod 600 "$tmp"
  {
    printf '# .env — olt-system (gerado em %s pelo olt-install.sh %s)\n' "$(date -u +%FT%TZ)" "$INSTALLER_VERSION"
    printf '# Contém SEGREDOS. chmod 600. Não versionar. Fazer backup seguro.\n\n'
    env_lines
  } > "$tmp"
  [ -f "$envf" ] && cp -a "$envf" "${envf}.bak.$(date +%Y%m%d%H%M%S)"
  mv -f "$tmp" "$envf"
  chmod 600 "$envf"
  ok ".env escrito em $envf"
}

# ---------------------------------------------------------------------------
# Parser seguro de --config (KEY=VALUE, sem `source`, whitelist de chaves)
# ---------------------------------------------------------------------------
OLT_CONFIG_KEYS=(
  INSTALL_DIR IMAGE_TAG OLT_SYSTEM_HOST OLT_SYSTEM_WEB_PORT OLT_SYSTEM_CORS_ORIGINS
  OLT_WEB_API_BASE_URL OLT_WEB_HTTP_PORT DB_MODE OLT_SYSTEM_DB_HOST
  OLT_SYSTEM_DB_PORT OLT_SYSTEM_DB_USER OLT_SYSTEM_DB_PASSWORD OLT_SYSTEM_DB_NAME
  OLT_SYSTEM_ADMIN_EMAIL
)

is_known_config_key() {
  local k="$1" known
  for known in "${OLT_CONFIG_KEYS[@]}"; do
    [ "$k" = "$known" ] && return 0
  done
  return 1
}

load_config_file() {
  local file="$1" line key val
  [ -f "$file" ] || die "Arquivo de config não encontrado: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) warn "Ignorando linha inválida em $file: $line"; continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      warn "Ignorando chave inválida em $file: '$key'"
      continue
    fi
    if ! is_known_config_key "$key"; then
      warn "Ignorando chave desconhecida em $file: '$key'"
      continue
    fi
    printf -v "$key" '%s' "$val"
  done < "$file"
  ok "Config carregada de $file"
}

# ---------------------------------------------------------------------------
# Pré-flight
# ---------------------------------------------------------------------------

# detect_primary_ip — primeiro IPv4 "de verdade" da máquina (filtra pontes do
# Docker/libvirt/VPN), usado só para PRÉ-PREENCHER OLT_SYSTEM_HOST — o operador
# sempre vê e confirma o valor.
detect_primary_ip() {
  ip -4 -o addr show scope global 2>/dev/null \
    | grep -vE ' (docker[0-9]*|br-[0-9a-f]+|veth[0-9a-f]*|virbr[0-9]*|tun[0-9]*) ' \
    | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

who_listens() {
  local port="$1" proto="${2:-tcp}" flag
  case "$proto" in udp) flag=-lunp ;; *) flag=-ltnp ;; esac
  ss "$flag" 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p { for (i=1;i<=NF;i++) if ($i ~ /users:/) { print $i; exit } }' || true
}

check_port_free() {
  local port="$1" proto="$2" label="${3:-}" owner
  owner="$(who_listens "$port" "$proto")"
  if [ -n "$owner" ]; then
    err "Porta ${port}/${proto}${label:+ ($label)} já em uso por: ${owner}"
    return 1
  fi
  ok "Porta ${port}/${proto}${label:+ ($label)} livre."
}

detect_os() {
  [ -r /etc/os-release ] || die "Não consegui ler /etc/os-release."
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-desconhecido}"
  OS_VER="${VERSION_ID:-}"
  case "$OS_ID" in
    ubuntu | debian | rocky | almalinux | rhel | centos | fedora) ;;
    *) warn "SO não homologado: ${OS_ID} ${OS_VER}. Prosseguindo por sua conta." ;;
  esac
  ok "Sistema: ${OS_ID} ${OS_VER}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "Arquitetura não suportada: $(uname -m)" ;;
  esac
  ok "Arquitetura: ${ARCH}"
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    die "Encontrado docker-compose v1 (EOL, ignora 'depends_on: condition'). Instale o plugin Compose v2:
  apt-get install docker-compose-plugin      # Debian/Ubuntu
  dnf install docker-compose-plugin          # RHEL/Rocky"
  else
    die "Docker Compose não encontrado."
  fi
  ok "Compose: $(docker compose version --short 2>/dev/null || echo v2)"
}

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}' || true; }

check_disk() {
  local path="$1" need_mb="$2" probe="$1" have
  if [ "$DRY_RUN" = yes ]; then
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
  else
    mkdir -p "$path" 2>/dev/null || true
    probe="$path"
  fi
  have="$(free_mb "$probe")"
  if [ -z "$have" ]; then
    warn "Não consegui medir espaço em $probe"
    return 0
  fi
  if [ "$have" -lt "$need_mb" ]; then
    fail_or_warn "Espaço insuficiente em $probe: ${have}MB livres, precisa de ${need_mb}MB."
    return 0
  fi
  ok "Espaço em disco OK em $probe (${have}MB livres, requisito ${need_mb}MB)."
}

check_registry() {
  local image="$1"
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    ok "Acesso ao registry OK (${image})."
    return 0
  fi
  fail_or_warn "Não consegui acessar ${image}. Rode 'docker login ghcr.io -u <usuario>' (token com escopo read:packages) antes de instalar e confirme que a tag existe."
}

check_postgres_reachable() {
  # Só usado no modo 'external' — não faz sentido pro self-hosted (o container
  # ainda nem existe no pré-flight).
  local host="$1" port="$2"
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -h "$host" -p "$port" -t 5 >/dev/null 2>&1 && { ok "Postgres externo alcançável em ${host}:${port}."; return 0; }
    fail_or_warn "Não consegui alcançar o Postgres externo em ${host}:${port} (pg_isready)."
    return 0
  fi
  # Sem pg_isready instalado no host: TCP connect simples via /dev/tcp do bash.
  if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
    exec 3<&- 3>&-
    ok "Porta TCP ${host}:${port} alcançável (pg_isready ausente — checagem só de porta)."
  else
    fail_or_warn "Não consegui conectar em ${host}:${port} (Postgres externo)."
  fi
}

# ---------------------------------------------------------------------------
# Validação pós-instalação
# ---------------------------------------------------------------------------
check_http() {
  local url="$1" label="$2"
  if curl -fsS --max-time 5 -o /dev/null "$url"; then
    ok "${label} respondendo em ${url}"
    return 0
  fi
  err "${label} não respondeu em ${url}"
  return 1
}

wait_healthy() {
  # `docker inspect` de um container inexistente imprime uma linha vazia em
  # stdout ANTES de errar — por isso a existência é checada à parte, como
  # comando booleano, não por texto.
  local svc="$1" timeout="${2:-120}" waited=0 st
  while [ "$waited" -lt "$timeout" ]; do
    if ! docker inspect "$svc" >/dev/null 2>&1; then
      err "Container ${svc} não encontrado."
      return 1
    fi
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' "$svc" 2>/dev/null)"
    case "$st" in
      healthy | sem-healthcheck)
        ok "${svc} está ${st} (${waited}s)."
        return 0
        ;;
      unhealthy)
        err "${svc} reportou unhealthy."
        docker logs --tail 50 "$svc" 2>&1 | sed 's/^/    | /' >&2 || true
        return 1
        ;;
    esac
    sleep 3
    waited=$((waited + 3))
    [ "$QUIET" = yes ] || printf '\r  aguardando %s… %ss' "$svc" "$waited" >&2
  done
  [ "$QUIET" = yes ] || printf '\n' >&2
  err "Timeout esperando ${svc} ficar saudável."
  docker logs --tail 80 "$svc" 2>&1 | sed 's/^/    | /' >&2 || true
  return 1
}

# ---------------------------------------------------------------------------
# Modo de banco → containers/volumes da stack
# ---------------------------------------------------------------------------
containers_for_mode() {
  printf '%s\n' olt_system_api olt_system_web
  [ "$DB_MODE" = self-hosted ] && printf '%s\n' olt_system_db
  return 0
}

# volume insubstituível por modo — de propósito NÃO inclui nada efêmero (não há
# cache/runtime nesta stack fora do próprio Postgres).
volumes_for_mode() {
  [ "$DB_MODE" = self-hosted ] && printf '%s\n' postgres_data
  return 0
}

# resolve_compose_project_name — Docker Compose prefixa nome de volume com o
# "nome do projeto" — perguntamos ao próprio Compose em vez de reimplementar a
# lógica de sanitização dele. Funciona tanto para instalações que fixam
# COMPOSE_PROJECT_NAME no .env quanto para as que não fixam.
resolve_compose_project_name() {
  local out
  out="$(cd "$INSTALL_DIR" && "${COMPOSE[@]}" config --format json 2>/dev/null)" || true
  printf '%s' "$out" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -n1
}

# manifest_get KEY FILE — parser mínimo do manifest.json plano que a gente
# mesmo gera em do_backup() (uma chave "string" por linha). Sem depender de
# jq, que não está na lista de comandos obrigatórios do instalador.
manifest_get() {
  local key="$1" file="$2"
  sed -n "s/.*\"${key}\": *\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
}

# infer_db_mode_from_env — usado por upgrade/backup/uninstall/doctor: lê o modo
# de banco de uma instalação existente a partir do .env, sem perguntar de novo.
infer_db_mode_from_env() {
  case "$(env_get COMPOSE_PROFILES)" in
    *self-hosted-db*) DB_MODE=self-hosted ;;
    *) DB_MODE=external ;;
  esac
}

# run_migration — roda Web.Release.migrate/0 (ADR 0031-release-de-producao.md,
# olt_system) dentro do container `api` já em pé. Idempotente (Ecto.Migrator não
# faz nada se já estiver tudo aplicado) — seguro chamar em install e upgrade sem
# distinguir "banco novo" de "banco existente". Retry curto porque logo depois de
# `up -d` o container pode levar um instante a aceitar `exec`.
run_migration() {
  local tries=0
  while [ "$tries" -lt 10 ]; do
    if run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" exec -T api bin/olt_system eval "Web.Release.migrate()"; then
      ok "Migração do banco aplicada."
      return 0
    fi
    tries=$((tries + 1))
    sleep 3
  done
  return 1
}

# run_seed — roda Web.Release.seed/0 (bootstrap do admin + catálogo de OIDs SNMP) —
# só faz sentido DEPOIS de run_migration ter sucesso (schema precisa existir antes
# do boot normal da app usar os repos). Também idempotente, seguro chamar sempre.
#
# `rpc`, não `eval` — achado real testando contra um container de verdade: `eval`
# roda em uma VM nova, não-booted (código carregado, mas a árvore de supervisão da
# aplicação nunca sobe), então `Auth.Repo`/`Persistence.Repo` não existem nesse
# contexto (`RuntimeError: could not lookup Ecto repo`). `rpc` executa no NÓ JÁ
# RODANDO (o processo principal do container, subido via `bin/olt_system start`),
# onde os repos já estão supervisionados de verdade — só isso resolve. `migrate/0`
# continua via `eval` de propósito: `Ecto.Migrator.with_repo/2` sobe sua própria
# conexão isolada, funciona igual com ou sem a app já rodando.
run_seed() {
  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" exec -T api bin/olt_system rpc "Web.Release.seed()"
}

do_backup() {
  [ -f "$INSTALL_DIR/.env" ] || die "Nenhuma instalação encontrada em $INSTALL_DIR."
  infer_db_mode_from_env

  local ts backup_dir tarball
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$INSTALL_DIR/backups"
  tarball="${backup_dir}/olt-system-backup-${ts}.tgz"

  if [ "$DRY_RUN" = yes ]; then
    log "  ${C_DIM}[dry-run]${C_RESET} geraria ${tarball} contendo: .env, docker-compose.yml, manifest.json"
    if [ "$DB_MODE" = self-hosted ]; then
      log "    - volume: postgres_data"
    else
      log "    - (banco externo: dados do Postgres NÃO entram neste backup)"
    fi
    return 0
  fi

  mkdir -p "$backup_dir"
  local stage
  stage="$(mktemp -d)"

  cp "$INSTALL_DIR/.env" "$stage/.env"
  cp "$INSTALL_DIR/docker-compose.yml" "$stage/docker-compose.yml"
  cat > "$stage/manifest.json" <<EOF
{
  "installer_version": "${INSTALLER_VERSION}",
  "db_mode": "${DB_MODE}",
  "image_tag": "$(env_get IMAGE_TAG)",
  "hostname": "$(hostname 2>/dev/null || echo desconhecido)",
  "install_dir": "${INSTALL_DIR}",
  "created_at": "$(date -u +%FT%TZ)"
}
EOF

  if [ "$DB_MODE" = self-hosted ]; then
    detect_compose
    local project_name real_vol
    project_name="$(resolve_compose_project_name)"
    [ -n "$project_name" ] || warn "Não consegui resolver o nome do projeto Compose — tentando o volume sem prefixo."
    real_vol="postgres_data"
    [ -n "$project_name" ] && real_vol="${project_name}_postgres_data"
    if docker volume inspect "$real_vol" >/dev/null 2>&1; then
      docker run --rm -v "${real_vol}:/src:ro" -v "${stage}:/dst" "$BACKUP_HELPER_IMAGE" \
          sh -c "tar czf /dst/postgres_data.tgz -C /src ." \
        || warn "Falha ao arquivar o volume ${real_vol} — continuando sem ele."
    else
      warn "Volume ${real_vol} não existe — pulando."
    fi
  else
    warn "Banco externo: este backup NÃO inclui dados do Postgres — administrar o backup do banco externo é responsabilidade de quem o opera."
  fi

  tar czf "$tarball" -C "$stage" .
  rm -rf "$stage"
  chmod 600 "$tarball"
  ok "Backup salvo em ${tarball}"
}

# post_up_validate — mesma checagem usada por install, upgrade e restore depois
# de subir a stack. Não altera DB_MODE/INSTALL_DIR.
post_up_validate() {
  local c overall_ok=yes
  while IFS= read -r c; do
    wait_healthy "$c" 120 || overall_ok=no
  done < <(containers_for_mode)
  check_http "${OLT_WEB_API_BASE_URL}/health" "api" || overall_ok=no
  check_http "http://127.0.0.1:${OLT_WEB_HTTP_PORT:-80}/" "web" || overall_ok=no
  [ "$overall_ok" = yes ]
}

# ---------------------------------------------------------------------------
# docker-compose.prod.yml embutido — GERADO por scripts/sync-installer.sh a
# partir do repo-fonte real (olt_docker/docker-compose.prod.yml). NÃO EDITE este
# bloco à mão: edite o docker-compose.prod.yml de olt_docker e rode
# scripts/sync-installer.sh de novo.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034 # lido em cmd_install/cmd_upgrade/cmd_restore
# >>> OLT:PROD:BEGIN
COMPOSE_PROD=$(cat <<'OLT_COMPOSE_EOF'
# Fonte da verdade do compose de produção — embutido em olt-install.sh por
# ../olt_installer/scripts/sync-installer.sh (NUNCA editar o bloco embutido lá, editar
# aqui e rodar o sync). Ver ADR 0031-release-de-producao.md (olt_system) e
# docs/INSTALLER_KB.md (olt_installer) para o raciocínio completo.
#
# `db` fica atrás de `profiles: ["self-hosted-db"]` de propósito (nunca dois arquivos
# de compose quase-iguais) — só sobe quando `.env` tem `COMPOSE_PROFILES=self-hosted-db`
# (instalação sem Postgres próprio). Com um Postgres externo, `api` só lê
# OLT_SYSTEM_DB_HOST/etc apontando pra fora, e este serviço nunca é criado.
services:
  api:
    image: "${OLT_SYSTEM_IMAGE:?set OLT_SYSTEM_IMAGE}"
    pull_policy: always
    container_name: olt_system_api
    restart: unless-stopped
    environment:
      OLT_SYSTEM_WEB_PORT: "4000"
      OLT_SYSTEM_SECRET_KEY_BASE: "${OLT_SYSTEM_SECRET_KEY_BASE:?set OLT_SYSTEM_SECRET_KEY_BASE}"
      OLT_SYSTEM_HOST: "${OLT_SYSTEM_HOST:?set OLT_SYSTEM_HOST}"
      OLT_SYSTEM_CORS_ORIGINS: "${OLT_SYSTEM_CORS_ORIGINS:?set OLT_SYSTEM_CORS_ORIGINS}"
      OLT_SYSTEM_ENCRYPTION_KEY: "${OLT_SYSTEM_ENCRYPTION_KEY:?set OLT_SYSTEM_ENCRYPTION_KEY}"
      OLT_SYSTEM_DB_HOST: "${OLT_SYSTEM_DB_HOST:?set OLT_SYSTEM_DB_HOST}"
      OLT_SYSTEM_DB_PORT: "${OLT_SYSTEM_DB_PORT:-5432}"
      OLT_SYSTEM_DB_USER: "${OLT_SYSTEM_DB_USER:?set OLT_SYSTEM_DB_USER}"
      OLT_SYSTEM_DB_PASSWORD: "${OLT_SYSTEM_DB_PASSWORD:?set OLT_SYSTEM_DB_PASSWORD}"
      OLT_SYSTEM_DB_NAME: "${OLT_SYSTEM_DB_NAME:?set OLT_SYSTEM_DB_NAME}"
      OLT_SYSTEM_DB_POOL_SIZE: "${OLT_SYSTEM_DB_POOL_SIZE:-10}"
      # Lidas só por apps/auth/priv/repo/seeds.exs (Web.Release.seed/0, olt_installer)
      # — nunca pelo boot normal do Endpoint. Sem default aqui de propósito: o
      # fallback "change-me-in-production" do próprio seeds.exs é só pra dev, o
      # instalador sempre gera/pergunta um valor real.
      OLT_SYSTEM_ADMIN_EMAIL: "${OLT_SYSTEM_ADMIN_EMAIL:?set OLT_SYSTEM_ADMIN_EMAIL}"
      OLT_SYSTEM_ADMIN_PASSWORD: "${OLT_SYSTEM_ADMIN_PASSWORD:?set OLT_SYSTEM_ADMIN_PASSWORD}"
    ports:
      - "${OLT_SYSTEM_WEB_PORT:-4000}:4000"

  web:
    image: "${OLT_WEB_IMAGE:?set OLT_WEB_IMAGE}"
    pull_policy: always
    container_name: olt_system_web
    restart: unless-stopped
    environment:
      OLT_WEB_API_BASE_URL: "${OLT_WEB_API_BASE_URL:?set OLT_WEB_API_BASE_URL}"
    ports:
      - "${OLT_WEB_HTTP_PORT:-80}:80"

  db:
    profiles: ["self-hosted-db"]
    image: postgres:16-alpine
    container_name: olt_system_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${OLT_SYSTEM_DB_USER:?set OLT_SYSTEM_DB_USER}"
      POSTGRES_PASSWORD: "${OLT_SYSTEM_DB_PASSWORD:?set OLT_SYSTEM_DB_PASSWORD}"
      POSTGRES_DB: "${OLT_SYSTEM_DB_NAME:?set OLT_SYSTEM_DB_NAME}"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${OLT_SYSTEM_DB_USER:-postgres}"]
      interval: 5s
      timeout: 5s
      retries: 10
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
OLT_COMPOSE_EOF
)
# <<< OLT:PROD:END

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
cmd_install() {
  detect_os
  detect_arch
  detect_compose

  case "$COMPOSE_PROD" in
    *PLACEHOLDER*) die "Bloco de compose ainda não foi gerado. Rode: scripts/sync-installer.sh" ;;
  esac

  ask_valid INSTALL_DIR "Diretório de instalação" "$INSTALL_DIR" is_nonempty "Informe um caminho."
  ask_valid IMAGE_TAG "Tag das imagens olt_system/olt_web (ex.: v1.0.0, latest)" "${IMAGE_TAG:-latest}" is_image_tag "Use apenas letras, números, '.', '_' e '-'."

  local detected_ip
  detected_ip="$(detect_primary_ip)"
  if [ -n "$detected_ip" ]; then
    log "IP detectado para pré-preenchimento: ${detected_ip}"
  else
    detected_ip="localhost"
    warn "Não consegui detectar um IPv4 do host — usando 'localhost' como default. Ajuste se a instalação precisar ser acessada de fora desta máquina."
  fi
  ask_valid OLT_SYSTEM_HOST "Host/IP público desta instalação" "${OLT_SYSTEM_HOST:-$detected_ip}" is_nonempty "Informe um host ou IP."
  ask_valid OLT_SYSTEM_WEB_PORT "Porta HTTP da API, publicada no host" "${OLT_SYSTEM_WEB_PORT:-4000}" is_port "Informe uma porta válida (1-65535)."
  ask_valid OLT_WEB_API_BASE_URL "URL pública da API (o navegador do operador vai chamar isto)" "${OLT_WEB_API_BASE_URL:-http://${OLT_SYSTEM_HOST}:${OLT_SYSTEM_WEB_PORT}}" is_url "Informe uma URL http(s)://..."
  ask_valid OLT_SYSTEM_CORS_ORIGINS "Origem do frontend, permitida por CORS" "${OLT_SYSTEM_CORS_ORIGINS:-http://${OLT_SYSTEM_HOST}}" is_nonempty "Informe ao menos uma origem (ex.: http://${OLT_SYSTEM_HOST})."
  ask_valid OLT_WEB_HTTP_PORT "Porta HTTP do frontend" "${OLT_WEB_HTTP_PORT:-80}" is_port "Informe uma porta válida (1-65535)."

  ask_valid DB_MODE "Banco de dados — 'external' (já tenho um Postgres) ou 'self-hosted' (subir um container)" "${DB_MODE:-external}" is_db_mode "Digite 'external' ou 'self-hosted'."

  if [ "$DB_MODE" = external ]; then
    ask_valid OLT_SYSTEM_DB_HOST "Host do Postgres externo" "${OLT_SYSTEM_DB_HOST:-}" is_nonempty "Informe o host do Postgres."
    ask_valid OLT_SYSTEM_DB_PORT "Porta do Postgres externo" "${OLT_SYSTEM_DB_PORT:-5432}" is_port "Informe uma porta válida."
    ask_valid OLT_SYSTEM_DB_USER "Usuário do Postgres" "${OLT_SYSTEM_DB_USER:-olt_system}" is_nonempty "Informe o usuário."
    ask_valid OLT_SYSTEM_DB_NAME "Nome do banco" "${OLT_SYSTEM_DB_NAME:-olt_system_prod}" is_nonempty "Informe o nome do banco."
    ask OLT_SYSTEM_DB_PASSWORD "Senha do Postgres" "${OLT_SYSTEM_DB_PASSWORD:-}"
    [ -n "$OLT_SYSTEM_DB_PASSWORD" ] || die "Senha do Postgres não pode ser vazia."
  else
    OLT_SYSTEM_DB_HOST=db
    OLT_SYSTEM_DB_PORT=5432
    OLT_SYSTEM_DB_USER="${OLT_SYSTEM_DB_USER:-olt_system}"
    OLT_SYSTEM_DB_NAME="${OLT_SYSTEM_DB_NAME:-olt_system_prod}"
    secret_or_keep OLT_SYSTEM_DB_PASSWORD gen_alnum 32
  fi

  ask_valid OLT_SYSTEM_ADMIN_EMAIL "E-mail do primeiro usuário administrador" "${OLT_SYSTEM_ADMIN_EMAIL:-admin@olt.local}" is_email "Informe um e-mail válido."

  secret_or_keep OLT_SYSTEM_SECRET_KEY_BASE gen_hex 64
  secret_or_keep OLT_SYSTEM_ENCRYPTION_KEY gen_b64 32
  secret_or_keep OLT_SYSTEM_ADMIN_PASSWORD gen_alnum 24
  if [ -n "$NEW_SECRETS" ]; then
    log "Segredos gerados nesta execução:${NEW_SECRETS}"
  fi

  hr
  log "${C_BOLD}Pré-flight${C_RESET}"
  [ "$(id -u)" -eq 0 ] || fail_or_warn "É necessário rodar como root (ou via sudo)."

  local cmd
  for cmd in docker openssl curl ss; do
    command -v "$cmd" >/dev/null 2>&1 || fail_or_warn "Comando obrigatório ausente: $cmd"
  done
  docker info >/dev/null 2>&1 || fail_or_warn "Docker daemon inacessível. Verifique se o serviço está rodando e se seu usuário está no grupo docker."

  check_disk "$INSTALL_DIR" "$DEFAULT_DISK_MB"

  check_port_free "$OLT_WEB_HTTP_PORT" tcp "web" || fail_or_warn "Porta ${OLT_WEB_HTTP_PORT}/tcp precisa estar livre para o frontend."
  check_port_free "$OLT_SYSTEM_WEB_PORT" tcp "api" || fail_or_warn "Porta ${OLT_SYSTEM_WEB_PORT}/tcp precisa estar livre para a API."

  if [ "$DB_MODE" = self-hosted ]; then
    : # `db` (self-hosted) nunca publica porta pro host (docker-compose.prod.yml) —
      # só é alcançado por `api` na rede interna do Compose, então não há porta 5432
      # do HOST pra checar aqui.
  else
    check_postgres_reachable "$OLT_SYSTEM_DB_HOST" "$OLT_SYSTEM_DB_PORT"
  fi

  check_registry "${IMAGE_REPO_NS}/olt_system:${IMAGE_TAG}"
  check_registry "${IMAGE_REPO_NS}/olt_web:${IMAGE_TAG}"

  hr
  log "${C_BOLD}Revise antes de aplicar:${C_RESET}"
  printf '  %-28s %s\n' "Diretório:" "$INSTALL_DIR"
  printf '  %-28s %s\n' "Tag das imagens:" "$IMAGE_TAG"
  printf '  %-28s %s\n' "Host público:" "$OLT_SYSTEM_HOST"
  printf '  %-28s %s\n' "URL da API:" "$OLT_WEB_API_BASE_URL"
  printf '  %-28s %s\n' "CORS allowed origins:" "$OLT_SYSTEM_CORS_ORIGINS"
  printf '  %-28s %s\n' "Porta da API:" "$OLT_SYSTEM_WEB_PORT"
  printf '  %-28s %s\n' "Porta do frontend:" "$OLT_WEB_HTTP_PORT"
  printf '  %-28s %s\n' "Modo de banco:" "$DB_MODE"
  printf '  %-28s %s:%s\n' "Postgres:" "$OLT_SYSTEM_DB_HOST" "$OLT_SYSTEM_DB_PORT"
  printf '  %-28s %s\n' "E-mail do admin:" "$OLT_SYSTEM_ADMIN_EMAIL"
  hr
  confirm "Aplicar esta configuração?" s || die "Cancelado pelo operador."

  run mkdir -p "$INSTALL_DIR"
  printf '%s\n' "$COMPOSE_PROD" | write_file "$INSTALL_DIR/docker-compose.yml" 644
  write_env

  if [ "$NO_START" = yes ]; then
    ok "Arquivos escritos em $INSTALL_DIR. --no-start: não subindo a stack."
    return 0
  fi

  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" pull
  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" up -d

  if [ "$DRY_RUN" = yes ]; then
    hr
    ok "Simulação (--dry-run) concluída — nada foi escrito ou executado de verdade."
    return 0
  fi

  hr
  log "${C_BOLD}Rodando migração do banco${C_RESET}"
  run_migration || fail_or_warn "Falha ao rodar a migração — investigue com: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs api"

  hr
  log "${C_BOLD}Aplicando dado inicial (admin + catálogo de OIDs)${C_RESET}"
  run_seed || fail_or_warn "Falha ao aplicar o dado inicial — investigue com: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs api"

  hr
  log "${C_BOLD}Aguardando containers ficarem saudáveis e validando${C_RESET}"
  local overall_ok=yes
  post_up_validate || overall_ok=no

  hr
  if [ "$overall_ok" = yes ]; then
    ok "Instalação concluída."
  else
    warn "Instalação concluída com pendências acima — rode './olt-install.sh doctor --dir ${INSTALL_DIR}' para investigar."
  fi
  log "  Frontend:  http://${OLT_SYSTEM_HOST}:${OLT_WEB_HTTP_PORT}/"
  log "  API:       ${OLT_WEB_API_BASE_URL}"
  log "  Login:     ${OLT_SYSTEM_ADMIN_EMAIL}"
  if [[ "$NEW_SECRETS" == *OLT_SYSTEM_ADMIN_PASSWORD* ]]; then
    log "  Senha:     ${OLT_SYSTEM_ADMIN_PASSWORD} ${C_DIM}(gerada agora — troque depois do primeiro login)${C_RESET}"
  else
    log "  Senha:     (preservada de uma instalação anterior — ver ${INSTALL_DIR}/.env)"
  fi
  log "  Segredos:  ${INSTALL_DIR}/.env (chmod 600)"
  hr
}

# ---------------------------------------------------------------------------
# doctor (somente leitura)
# ---------------------------------------------------------------------------
cmd_doctor() {
  # Diagnóstico: nunca deve abortar no meio por causa de um único subcomando
  # falhando — segue reportando o máximo possível.
  set +e

  hr
  log "${C_BOLD}olt-install doctor${C_RESET} — ${INSTALLER_VERSION}"
  log "  Diretório: ${INSTALL_DIR}"
  hr

  if [ ! -f "$INSTALL_DIR/.env" ]; then
    err "Nenhuma instalação encontrada em ${INSTALL_DIR} (.env ausente)."
    set -e
    return 1
  fi

  local perms
  perms="$(stat -c '%a' "$INSTALL_DIR/.env" 2>/dev/null || echo '?')"
  if [ "$perms" = "600" ]; then
    ok ".env com permissão 600."
  else
    warn ".env com permissão ${perms} (esperado 600) — rode: chmod 600 ${INSTALL_DIR}/.env"
  fi

  local key
  for key in OLT_SYSTEM_SECRET_KEY_BASE OLT_SYSTEM_ENCRYPTION_KEY OLT_SYSTEM_ADMIN_EMAIL OLT_SYSTEM_ADMIN_PASSWORD OLT_SYSTEM_CORS_ORIGINS OLT_SYSTEM_DB_HOST; do
    if [ -n "$(env_get "$key")" ]; then
      ok "Chave presente: $key"
    else
      err "Chave ausente ou vazia no .env: $key"
    fi
  done

  infer_db_mode_from_env
  log "Modo de banco inferido: ${DB_MODE}"

  local configured_api configured_port
  configured_api="$(env_get OLT_WEB_API_BASE_URL)"
  [ -n "$configured_api" ] && OLT_WEB_API_BASE_URL="$configured_api"
  configured_port="$(env_get OLT_WEB_HTTP_PORT)"
  [ -n "$configured_port" ] && OLT_WEB_HTTP_PORT="$configured_port"

  hr
  log "${C_BOLD}Containers${C_RESET}"
  local c status restarts health
  while IFS= read -r c; do
    if ! docker inspect "$c" >/dev/null 2>&1; then
      err "Container ${c}: não encontrado"
      continue
    fi
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' "$c" 2>/dev/null)"
    if [ "$status" = running ] && { [ "$health" = healthy ] || [ "$health" = sem-healthcheck ]; }; then
      ok "${c}: ${status} (${health}, restarts=${restarts})"
    else
      err "${c}: ${status} (${health}, restarts=${restarts})"
      docker logs --tail 20 "$c" 2>&1 | sed 's/^/    | /'
    fi
  done < <(containers_for_mode)

  hr
  log "${C_BOLD}HTTP${C_RESET}"
  check_http "${OLT_WEB_API_BASE_URL:-http://127.0.0.1:4000}/health" "api"
  check_http "http://127.0.0.1:${OLT_WEB_HTTP_PORT:-80}/" "web"

  if [ "$DB_MODE" = external ]; then
    hr
    log "${C_BOLD}Postgres externo${C_RESET}"
    check_postgres_reachable "$(env_get OLT_SYSTEM_DB_HOST)" "$(env_get OLT_SYSTEM_DB_PORT)"
  fi

  hr
  log "${C_BOLD}Disco${C_RESET}"
  check_disk "$INSTALL_DIR" 0

  hr
  log "${C_BOLD}Firewall${C_RESET}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "  ufw ativo — confira: ufw status numbered"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "  firewalld ativo — confira: firewall-cmd --list-all"
  else
    log "  nenhum firewall gerenciado detectado."
  fi
  hr

  set -e
}

# ---------------------------------------------------------------------------
# upgrade
# ---------------------------------------------------------------------------
cmd_upgrade() {
  detect_compose
  [ -f "$INSTALL_DIR/.env" ] || die "Nenhuma instalação encontrada em $INSTALL_DIR."
  infer_db_mode_from_env

  local from to
  from="$(env_get IMAGE_TAG)"
  [ -n "$from" ] || die "IMAGE_TAG não encontrado em ${INSTALL_DIR}/.env — instalação corrompida ou de outra ferramenta."
  to="${IMAGE_TAG:-$from}"
  if [ "$from" = "$to" ]; then
    confirm "Já está na tag '${to}'. Reaplicar mesmo assim?" n || die "Cancelado."
  fi
  log "Atualizando ${from} → ${to}"

  check_registry "${IMAGE_REPO_NS}/olt_system:${to}"
  check_registry "${IMAGE_REPO_NS}/olt_web:${to}"

  hr
  log "${C_BOLD}Backup antes do upgrade${C_RESET}"
  do_backup || fail_or_warn "Backup falhou; upgrade abortado (rode 'backup' manualmente e investigue antes de tentar de novo)."

  # Recarrega do .env existente tudo que install pergunta mas upgrade não deve
  # perguntar de novo — só IMAGE_TAG muda.
  OLT_SYSTEM_HOST="$(env_get OLT_SYSTEM_HOST)"
  OLT_SYSTEM_WEB_PORT="$(env_get OLT_SYSTEM_WEB_PORT)"
  OLT_SYSTEM_CORS_ORIGINS="$(env_get OLT_SYSTEM_CORS_ORIGINS)"
  OLT_WEB_API_BASE_URL="$(env_get OLT_WEB_API_BASE_URL)"
  OLT_WEB_HTTP_PORT="$(env_get OLT_WEB_HTTP_PORT)"
  OLT_SYSTEM_DB_HOST="$(env_get OLT_SYSTEM_DB_HOST)"
  OLT_SYSTEM_DB_PORT="$(env_get OLT_SYSTEM_DB_PORT)"
  OLT_SYSTEM_DB_USER="$(env_get OLT_SYSTEM_DB_USER)"
  OLT_SYSTEM_DB_PASSWORD="$(env_get OLT_SYSTEM_DB_PASSWORD)"
  OLT_SYSTEM_DB_NAME="$(env_get OLT_SYSTEM_DB_NAME)"
  OLT_SYSTEM_SECRET_KEY_BASE="$(env_get OLT_SYSTEM_SECRET_KEY_BASE)"
  OLT_SYSTEM_ENCRYPTION_KEY="$(env_get OLT_SYSTEM_ENCRYPTION_KEY)"
  OLT_SYSTEM_ADMIN_EMAIL="$(env_get OLT_SYSTEM_ADMIN_EMAIL)"
  OLT_SYSTEM_ADMIN_PASSWORD="$(env_get OLT_SYSTEM_ADMIN_PASSWORD)"
  IMAGE_TAG="$to"

  printf '%s\n' "$COMPOSE_PROD" | write_file "$INSTALL_DIR/docker-compose.yml" 644
  write_env

  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" pull
  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" up -d --remove-orphans

  if [ "$DRY_RUN" = yes ]; then
    hr
    ok "Simulação (--dry-run) concluída — nada foi escrito ou executado de verdade."
    return 0
  fi

  hr
  log "${C_BOLD}Rodando migração do banco${C_RESET}"
  run_migration || warn "Falha ao rodar a migração — verifique manualmente antes de confiar no upgrade."

  hr
  log "${C_BOLD}Reaplicando dado inicial (catálogo de OIDs)${C_RESET}"
  run_seed || warn "Falha ao aplicar o dado inicial — verifique manualmente."

  hr
  log "${C_BOLD}Validação${C_RESET}"
  if ! post_up_validate; then
    err "Validação falhou após o upgrade."
    if confirm "Reverter para a tag '${from}'?" s; then
      IMAGE_TAG="$from"
      write_env
      run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" up -d
      warn "Revertido para ${from}. Investigue antes de tentar de novo (o backup pré-upgrade está em ${INSTALL_DIR}/backups)."
    fi
    return 1
  fi
  hr
  ok "Upgrade concluído: ${from} → ${to}"
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
cmd_backup() {
  do_backup
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------
cmd_restore() {
  detect_compose
  [ -n "$RESTORE_FILE" ] || die "Uso: olt-install.sh restore ARQUIVO.tgz"
  [ -f "$RESTORE_FILE" ] || die "Arquivo de backup não encontrado: $RESTORE_FILE"

  local stage
  stage="$(mktemp -d)"
  tar xzf "$RESTORE_FILE" -C "$stage" || die "Não consegui extrair ${RESTORE_FILE} (tarball corrompido?)."
  [ -f "$stage/manifest.json" ] || die "manifest.json ausente no backup — arquivo não veio do olt-install.sh."

  local backup_db_mode backup_tag backup_created
  backup_db_mode="$(manifest_get db_mode "$stage/manifest.json")"
  backup_tag="$(manifest_get image_tag "$stage/manifest.json")"
  backup_created="$(manifest_get created_at "$stage/manifest.json")"
  is_db_mode "$backup_db_mode" || die "manifest.json com modo de banco inválido: '${backup_db_mode}'."

  hr
  log "${C_BOLD}Backup a restaurar:${C_RESET}"
  printf '  %-16s %s\n' "Arquivo:" "$RESTORE_FILE"
  printf '  %-16s %s\n' "Modo de banco:" "$backup_db_mode"
  printf '  %-16s %s\n' "Tag da imagem:" "$backup_tag"
  printf '  %-16s %s\n' "Criado em:" "$backup_created"
  printf '  %-16s %s\n' "Destino:" "$INSTALL_DIR"
  hr
  warn "Isto SOBRESCREVE a instalação atual em ${INSTALL_DIR} (se houver uma) com o conteúdo do backup."
  confirm "Restaurar mesmo assim?" n || die "Cancelado pelo operador."

  if [ "$DRY_RUN" = yes ]; then
    log "  ${C_DIM}[dry-run]${C_RESET} restauraria .env, docker-compose.yml e (se self-hosted) o volume postgres_data em ${INSTALL_DIR}."
    rm -rf "$stage"
    return 0
  fi

  if [ -f "$INSTALL_DIR/.env" ]; then
    log "Instalação existente detectada em ${INSTALL_DIR} — fazendo backup dela antes de sobrescrever."
    DB_MODE="$backup_db_mode"
    do_backup || warn "Backup pré-restore falhou — prosseguindo mesmo assim, a pedido do operador."
    run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" down --remove-orphans || true
  fi

  DB_MODE="$backup_db_mode"
  run mkdir -p "$INSTALL_DIR"
  cp "$stage/.env" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  cp "$stage/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"

  if [ "$DB_MODE" = self-hosted ]; then
    local project_name real_vol vol_file
    project_name="$(resolve_compose_project_name)"
    [ -n "$project_name" ] || warn "Não consegui resolver o nome do projeto Compose — criando o volume sem prefixo (o 'docker compose up' seguinte pode não reconhecê-lo)."
    real_vol="postgres_data"
    [ -n "$project_name" ] && real_vol="${project_name}_postgres_data"
    vol_file="$stage/postgres_data.tgz"
    if [ -f "$vol_file" ]; then
      docker volume create "$real_vol" >/dev/null
      docker run --rm -v "${real_vol}:/dst" -v "${stage}:/src:ro" "$BACKUP_HELPER_IMAGE" \
          sh -c "tar xzf /src/postgres_data.tgz -C /dst" \
        || warn "Falha ao restaurar o volume ${real_vol}."
    else
      warn "Backup não tem o volume postgres_data — pulando (o Postgres self-hosted ficará vazio)."
    fi
  fi

  rm -rf "$stage"

  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" up -d

  OLT_WEB_API_BASE_URL="$(env_get OLT_WEB_API_BASE_URL)"
  OLT_WEB_HTTP_PORT="$(env_get OLT_WEB_HTTP_PORT)"

  hr
  log "${C_BOLD}Validação${C_RESET}"
  if post_up_validate; then
    hr
    ok "Restore concluído a partir de ${RESTORE_FILE}."
  else
    hr
    warn "Restore concluído com pendências acima — rode './olt-install.sh doctor --dir ${INSTALL_DIR}' para investigar."
  fi
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
  detect_compose
  [ -f "$INSTALL_DIR/.env" ] || die "Nenhuma instalação encontrada em $INSTALL_DIR."
  infer_db_mode_from_env

  run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" down --remove-orphans

  if [ "$PURGE" != yes ]; then
    if [ "$DRY_RUN" = yes ]; then
      ok "Simulação (--dry-run) concluída — containers seriam removidos, volumes e dados preservados."
    else
      ok "Containers removidos. Volumes e dados preservados (rode com --purge para remover tudo)."
    fi
  else
    err "--purge remove os volumes desta stack. $([ "$DB_MODE" = self-hosted ] && echo 'Isso inclui o Postgres self-hosted (postgres_data).') Isto é IRREVERSÍVEL."
    if [ "$NON_INTERACTIVE" = yes ]; then
      die "--purge exige confirmação interativa — não roda em modo não-interativo (--config)."
    fi
    if [ "$DRY_RUN" = yes ]; then
      log "  ${C_DIM}[dry-run]${C_RESET} pediria confirmação digitada do hostname e depois removeria os volumes."
      ok "Simulação (--dry-run) concluída."
    else
      local hn typed
      hn="$(hostname 2>/dev/null || echo host)"
      ask typed "Digite o hostname (${hn}) para confirmar a remoção definitiva" ""
      [ "$typed" = "$hn" ] || die "Hostname não confere. Abortado (decisão correta)."

      do_backup || warn "Backup automático pré-purge falhou — prosseguindo mesmo assim, a pedido do operador."

      run_in_dir "$INSTALL_DIR" "${COMPOSE[@]}" down -v --remove-orphans
      ok "Volumes removidos."
    fi
  fi

  hr
  ok "Uninstall concluído. ${INSTALL_DIR}/.env e docker-compose.yml preservados (permite reinstalar com os mesmos segredos)."
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
olt-install.sh [COMANDO] [OPÇÕES]

Comandos:
  install             instala a stack olt-system (api + web + Postgres opcional)
  doctor              diagnóstico read-only de uma instalação existente
  upgrade             atualiza a tag de imagem, com backup automático e rollback
  backup              arquiva .env, compose e (se self-hosted) o volume do Postgres
  restore ARQUIVO.tgz restaura um backup gerado por 'backup' (sobrescreve o destino)
  uninstall           para e remove os containers (--purge também remove volumes)

Opções:
  -c, --config ARQ    arquivo de respostas KEY=VALUE (implica não-interativo)
  -y, --yes           assume sim em todas as confirmações (não afeta o gate de
                      confirmação digitada de 'uninstall --purge')
  -n, --dry-run       mostra o que faria, não escreve nada nem sobe containers
  -q, --quiet         só erros
  -v, --verbose       log detalhado
      --tag VERSAO    tag de imagem — em 'upgrade', é a tag de destino
      --dir CAMINHO   diretório de instalação (default: ${DEFAULT_INSTALL_DIR})
      --no-start      escreve os arquivos mas não sobe a stack (só 'install')
      --purge         com 'uninstall': remove volumes. IRREVERSÍVEL.
      --version
  -h, --help

Exemplos:
  ./olt-install.sh install --tag v1.0.0 -y
  ./olt-install.sh install -c olt.answers --dry-run
  ./olt-install.sh doctor --dir /opt/olt-system
  ./olt-install.sh upgrade --tag v1.1.0 --dir /opt/olt-system
  ./olt-install.sh backup --dir /opt/olt-system
  ./olt-install.sh restore /opt/olt-system/backups/olt-system-backup-*.tgz
  ./olt-install.sh uninstall --purge --dir /opt/olt-system

Chaves aceitas em --config: ${OLT_CONFIG_KEYS[*]}
EOF
}

parse_args() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --version)
      printf 'olt-install.sh %s\n' "$INSTALLER_VERSION"
      exit 0
      ;;
    install | doctor | upgrade | backup | uninstall)
      COMMAND="$1"
      shift
      ;;
    restore)
      COMMAND="restore"
      shift
      if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        RESTORE_FILE="$1"
        shift
      fi
      ;;
    *) die "Comando desconhecido: '$1' (use install|doctor|upgrade|backup|restore|uninstall|--help)" ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      -c | --config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      -y | --yes)
        ASSUME_YES=yes
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=yes
        shift
        ;;
      -q | --quiet)
        QUIET=yes
        shift
        ;;
      -v | --verbose)
        VERBOSE=yes
        shift
        ;;
      --tag)
        IMAGE_TAG="$2"
        shift 2
        ;;
      --dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      --no-start)
        NO_START=yes
        shift
        ;;
      --purge)
        PURGE=yes
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --version)
        printf 'olt-install.sh %s\n' "$INSTALLER_VERSION"
        exit 0
        ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done

  if [ -n "$CONFIG_FILE" ]; then
    load_config_file "$CONFIG_FILE"
    NON_INTERACTIVE=yes
  fi
}

_cleanup() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  err "olt-install.sh terminou com erro (código ${rc})."
  return "$rc"
}
trap _cleanup EXIT
trap 'die "Interrompido pelo operador."' INT TERM

main() {
  parse_args "$@"
  case "$COMMAND" in
    install) cmd_install ;;
    doctor) cmd_doctor ;;
    upgrade) cmd_upgrade ;;
    backup) cmd_backup ;;
    restore) cmd_restore ;;
    uninstall) cmd_uninstall ;;
    *)
      usage
      exit 1
      ;;
  esac
}

# Permite `source olt-install.sh` (usado pelos testes em tests/) sem disparar
# main() — só executa main quando o arquivo roda como script mesmo.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
