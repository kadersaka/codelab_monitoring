#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Script d'installation — Serveur Peramix (Ubuntu 22.04)
# À lancer en tant que root ou avec sudo
# Usage : bash install.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_ROOT" || exit 1
dc() {
    local cf="${SCRIPT_ROOT}/docker-compose.yml"
    [[ -f "$cf" ]] || log_error "Fichier introuvable : $cf"
    docker compose -f "$cf" --project-directory "${SCRIPT_ROOT}" "$@"
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Vérifications préalables ─────────────────────────────────────
log_info "Vérification des prérequis..."

[[ $EUID -eq 0 ]] || log_error "Ce script doit être lancé en root ou avec sudo."

if [ ! -f ".env" ]; then
    log_warning "Fichier .env introuvable. Copie de .env.example..."
    cp .env.example .env
    log_warning "IMPORTANT : Edite .env avec tes vraies valeurs avant de continuer."
    log_warning "Lance : nano .env"
    exit 1
fi

# ── Mise à jour système ─────────────────────────────────────────
log_info "Mise à jour des paquets système..."
apt-get update -qq
apt-get upgrade -y -qq

# ── Installation Docker ─────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Installation de Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    log_success "Docker installé."
else
    log_success "Docker déjà installé : $(docker --version)"
fi

# ── Installation Docker Compose ─────────────────────────────────
if ! docker compose version &>/dev/null; then
    log_info "Installation de Docker Compose plugin..."
    apt-get install -y docker-compose-plugin
    log_success "Docker Compose installé."
else
    log_success "Docker Compose déjà installé : $(docker compose version)"
fi

# ── Firewall UFW ────────────────────────────────────────────────
log_info "Configuration du firewall UFW..."
apt-get install -y ufw -qq

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH (changer le port si tu utilises un port custom)
ufw allow 22/tcp comment 'SSH'

# HTTP/HTTPS pour Nginx Proxy Manager
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# BLOQUER l'accès direct aux services (ils passent par Nginx)
# Loki, Prometheus, Grafana, etc. sont sur 127.0.0.1 uniquement

ufw --force enable
log_success "Firewall configuré."

# ── Fail2Ban ────────────────────────────────────────────────────
log_info "Installation de Fail2Ban..."
apt-get install -y fail2ban -qq
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
EOF
systemctl enable fail2ban
systemctl restart fail2ban
log_success "Fail2Ban configuré."

# ── Création dossiers ───────────────────────────────────────────
log_info "Création de la structure de dossiers..."
mkdir -p nginx_proxy/{data,letsencrypt}
mkdir -p secrets

# ── Mot de passe Portainer ──────────────────────────────────────
if [ ! -f "secrets/portainer_password.txt" ]; then
    log_info "Génération du mot de passe Portainer..."
    if command -v htpasswd &>/dev/null; then
        read -s -p "Mot de passe Portainer admin : " PORTAINER_PASS
        echo
        htpasswd -nbB admin "$PORTAINER_PASS" | cut -d":" -f2 > secrets/portainer_password.txt
    else
        apt-get install -y apache2-utils -qq
        read -s -p "Mot de passe Portainer admin : " PORTAINER_PASS
        echo
        htpasswd -nbB admin "$PORTAINER_PASS" | cut -d":" -f2 > secrets/portainer_password.txt
    fi
    log_success "Mot de passe Portainer généré."
fi

chmod 600 secrets/portainer_password.txt

# ── Fichier retention-overrides.yml ─────────────────────────────
if [ ! -f "configs/retention-overrides.yml" ]; then
    log_warning "configs/retention-overrides.yml manquant — utilisation du fichier d'exemple."
fi

# ── Secrets Alertmanager (mot de passe SMTP depuis .env uniquement) ─
log_info "Synchronisation secrets (Alertmanager SMTP) depuis .env..."
bash scripts/sync-secrets-from-env.sh

# ── Démarrage des services ───────────────────────────────────────
log_info "Démarrage de la stack monitoring..."
dc pull
dc up -d

# ── Vérification santé ───────────────────────────────────────────
log_info "Attente du démarrage des services (60 secondes)..."
sleep 60

log_info "Vérification de la santé des services..."
SERVICES=("loki" "prometheus" "grafana" "minio" "alertmanager")
ALL_OK=true

for service in "${SERVICES[@]}"; do
    STATUS=$(dc ps --format "{{.Status}}" "$service" 2>/dev/null || echo "absent")
    if [[ "$STATUS" == *"healthy"* ]] || [[ "$STATUS" == *"Up"* ]]; then
        log_success "$service : $STATUS"
    else
        log_warning "$service : $STATUS"
        ALL_OK=false
    fi
done

# ── Résumé ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  CodeLab Monitoring Stack — Installation terminée"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Prochaines étapes :"
echo "  1. Configurer Nginx Proxy Manager via http://$(hostname -I | awk '{print $1}'):81"
echo "     - Email par défaut : admin@example.com"
echo "     - Mot de passe : changeme"
echo "     - CHANGER immédiatement après la 1ère connexion"
echo ""
echo "  2. Créer les Proxy Hosts dans NPM :"
echo "     monitoring.codelab.bj → grafana:3000"
echo "     loki.codelab.bj       → loki:3100 (+ Basic Auth / Access List)"
echo "     portainer.codelab.bj  → portainer:9443"
echo ""
echo "  3. Accéder à Grafana : https://monitoring.codelab.bj"
echo "     (après configuration NPM + DNS)"
echo ""
echo "  4. Installer Promtail + Node Exporter sur les serveurs distants :"
echo "     bash scripts/install-agent.sh"
echo ""

if $ALL_OK; then
    log_success "Tous les services sont opérationnels."
else
    log_warning "Certains services ne sont pas encore prêts. Lance : cd ${SCRIPT_ROOT} && dc ps"
fi
