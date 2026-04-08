#!/bin/bash

# ============================================================================
# Script d'initialisation serveur pour mobcash_inte_backend
# Sans Docker - Installation directe sur le serveur
# ============================================================================

set -e  # Arrêter en cas d'erreur

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonctions d'affichage
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ============================================================================
# ÉTAPE 0: Vérification des arguments
# ============================================================================
DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    error "Usage: ./init_server.sh <votre-domaine.com>"
    error "Exemple: ./init_server.sh api.turaincash.com"
    exit 1
fi

info "🚀 Initialisation du serveur pour: $DOMAIN"
info "📁 Répertoire de travail: $(pwd)"

# ============================================================================
# ÉTAPE 1: Détection et vérification de Python
# ============================================================================
step "ÉTAPE 1: Détection de Python"

# Chercher Python (python3 ou python)
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
    PYTHON_VERSION=$(python --version 2>&1 | awk '{print $2}')
else
    error "Python n'est pas installé sur ce système"
    info "Installation de Python 3..."
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip python3-venv python3-dev
    PYTHON_CMD="python3"
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
fi

success "Python détecté: $PYTHON_CMD version $PYTHON_VERSION"

# Installer python3-venv si pas déjà installé
if ! dpkg -l | grep -q python3-venv; then
    info "Installation de python3-venv..."
    sudo apt-get install -y python3-venv
    success "python3-venv installé"
else
    success "python3-venv déjà installé"
fi

# Vérifier la version minimale (3.8+)
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 8 ]); then
    error "Python 3.8+ requis, version actuelle: $PYTHON_VERSION"
    exit 1
fi

success "Version Python compatible: $PYTHON_VERSION"

# ============================================================================
# ÉTAPE 2: Installation des dépendances système
# ============================================================================
step "ÉTAPE 2: Installation des dépendances système"

info "Mise à jour des paquets..."
sudo apt-get update

info "Installation des outils de base..."
sudo apt-get install -y \
    build-essential \
    curl \
    wget \
    git \
    software-properties-common \
    ca-certificates \
    gnupg \
    lsb-release

success "Outils de base installés"

# ============================================================================
# ÉTAPE 3: Installation et configuration de PostgreSQL
# ============================================================================
step "ÉTAPE 3: Installation de PostgreSQL"

if command -v psql &> /dev/null; then
    success "PostgreSQL déjà installé"
    POSTGRES_VERSION=$(psql --version | awk '{print $3}')
    info "Version: $POSTGRES_VERSION"
else
    info "Installation de PostgreSQL..."
    sudo apt-get install -y postgresql postgresql-contrib libpq-dev
    success "PostgreSQL installé"
fi

# Démarrer PostgreSQL
info "Démarrage de PostgreSQL..."
sudo systemctl start postgresql
sudo systemctl enable postgresql
success "PostgreSQL démarré et activé au démarrage"

# Charger les variables d'environnement
if [ -f .env ]; then
    # Nettoyer les espaces et exporter les variables pour le script
    while IFS='=' read -r key value; do
        # Sauter les lignes vides et les commentaires
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        
        # Supprimer les guillemets simples/doubles autour de la valeur si présents
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')
        
        # Exporter la variable
        export "$key=$value"
    done < .env
    success "Fichier .env chargé"
else
    warn "Fichier .env introuvable! Création d'un fichier .env par défaut..."
    cat > .env <<'EOF'
SECRET_KEY='django-insecure-1xk(s@!44_4h^d^q&!vpy=^641-&0r)&eoa^gh8umk$3l@uth@'
DATABASE_NAME=mobcash
DATABASE_USER=root
DATABASE_PASSWORD="qwertyuiop"
DATABASE_HOST=127.0.0.1
DATABASE_PORT=3306
DEBUG=False
TOKEN_BOT="8308946:AAEe5YhGdk9p1wU3Aoo9QGMPOxUMFpXFLIA"
MOBCASHAPI_API_KEY=mbck_live_94dc052ddc73627fcef7ffbdc82b6e69
MOBCASHAPI_API_SECRET=ASfxsuncAblZlz7cAXRvxlg3u06LXE7m37AAiX_8Ids
CONNECT_PRO_BASE_URL="https://connect.slaterci.net"
BASE_URL="https://api.slaterci.net/mobcash"
MOBCASHAPI_BASE_URL=https://api.blaffa-change.net
MTN_NOT_FEE="True"
EMAIL_HOST_USER=zeusslater25@gmail.com
EMAIL_PASSWORD=nhhd bxhw zmkc pmwm
FIREBASE_PROJECT_ID=slater-79f2c
EOF
    success "Fichier .env créé avec les valeurs par défaut"
    warn "⚠️  IMPORTANT: Modifiez le fichier .env avec vos propres valeurs avant de continuer!"
    
    # Charger le nouveau fichier .env
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')
        export "$key=$value"
    done < .env
fi

# Configuration des ports (Multi-projets)
GUNICORN_PORT=${APP_PORT:-8000}
DAPHNE_PORT=${WS_PORT:-8001}

info "Configuration des ports internes:"
info "  - Gunicorn: $GUNICORN_PORT"
info "  - Daphne: $DAPHNE_PORT"

# Créer la base de données et l'utilisateur
info "Configuration de la base de données PostgreSQL..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '${DATABASE_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${DATABASE_NAME};"

sudo -u postgres psql -tc "SELECT 1 FROM pg_user WHERE usename = '${DATABASE_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DATABASE_USER} WITH PASSWORD '${DATABASE_PASSWORD}';"

sudo -u postgres psql -c "ALTER ROLE ${DATABASE_USER} SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE ${DATABASE_USER} SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE ${DATABASE_USER} SET timezone TO 'UTC';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DATABASE_NAME} TO ${DATABASE_USER};"
# Correction pour les erreurs de permission sur le schéma public (PostgreSQL 15+)
sudo -u postgres psql -d ${DATABASE_NAME} -c "GRANT ALL ON SCHEMA public TO ${DATABASE_USER};"
sudo -u postgres psql -c "ALTER USER ${DATABASE_USER} WITH SUPERUSER;"

success "Base de données PostgreSQL configurée"

# ============================================================================
# ÉTAPE 4: Installation et configuration de Redis
# ============================================================================
step "ÉTAPE 4: Installation de Redis"

if command -v redis-server &> /dev/null; then
    success "Redis déjà installé"
    REDIS_VERSION=$(redis-server --version | awk '{print $3}')
    info "Version: $REDIS_VERSION"
else
    info "Installation de Redis..."
    sudo apt-get install -y redis-server
    success "Redis installé"
fi

# Configurer Redis pour écouter sur localhost
info "Configuration de Redis..."
sudo sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf || true
sudo sed -i 's/^# requirepass .*/requirepass ""/' /etc/redis/redis.conf || true

# Démarrer Redis
info "Démarrage de Redis..."
sudo systemctl start redis-server
sudo systemctl enable redis-server
success "Redis démarré et activé au démarrage"

# ============================================================================
# ÉTAPE 5: Installation de Nginx
# ============================================================================
step "ÉTAPE 5: Installation de Nginx"

if command -v nginx &> /dev/null; then
    success "Nginx déjà installé"
    NGINX_VERSION=$(nginx -v 2>&1 | awk -F'/' '{print $2}')
    info "Version: $NGINX_VERSION"
else
    info "Installation de Nginx..."
    sudo apt-get install -y nginx
    success "Nginx installé"
fi

sudo systemctl start nginx
sudo systemctl enable nginx
success "Nginx démarré et activé au démarrage"

# ============================================================================
# ÉTAPE 6: Installation de Certbot (Let's Encrypt)
# ============================================================================
step "ÉTAPE 6: Installation de Certbot pour SSL"

if command -v certbot &> /dev/null; then
    success "Certbot déjà installé"
else
    info "Installation de Certbot..."
    sudo apt-get install -y certbot python3-certbot-nginx
    success "Certbot installé"
fi

# Vérifier si les certificats existent déjà
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    success "Certificats SSL déjà présents pour $DOMAIN"
else
    warn "Certificats SSL non trouvés pour $DOMAIN"
    info "Génération des certificats SSL..."
    
    # Arrêter Nginx temporairement pour Certbot standalone
    sudo systemctl stop nginx
    
    # Générer les certificats
    sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN || {
        error "Échec de la génération des certificats SSL"
        warn "Vous devrez générer les certificats manuellement avec:"
        warn "sudo certbot certonly --standalone -d $DOMAIN"
        # Continuer sans SSL pour l'instant
    }
    
    # Redémarrer Nginx
    sudo systemctl start nginx
fi

# Configurer le renouvellement automatique
info "Configuration du renouvellement automatique SSL..."
sudo systemctl enable certbot.timer || true
success "Renouvellement automatique SSL configuré"

# ============================================================================
# ÉTAPE 7: Installation de Supervisor
# ============================================================================
step "ÉTAPE 7: Installation de Supervisor"

if command -v supervisorctl &> /dev/null; then
    success "Supervisor déjà installé"
else
    info "Installation de Supervisor..."
    sudo apt-get install -y supervisor
    success "Supervisor installé"
fi

sudo systemctl start supervisor
sudo systemctl enable supervisor
success "Supervisor démarré et activé au démarrage"

# ============================================================================
# ÉTAPE 8: Configuration de l'environnement Python
# ============================================================================
step "ÉTAPE 8: Configuration de l'environnement Python"

# Créer l'environnement virtuel s'il n'existe pas
if [ -d ".venv" ]; then
    success "Environnement virtuel .venv déjà présent"
else
    info "Création de l'environnement virtuel..."
    $PYTHON_CMD -m venv .venv
    success "Environnement virtuel créé"
fi

# Activer l'environnement virtuel
info "Activation de l'environnement virtuel..."
source .venv/bin/activate

# Mettre à jour pip
info "Mise à jour de pip..."
pip install --upgrade pip

# Installer les dépendances
info "Installation des dépendances Python (cela peut prendre quelques minutes)..."
pip install -r requirements.txt
success "Dépendances Python installées"

# ============================================================================
# ÉTAPE 9: Configuration Django
# ============================================================================
step "ÉTAPE 9: Configuration Django"

# Créer les dossiers pour static et media
info "Création des dossiers static et media..."
sudo mkdir -p /var/www/mobcash/static
sudo mkdir -p /var/www/mobcash/media
sudo chown -R $USER:$USER /var/www/mobcash
success "Dossiers créés"

# Créer le dossier logs
info "Création du dossier logs..."
mkdir -p logs
success "Dossier logs créé"

# Vérifier Django
info "Vérification de Django..."
$PYTHON_CMD manage.py check
success "Django fonctionne correctement"

# Créer et appliquer les migrations
info "Création des migrations..."
$PYTHON_CMD manage.py makemigrations || warn "Aucune nouvelle migration"

info "Application des migrations..."
$PYTHON_CMD manage.py migrate
success "Migrations appliquées"

# Collecter les fichiers statiques
info "Collecte des fichiers statiques..."
$PYTHON_CMD manage.py collectstatic --noinput
success "Fichiers statiques collectés"

# ============================================================================
# ÉTAPE 10: Configuration de Gunicorn (systemd)
# ============================================================================
step "ÉTAPE 10: Configuration de Gunicorn"

PROJECT_DIR=$(pwd)
VENV_PATH="$PROJECT_DIR/.venv"

info "Création du service systemd pour Gunicorn..."
sudo tee /etc/systemd/system/gunicorn_mobcash.service > /dev/null <<EOF
[Unit]
Description=Gunicorn daemon for mobcash_inte_backend
After=network.target

[Service]
Type=notify
User=$USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$VENV_PATH/bin"
EnvironmentFile=$PROJECT_DIR/.env
ExecStart=$VENV_PATH/bin/gunicorn \\
    --workers 4 \\
    --bind 127.0.0.1:$GUNICORN_PORT \\
    --timeout 120 \\
    --access-logfile $PROJECT_DIR/logs/gunicorn_access.log \\
    --error-logfile $PROJECT_DIR/logs/gunicorn_error.log \\
    --log-level info \\
    mobcash_inte_backend.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

success "Service Gunicorn créé"

# Recharger systemd et démarrer Gunicorn
info "Démarrage de Gunicorn..."
sudo systemctl daemon-reload
sudo systemctl start gunicorn_mobcash
sudo systemctl enable gunicorn_mobcash
success "Gunicorn démarré et activé au démarrage"

# Vérifier le statut
if sudo systemctl is-active --quiet gunicorn_mobcash; then
    success "Gunicorn fonctionne correctement sur le port $GUNICORN_PORT"
else
    error "Gunicorn n'a pas démarré correctement"
    sudo systemctl status gunicorn_mobcash
fi

# ============================================================================
# ÉTAPE 11: Configuration de Daphne (systemd)
# ============================================================================
step "ÉTAPE 11: Configuration de Daphne (WebSockets)"

info "Création du service systemd pour Daphne..."
sudo tee /etc/systemd/system/daphne_mobcash.service > /dev/null <<EOF
[Unit]
Description=Daphne daemon for mobcash_inte_backend WebSockets
After=network.target

[Service]
Type=simple
User=$USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$VENV_PATH/bin"
EnvironmentFile=$PROJECT_DIR/.env
ExecStart=$VENV_PATH/bin/daphne \\
    -b 127.0.0.1 \\
    -p $DAPHNE_PORT \\
    mobcash_inte_backend.asgi:application

[Install]
WantedBy=multi-user.target
EOF

success "Service Daphne créé"

# Démarrer Daphne
info "Démarrage de Daphne..."
sudo systemctl daemon-reload
sudo systemctl start daphne_mobcash
sudo systemctl enable daphne_mobcash
success "Daphne démarré et activé au démarrage"

# Vérifier le statut
if sudo systemctl is-active --quiet daphne_mobcash; then
    success "Daphne fonctionne correctement sur le port $DAPHNE_PORT"
else
    error "Daphne n'a pas démarré correctement"
    sudo systemctl status daphne_mobcash
fi

# ============================================================================
# ÉTAPE 12: Configuration de Celery (Supervisor)
# ============================================================================
step "ÉTAPE 12: Configuration de Celery"

info "Création de la configuration Supervisor pour Celery Worker..."
sudo tee /etc/supervisor/conf.d/celery_mobcash.conf > /dev/null <<EOF
[program:celery_mobcash_worker]
command=$VENV_PATH/bin/celery -A mobcash_inte_backend worker --loglevel=info --concurrency=4
directory=$PROJECT_DIR
user=$USER
autostart=true
autorestart=true
stdout_logfile=$PROJECT_DIR/logs/celery_worker.log
stderr_logfile=$PROJECT_DIR/logs/celery_worker_error.log
environment=PATH="$VENV_PATH/bin"

[program:celery_mobcash_beat]
command=$VENV_PATH/bin/celery -A mobcash_inte_backend beat --loglevel=info
directory=$PROJECT_DIR
user=$USER
autostart=true
autorestart=true
stdout_logfile=$PROJECT_DIR/logs/celery_beat.log
stderr_logfile=$PROJECT_DIR/logs/celery_beat_error.log
environment=PATH="$VENV_PATH/bin"
EOF

success "Configuration Celery créée"

# Recharger Supervisor
info "Rechargement de Supervisor..."
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start celery_mobcash_worker celery_mobcash_beat
success "Celery démarré"

# Vérifier le statut
info "Statut de Celery:"
sudo supervisorctl status celery_mobcash_worker celery_mobcash_beat

# ============================================================================
# ÉTAPE 13: Configuration de Nginx
# ============================================================================
step "ÉTAPE 13: Configuration de Nginx"

info "Création de la configuration Nginx..."

# Vérifier si SSL existe
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    HAS_SSL=true
else
    HAS_SSL=false
    warn "Pas de certificats SSL, configuration HTTP uniquement"
fi

# Créer la configuration Nginx
if [ "$HAS_SSL" = true ]; then
    # Configuration avec SSL
    sudo tee /etc/nginx/sites-available/mobcash_inte > /dev/null <<EOF
# Redirection HTTP vers HTTPS
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

# Configuration HTTPS
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    # Certificats SSL
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    # Paramètres SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Taille maximale des uploads
    client_max_body_size 100M;

    # Logs
    access_log $PROJECT_DIR/logs/nginx_access.log;
    error_log $PROJECT_DIR/logs/nginx_error.log;

    # Fichiers statiques
    location /static/ {
        alias /var/www/mobcash/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Fichiers média
    location /media/ {
        alias /var/www/mobcash/media/;
        expires 7d;
    }

    # WebSocket (Daphne)
    location /ws/ {
        proxy_pass http://127.0.0.1:$DAPHNE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    # Application Django (Gunicorn)
    location / {
        proxy_pass http://127.0.0.1:$GUNICORN_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
    }
}
EOF
else
    # Configuration HTTP uniquement
    sudo tee /etc/nginx/sites-available/mobcash_inte > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 100M;

    access_log $PROJECT_DIR/logs/nginx_access.log;
    error_log $PROJECT_DIR/logs/nginx_error.log;

    location /static/ {
        alias /var/www/mobcash/static/;
    }

    location /media/ {
        alias /var/www/mobcash/media/;
    }

    location /ws/ {
        proxy_pass http://127.0.0.1:$DAPHNE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    location / {
        proxy_pass http://127.0.0.1:$GUNICORN_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_redirect off;
    }
}
EOF
fi

success "Configuration Nginx créée"

# Activer le site
info "Activation du site Nginx..."
sudo ln -sf /etc/nginx/sites-available/mobcash_inte /etc/nginx/sites-enabled/

# Supprimer la configuration par défaut si elle existe
sudo rm -f /etc/nginx/sites-enabled/default

# Tester la configuration
info "Test de la configuration Nginx..."
sudo nginx -t

# Recharger Nginx
info "Rechargement de Nginx..."
sudo systemctl reload nginx
success "Nginx configuré et rechargé"

# ============================================================================
# ÉTAPE 14: Vérifications finales
# ============================================================================
step "ÉTAPE 14: Vérifications finales"

info "Vérification des services..."

# Vérifier PostgreSQL
if sudo systemctl is-active --quiet postgresql; then
    success "✓ PostgreSQL: actif"
else
    error "✗ PostgreSQL: inactif"
fi

# Vérifier Redis
if sudo systemctl is-active --quiet redis-server; then
    success "✓ Redis: actif"
else
    error "✗ Redis: inactif"
fi

# Vérifier Nginx
if sudo systemctl is-active --quiet nginx; then
    success "✓ Nginx: actif"
else
    error "✗ Nginx: inactif"
fi

# Vérifier Gunicorn
if sudo systemctl is-active --quiet gunicorn_mobcash; then
    success "✓ Gunicorn: actif (port $GUNICORN_PORT)"
else
    error "✗ Gunicorn: inactif"
fi

# Vérifier Daphne
if sudo systemctl is-active --quiet daphne_mobcash; then
    success "✓ Daphne: actif (port $DAPHNE_PORT)"
else
    error "✗ Daphne: inactif"
fi

# Vérifier Celery
CELERY_STATUS=$(sudo supervisorctl status celery_mobcash_worker | awk '{print $2}')
if [ "$CELERY_STATUS" = "RUNNING" ]; then
    success "✓ Celery Worker: actif"
else
    error "✗ Celery Worker: $CELERY_STATUS"
fi

# ============================================================================
# RÉSUMÉ FINAL
# ============================================================================
step "🎉 INSTALLATION TERMINÉE"

echo ""
success "Serveur configuré avec succès pour: $DOMAIN"
echo ""
info "📋 Résumé de l'installation:"
echo "  • Python: $PYTHON_VERSION"
echo "  • PostgreSQL: installé et configuré"
echo "  • Redis: installé et configuré"
echo "  • Nginx: installé et configuré"
echo "  • Gunicorn: actif sur le port $GUNICORN_PORT"
echo "  • Daphne: actif sur le port $DAPHNE_PORT"
echo "  • Celery: actif (worker + beat)"
if [ "$HAS_SSL" = true ]; then
    echo "  • SSL: configuré avec Let's Encrypt"
else
    echo "  • SSL: non configuré (HTTP uniquement)"
fi
echo ""
info "🌐 Accès:"
if [ "$HAS_SSL" = true ]; then
    echo "  • URL: https://$DOMAIN"
else
    echo "  • URL: http://$DOMAIN"
fi
echo ""
info "📝 Commandes utiles:"
echo "  • Redémarrer Gunicorn: sudo systemctl restart gunicorn_mobcash"
echo "  • Redémarrer Daphne: sudo systemctl restart daphne_mobcash"
echo "  • Redémarrer Celery: sudo supervisorctl restart celery_mobcash_worker celery_mobcash_beat"
echo "  • Voir les logs Gunicorn: tail -f $PROJECT_DIR/logs/gunicorn_error.log"
echo "  • Voir les logs Celery: tail -f $PROJECT_DIR/logs/celery_worker.log"
echo "  • Voir les logs Nginx: tail -f $PROJECT_DIR/logs/nginx_error.log"
echo ""
info "🔄 Pour déployer les mises à jour, utilisez:"
echo "  ./deploy.sh"
echo ""

if [ "$HAS_SSL" = false ]; then
    warn "⚠️  Pour activer SSL plus tard, exécutez:"
    echo "  sudo certbot --nginx -d $DOMAIN"
    echo ""
fi

success "✅ Installation terminée avec succès!"
