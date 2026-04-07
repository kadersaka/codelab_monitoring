#!/usr/bin/env bash
# Écrit secrets/alertmanager_smtp_password.txt depuis SMTP_PASSWORD dans .env
# (Alertmanager lit le fichier, pas les variables d'environnement.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "[sync-secrets] Fichier .env manquant dans $ROOT" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p secrets
umask 077
printf '%s' "${SMTP_PASSWORD:-}" > secrets/alertmanager_smtp_password.txt
chmod 600 secrets/alertmanager_smtp_password.txt
echo "[sync-secrets] secrets/alertmanager_smtp_password.txt mis à jour depuis .env"
