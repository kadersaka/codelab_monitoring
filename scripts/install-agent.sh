#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Script d'installation des agents de monitoring
# À lancer sur chaque serveur applicatif (OCI, Hostinger, etc.)
# Usage : bash install-agent.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || log_error "Lancer en root ou avec sudo."

# ── Variables à configurer ──────────────────────────────────────
echo ""
echo "Configuration de l'agent de monitoring"
echo "═══════════════════════════════════════"
read -p "Tenant ID (ex: paygate, projetb) : " TENANT_ID
read -p "Nom du serveur (ex: oci-paygate) : " SERVER_NAME
read -p "URL Loki (ex: loki.codelab.bj) : " LOKI_HOST
read -p "Username Loki pour ce tenant : " LOKI_USER
read -s -p "Password Loki : " LOKI_PASS
echo
read -p "Chemin logs app (ex: /home/paygate/logs) [laisser vide si pas de Django] : " APP_LOG_PATH
read -p "Nom de l'app (ex: paygate) [laisser vide si pas de Django] : " APP_NAME
echo ""

# ── Versions ────────────────────────────────────────────────────
PROMTAIL_VERSION="2.9.3"
NODE_EXPORTER_VERSION="1.7.0"
ARCH="amd64"

# ── Installation Node Exporter ──────────────────────────────────
log_info "Installation Node Exporter v${NODE_EXPORTER_VERSION}..."

useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
    -O /tmp/node_exporter.tar.gz

tar xf /tmp/node_exporter.tar.gz -C /tmp
cp "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
rm -rf /tmp/node_exporter*

cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \\
    --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|host|etc)(\$|/)' \\
    --web.listen-address=0.0.0.0:9100

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

log_success "Node Exporter installé et démarré sur :9100"

# ── Installation Promtail ───────────────────────────────────────
log_info "Installation Promtail v${PROMTAIL_VERSION}..."

useradd --no-create-home --shell /bin/false promtail 2>/dev/null || true
usermod -aG adm promtail

mkdir -p /etc/promtail

wget -q "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip" \
    -O /tmp/promtail.zip

apt-get install -y unzip -qq
unzip -q /tmp/promtail.zip -d /tmp/
cp /tmp/promtail-linux-${ARCH} /usr/local/bin/promtail
chmod +x /usr/local/bin/promtail
rm -f /tmp/promtail*

# ── Génération de la config Promtail ───────────────────────────
CONFIG_FILE="/etc/promtail/config.yml"

cat > "$CONFIG_FILE" << PROMTAIL_EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn

positions:
  filename: /tmp/promtail-positions-${TENANT_ID}.yaml
  sync_period: 10s

clients:
  - url: https://${LOKI_HOST}/loki/api/v1/push
    tenant_id: ${TENANT_ID}
    basic_auth:
      username: ${LOKI_USER}
      password: ${LOKI_PASS}
    batchwait: 1s
    batchsize: 1048576
    timeout: 30s
    backoff_config:
      min_period: 500ms
      max_period: 10m
      max_retries: 20

scrape_configs:

  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          server: ${SERVER_NAME}
          tenant: ${TENANT_ID}
          __path__: /var/log/syslog

  - job_name: auth
    static_configs:
      - targets: [localhost]
        labels:
          job: auth
          server: ${SERVER_NAME}
          tenant: ${TENANT_ID}
          __path__: /var/log/auth.log
PROMTAIL_EOF

# Ajouter les logs Django si un chemin est fourni
if [ -n "$APP_LOG_PATH" ] && [ -n "$APP_NAME" ]; then
cat >> "$CONFIG_FILE" << DJANGO_EOF

  - job_name: django
    static_configs:
      - targets: [localhost]
        labels:
          job: django
          app: ${APP_NAME}
          server: ${SERVER_NAME}
          env: production
          __path__: ${APP_LOG_PATH}/*.log
    pipeline_stages:
      - regex:
          expression: '^\[(?P<timestamp>[^\]]+)\]\s+\[(?P<level>[A-Z]+)\]\s+\[(?P<logger>[^\]]+)\](\s+\[\d+\])?\s+(?P<message>.*)'
      - labels:
          level:
          logger:
      - match:
          selector: '{level="DEBUG"}'
          action: drop
          drop_counter_reason: debug_dropped
      - replace:
          expression: '(?i)(password|secret|token|api_key|authorization)(["\\s:=]+)([^\\s,\\]"]{4,})'
          replace: '\$1\$2***'

  - job_name: nginx_access
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx_access
          app: ${APP_NAME}
          server: ${SERVER_NAME}
          __path__: /var/log/nginx/access.log
    pipeline_stages:
      - drop:
          expression: '(GET /health|GET /metrics|HEAD /)'
          drop_counter_reason: health_check

  - job_name: nginx_error
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx_error
          app: ${APP_NAME}
          server: ${SERVER_NAME}
          __path__: /var/log/nginx/error.log
DJANGO_EOF
    log_success "Configuration logs Django ajoutée."
fi

chown promtail:promtail "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ── Service Systemd Promtail ────────────────────────────────────
cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail — Loki Log Agent
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network.target

[Service]
User=promtail
Group=promtail
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml

NoNewPrivileges=yes
PrivateTmp=yes

Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable promtail
systemctl start promtail

log_success "Promtail installé et démarré."

# ── Firewall : ouvrir Node Exporter seulement pour Peramix ──────
echo ""
read -p "IP du serveur Peramix (pour autoriser Node Exporter) : " PERAMIX_IP

if command -v ufw &>/dev/null; then
    ufw allow from "$PERAMIX_IP" to any port 9100 comment 'Prometheus Node Exporter'
    log_success "Firewall : port 9100 ouvert pour $PERAMIX_IP"
fi

# ── Résumé ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Agent installé sur : ${SERVER_NAME}"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  ✅ Node Exporter  → :9100"
echo "  ✅ Promtail       → envoi vers https://${LOKI_HOST}"
echo ""
echo "  Prochaines étapes sur Peramix :"
echo "  1. Ajouter dans configs/prometheus.yml :"
echo "     - targets: ['$(hostname -I | awk '{print $1}'):9100']"
echo "       labels:"
echo "         server: ${SERVER_NAME}"
echo "         project: ${TENANT_ID}"
echo ""
echo "  2. Recharger Prometheus :"
echo "     bash scripts/manage.sh reload-prom"
echo ""
echo "  Vérifier les logs Promtail :"
echo "     journalctl -u promtail -f"
echo ""
