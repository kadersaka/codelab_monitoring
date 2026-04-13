#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CodeLab Monitoring Stack — Script d'installation
# Compatible : Ubuntu 22.04 / Oracle Cloud (OCI)
# Usage : sudo bash scripts/install.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_ROOT" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

dc() {
    docker compose -f "${SCRIPT_ROOT}/docker-compose.yml" --project-directory "${SCRIPT_ROOT}" "$@"
}

# ── Vérifications préalables ─────────────────────────────────────
[[ $EUID -eq 0 ]] || log_error "Ce script doit être lancé en root : sudo bash scripts/install.sh"

if [ ! -f "${SCRIPT_ROOT}/.env" ]; then
    log_warning "Fichier .env introuvable. Copie de .env.example..."
    cp "${SCRIPT_ROOT}/.env.example" "${SCRIPT_ROOT}/.env"
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  IMPORTANT : Remplis le fichier .env avant de continuer${NC}"
    echo -e "${YELLOW}  Lance : nano ${SCRIPT_ROOT}/.env${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "   CodeLab Monitoring Stack — Démarrage installation"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Mise à jour système ──────────────────────────────────────────
log_info "Mise à jour des paquets système..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git unzip apt-transport-https ca-certificates gnupg lsb-release
log_success "Système mis à jour."

# ── Installation Docker ──────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_info "Installation de Docker Engine..."
    # Supprimer Docker Snap s'il existe
    if snap list docker &>/dev/null 2>&1; then
        log_warning "Docker Snap détecté — suppression..."
        snap remove docker || true
    fi
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    log_success "Docker installé : $(docker --version)"
else
    log_success "Docker déjà installé : $(docker --version)"
fi

# ── Docker Compose plugin ────────────────────────────────────────
if ! docker compose version &>/dev/null 2>&1; then
    log_info "Installation du plugin Docker Compose..."
    apt-get install -y docker-compose-plugin
    log_success "Docker Compose installé."
else
    log_success "Docker Compose : $(docker compose version)"
fi

# ── Firewall UFW ─────────────────────────────────────────────────
log_info "Configuration du firewall UFW..."
apt-get install -y ufw -qq

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP'
ufw allow 443/tcp  comment 'HTTPS'
ufw allow 81/tcp   comment 'NPM Admin (temporaire)'
ufw --force enable
log_success "UFW configuré."

# ── Règles iptables OCI ──────────────────────────────────────────
# Oracle Cloud bloque le trafic via iptables en plus du Security Group
log_info "Configuration iptables pour Oracle Cloud..."
apt-get install -y iptables-persistent netfilter-persistent -qq || true

iptables -I INPUT  -p tcp --dport 80  -j ACCEPT 2>/dev/null || true
iptables -I INPUT  -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
iptables -I INPUT  -p tcp --dport 81  -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -j ACCEPT         2>/dev/null || true

# Sauvegarder les règles iptables
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
log_success "iptables OCI configuré."

# ── Fail2Ban ─────────────────────────────────────────────────────
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

# ── Création des dossiers nécessaires ────────────────────────────
log_info "Création de la structure de dossiers..."
mkdir -p "${SCRIPT_ROOT}/nginx_proxy/data"
mkdir -p "${SCRIPT_ROOT}/nginx_proxy/letsencrypt"
mkdir -p "${SCRIPT_ROOT}/secrets"
chmod 700 "${SCRIPT_ROOT}/secrets"
log_success "Dossiers créés."

# ── Mot de passe Portainer ───────────────────────────────────────
if [ ! -f "${SCRIPT_ROOT}/secrets/portainer_password.txt" ]; then
    log_info "Génération du mot de passe Portainer..."
    apt-get install -y apache2-utils -qq
    echo ""
    read -s -p "  Choisis un mot de passe pour Portainer admin : " PORTAINER_PASS
    echo ""
    htpasswd -nbB admin "$PORTAINER_PASS" | cut -d":" -f2 > "${SCRIPT_ROOT}/secrets/portainer_password.txt"
    log_success "Mot de passe Portainer généré."
fi
chmod 600 "${SCRIPT_ROOT}/secrets/portainer_password.txt"

# ── Secret SMTP pour Alertmanager ───────────────────────────────
log_info "Synchronisation du secret SMTP..."
bash "${SCRIPT_ROOT}/scripts/sync-secrets-from-env.sh"
log_success "Secret SMTP synchronisé."

# ── Pull des images Docker ───────────────────────────────────────
log_info "Téléchargement des images Docker (peut prendre quelques minutes)..."
dc pull
log_success "Images téléchargées."

# ── Démarrage de la stack ────────────────────────────────────────
log_info "Démarrage de tous les services..."
dc up -d --remove-orphans
log_success "Services démarrés."

# ── Attente et vérification ──────────────────────────────────────
log_info "Attente du démarrage des services (60 secondes)..."
sleep 60

log_info "Vérification de l'état des services..."
echo ""
dc ps
echo ""

ALL_OK=true
for service in loki prometheus grafana alertmanager; do
    STATUS=$(dc ps --format "{{.Status}}" "$service" 2>/dev/null || echo "absent")
    if [[ "$STATUS" == *"healthy"* ]] || [[ "$STATUS" == *"Up"* ]]; then
        log_success "$service : OK"
    else
        log_warning "$service : $STATUS"
        ALL_OK=false
    fi
done

# ── Résumé final ─────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "══════════════════════════════════════════════════════"
echo "   CodeLab Monitoring Stack — Installation terminée"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  ⚠️  IMPORTANT — Ouvrir les ports dans la console OCI :"
echo "     Console OCI → Networking → VCN → Security Lists"
echo "     Ajouter Ingress Rules : TCP 80, 443, 81"
echo ""
echo "  Accès Nginx Proxy Manager (config reverse proxy + SSL) :"
echo "     http://${SERVER_IP}:81"
echo "     Email    : admin@example.com"
echo "     Password : changeme  ← CHANGER IMMÉDIATEMENT"
echo ""
echo "  Proxy Hosts à créer dans NPM :"
echo "     monitoring.codelab.bj  →  grafana:3000    (SSL Let's Encrypt)"
echo "     loki.codelab.bj        →  loki:3100       (SSL + Basic Auth)"
echo "     portainer.codelab.bj   →  portainer:9443  (SSL Let's Encrypt)"
echo ""
echo "  Commandes utiles :"
echo "     bash scripts/manage.sh status"
echo "     bash scripts/manage.sh logs grafana"
echo "     bash scripts/manage.sh logs loki"
echo ""

if $ALL_OK; then
    log_success "Tous les services sont opérationnels."
else
    log_warning "Certains services ne sont pas encore prêts."
    echo "  → Lance : bash scripts/manage.sh logs <service> pour diagnostiquer"
fi
