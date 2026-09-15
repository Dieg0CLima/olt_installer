#!/usr/bin/env bash
# Regenera o bloco de docker-compose embutido em olt-install.sh a partir do
# arquivo-fonte real no repo-irmão olt_docker (docker-compose.prod.yml). O bloco
# gerado fica marcado com "GERADO POR scripts/sync-installer.sh — NÃO EDITE" dentro
# do próprio instalador; nunca edite esse trecho à mão, edite
# ../olt_docker/docker-compose.prod.yml e rode este script de novo.
#
# Uso:
#   scripts/sync-installer.sh            # regenera olt-install.sh in-place
#   scripts/sync-installer.sh --check    # só valida (diff); não escreve nada
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/olt-install.sh"
COMPOSE_SRC="$ROOT/../olt_docker/docker-compose.prod.yml"

die() { printf 'sync-installer: %s\n' "$*" >&2; exit 1; }

CHECK_ONLY=no
case "${1:-}" in
  --check) CHECK_ONLY=yes ;;
  "") ;;
  *) die "opção desconhecida: $1 (use --check ou nenhum argumento)" ;;
esac

[ -f "$INSTALL_SH" ] || die "não encontrei $INSTALL_SH"
[ -f "$COMPOSE_SRC" ] || die "não encontrei $COMPOSE_SRC — o repo olt_docker precisa estar clonado como irmão de olt_installer"

# splice_block MARKER SOURCE_FILE TARGET_FILE OUT_FILE
# Substitui tudo entre "# >>> OLT:MARKER:BEGIN" e "# <<< OLT:MARKER:END" (inclusive)
# em TARGET_FILE por um novo bloco `COMPOSE_MARKER=$(cat <<'...' )` com o conteúdo
# literal de SOURCE_FILE, escrevendo o resultado em OUT_FILE.
splice_block() {
  local marker="$1" src="$2" target="$3" out="$4"
  local begin="# >>> OLT:${marker}:BEGIN" end="# <<< OLT:${marker}:END"

  grep -Fq 'OLT_COMPOSE_EOF' "$src" && die "conflito de delimitador: '$src' contém a linha 'OLT_COMPOSE_EOF'"
  grep -Fq "$begin" "$target" || die "marcador '$begin' não encontrado em $target"
  grep -Fq "$end" "$target" || die "marcador '$end' não encontrado em $target"

  {
    awk -v b="$begin" '{print} index($0,b){exit}' "$target"
    printf 'COMPOSE_%s=$(cat <<'\''OLT_COMPOSE_EOF'\''\n' "$marker"
    cat "$src"
    printf 'OLT_COMPOSE_EOF\n)\n'
    awk -v e="$end" 'index($0,e){f=1} f{print}' "$target"
  } > "$out"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

splice_block PROD "$COMPOSE_SRC" "$INSTALL_SH" "$tmp"

if [ "$CHECK_ONLY" = yes ]; then
  if diff -u "$INSTALL_SH" "$tmp" >&2; then
    printf 'sync-installer: OK — bloco embutido bate com a fonte.\n'
    exit 0
  fi
  printf 'sync-installer: DIVERGÊNCIA (acima) — rode scripts/sync-installer.sh sem --check para atualizar.\n' >&2
  exit 1
fi

chmod 755 "$tmp"
mv "$tmp" "$INSTALL_SH"
printf 'sync-installer: olt-install.sh atualizado a partir de:\n  %s\n' "$COMPOSE_SRC"
