#!/usr/bin/env bash
# Confirma que o bloco de compose embutido em olt-install.sh bate com a fonte real
# em ../olt_docker/docker-compose.prod.yml. Exige olt_docker clonado como irmão
# deste repo (mesma suposição de scripts/sync-installer.sh).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/sync-installer.sh" --check
