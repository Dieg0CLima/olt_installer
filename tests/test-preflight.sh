#!/usr/bin/env bash
# Testes puros de olt-install.sh: validadores, geradores de segredo, idempotência
# do .env e o parser de --config. Não precisa de Docker, root, nem rede — roda em
# qualquer máquina de dev.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/olt-install.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# check DESCRIÇÃO EXPR — EXPR é avaliado num bash -c isolado que já fez
# `source olt-install.sh` (funções/vars disponíveis, main() não dispara por
# causa do guard de sourcing no fim do script).
check() {
  local desc="$1" expr="$2"
  if bash -c "set -Eeuo pipefail; source '$INSTALL_SH'; $expr" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s\n' "$desc"
    FAIL=$((FAIL + 1))
  fi
}

# check_dies DESCRIÇÃO EXPR — variante para funções que chamam die()/exit
# diretamente.
check_dies() {
  local desc="$1" expr="$2"
  if bash -c "set -Eeuo pipefail; source '$INSTALL_SH'; $expr" >/dev/null 2>&1; then
    printf 'FAIL - %s (esperava que morresse, mas teve sucesso)\n' "$desc"
    FAIL=$((FAIL + 1))
  else
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# Validadores
# ---------------------------------------------------------------------------
check "is_port aceita 8000"                 'is_port 8000'
check "is_port rejeita 0"                   '! is_port 0'
check "is_port rejeita 70000"               '! is_port 70000'
check "is_port rejeita não-numérico"        '! is_port abc'

check "is_url aceita http://"               'is_url http://x'
check "is_url aceita https://"              'is_url https://x'
check "is_url rejeita ftp://"               '! is_url ftp://x'
check "is_url rejeita string vazia"         '! is_url ""'

check "is_image_tag aceita v1.2.3"          'is_image_tag v1.2.3'
check "is_image_tag aceita latest"          'is_image_tag latest'
check "is_image_tag rejeita espaço"         '! is_image_tag "v1 2"'
check "is_image_tag rejeita '!'"            '! is_image_tag "v1!"'

check "is_db_mode aceita external"          'is_db_mode external'
check "is_db_mode aceita self-hosted"       'is_db_mode self-hosted'
check "is_db_mode rejeita outro valor"      '! is_db_mode foo'

check "is_nonempty rejeita vazio"           '! is_nonempty ""'
check "is_nonempty aceita não-vazio"        'is_nonempty x'

# ---------------------------------------------------------------------------
# Geradores de segredo
# ---------------------------------------------------------------------------
check "gen_alnum 40 tem 40 chars alfanum" \
  '[ "$(gen_alnum 40 | tr -d "\n" | wc -c)" -eq 40 ] && [ -z "$(gen_alnum 40 | tr -d "A-Za-z0-9\n")" ]'

check "gen_hex 16 produz 32 chars hex" \
  '[ "$(gen_hex 16 | tr -d "\n" | wc -c)" -eq 32 ] && [[ "$(gen_hex 16)" =~ ^[0-9a-f]+$ ]]'

check "gen_b64 32 produz base64 válido, decodifica pra 32 bytes" \
  '[ "$(gen_b64 32 | base64 -d 2>/dev/null | wc -c)" -eq 32 ]'

# ---------------------------------------------------------------------------
# env_get / secret_or_keep — idempotência
# ---------------------------------------------------------------------------
ENVDIR_EXISTING="$TMPROOT/existing"
mkdir -p "$ENVDIR_EXISTING"
cat > "$ENVDIR_EXISTING/.env" <<'EOF'
OLT_SYSTEM_SECRET_KEY_BASE=segredo-ja-existente
EOF

check "env_get lê chave existente do .env" \
  "INSTALL_DIR='$ENVDIR_EXISTING'; [ \"\$(env_get OLT_SYSTEM_SECRET_KEY_BASE)\" = 'segredo-ja-existente' ]"

check "env_get retorna vazio p/ chave ausente" \
  "INSTALL_DIR='$ENVDIR_EXISTING'; [ -z \"\$(env_get CHAVE_QUE_NAO_EXISTE)\" ]"

check "secret_or_keep preserva segredo já gravado no .env" \
  "INSTALL_DIR='$ENVDIR_EXISTING'; secret_or_keep OLT_SYSTEM_SECRET_KEY_BASE gen_hex 64; [ \"\$OLT_SYSTEM_SECRET_KEY_BASE\" = 'segredo-ja-existente' ]"

ENVDIR_FRESH="$TMPROOT/fresh"
mkdir -p "$ENVDIR_FRESH"
check "secret_or_keep gera segredo novo quando não há .env" \
  "INSTALL_DIR='$ENVDIR_FRESH'; secret_or_keep OLT_SYSTEM_SECRET_KEY_BASE gen_hex 64; [ -n \"\$OLT_SYSTEM_SECRET_KEY_BASE\" ] && [[ \"\$NEW_SECRETS\" == *OLT_SYSTEM_SECRET_KEY_BASE* ]]"

check "secret_or_keep respeita valor já setado na env do processo" \
  "INSTALL_DIR='$ENVDIR_FRESH'; OLT_SYSTEM_SECRET_KEY_BASE=veio-do-flag; secret_or_keep OLT_SYSTEM_SECRET_KEY_BASE gen_hex 64; [ \"\$OLT_SYSTEM_SECRET_KEY_BASE\" = 'veio-do-flag' ]"

# ---------------------------------------------------------------------------
# load_config_file — parser seguro (whitelist, sem `source`)
# ---------------------------------------------------------------------------
CONFIG_OK="$TMPROOT/olt.answers"
cat > "$CONFIG_OK" <<'EOF'
# comentário, deve ser ignorado
DB_MODE=self-hosted
IMAGE_TAG=v9.9.9

CHAVE_DESCONHECIDA=nao-deveria-ser-aceita
linha sem sinal de igual
db_mode=minusculo-invalido
EOF

check "load_config_file aplica chaves conhecidas" \
  "load_config_file '$CONFIG_OK'; [ \"\$DB_MODE\" = self-hosted ] && [ \"\$IMAGE_TAG\" = v9.9.9 ]"

check "load_config_file ignora chave desconhecida (não injeta var)" \
  "load_config_file '$CONFIG_OK' 2>/dev/null; [ -z \"\${CHAVE_DESCONHECIDA:-}\" ]"

check "load_config_file ignora chave em minúsculo (fora do padrão)" \
  "load_config_file '$CONFIG_OK' 2>/dev/null; [ -z \"\${db_mode:-}\" ]"

check_dies "load_config_file morre em arquivo inexistente" \
  'load_config_file /caminho/que/nao/existe.answers'

# ---------------------------------------------------------------------------
# containers_for_mode / volumes_for_mode
# ---------------------------------------------------------------------------
check "containers_for_mode(external) não inclui olt_system_db" \
  'DB_MODE=external; [[ "$(containers_for_mode)" != *olt_system_db* ]]'

check "containers_for_mode(self-hosted) inclui olt_system_db" \
  'DB_MODE=self-hosted; [[ "$(containers_for_mode)" == *olt_system_db* ]]'

check "volumes_for_mode(external) não inclui postgres_data" \
  '! (DB_MODE=external; volumes_for_mode | grep -q .)'

check "volumes_for_mode(self-hosted) inclui postgres_data" \
  'DB_MODE=self-hosted; [ "$(volumes_for_mode)" = postgres_data ]'

# ---------------------------------------------------------------------------
# manifest_get — parser mínimo do manifest.json que do_backup() gera
# ---------------------------------------------------------------------------
MANIFEST="$TMPROOT/manifest.json"
cat > "$MANIFEST" <<'EOF'
{
  "installer_version": "0.1.0",
  "db_mode": "self-hosted",
  "image_tag": "v1.2.3",
  "hostname": "olt-prod-01",
  "install_dir": "/opt/olt-system",
  "created_at": "2026-09-15T18:00:00Z"
}
EOF

check "manifest_get lê 'db_mode'" \
  "[ \"\$(manifest_get db_mode '$MANIFEST')\" = self-hosted ]"
check "manifest_get lê 'image_tag'" \
  "[ \"\$(manifest_get image_tag '$MANIFEST')\" = v1.2.3 ]"
check "manifest_get retorna vazio p/ chave ausente" \
  "[ -z \"\$(manifest_get chave_que_nao_existe '$MANIFEST')\" ]"

# ---------------------------------------------------------------------------
printf '\n%s/%s testes passaram.\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
