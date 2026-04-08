#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Reset complet + déploiement de la stack monitoring
# Usage : bash install_monitoring.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || log_error "Lancer en root ou avec sudo."
[[ -f "docker-compose.yml" ]] || log_error "Lance ce script depuis le dossier du projet (là où se trouve docker-compose.yml)."
[[ -f ".env" ]] || log_error "Fichier .env manquant. Copie .env.example en .env et remplis les valeurs."

# ── 1. Arrêter et supprimer les containers + volumes existants ──
log_info "Arrêt et suppression des containers existants..."
docker compose down --volumes --remove-orphans 2>/dev/null || true

# ── 2. Supprimer toutes les images ──────────────────────────────
log_info "Suppression des images Docker..."
docker rmi $(docker images -q) -f 2>/dev/null || true

# ── 3. Nettoyer volumes, networks, cache résiduels ──────────────
log_info "Nettoyage des volumes et networks résiduels..."
docker volume prune -f
docker network prune -f
docker builder prune -f 2>/dev/null || true

log_success "Docker nettoyé."

# ── 4. Vérification rapide ──────────────────────────────────────
CONTAINERS=$(docker ps -a -q)
IMAGES=$(docker images -q)
[[ -z "$CONTAINERS" ]] && log_success "Aucun container restant." || echo -e "${RED}Containers résiduels détectés.${NC}"
[[ -z "$IMAGES" ]]     && log_success "Aucune image restante."   || echo -e "${RED}Images résiduelles détectées.${NC}"

# ── 5. Lancer l'installation ────────────────────────────────────
log_info "Lancement de l'installation de la stack monitoring..."
bash scripts/install.sh
