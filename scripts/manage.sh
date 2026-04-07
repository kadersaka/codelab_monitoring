#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# manage.sh — Commandes de gestion quotidienne
# Usage : bash manage.sh [commande]
# ═══════════════════════════════════════════════════════════════

set -euo pipefail
cd "$(dirname "$0")/.."

# Préfixe des volumes Docker (= nom du projet Compose) : COMPOSE_PROJECT_NAME dans .env, sinon nom du dossier
compose_volume_prefix() {
    local from_env=""
    if [[ -f .env ]]; then
        from_env="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[\"'\'']//;s/[\"'\'']$//')"
    fi
    if [[ -n "${from_env}" ]]; then
        echo "${from_env}"
    else
        basename "$(pwd)"
    fi
}

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Envoie une alerte de test à Alertmanager (api v1). $1 = severity (warning|critical)
post_test_alert_to_alertmanager() {
    local severity="$1"
    local tmp http_code
    tmp=$(mktemp)
    if ! http_code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST http://127.0.0.1:9093/api/v1/alerts \
        -H 'Content-Type: application/json' \
        -d "[{
            \"labels\": {
                \"alertname\": \"TestAlerteCodeLab\",
                \"severity\": \"${severity}\",
                \"project\": \"test\"
            },
            \"annotations\": {
                \"summary\": \"Alerte de test CodeLab Monitoring\",
                \"description\": \"Test depuis manage.sh (severity=${severity}).\"
            }
        }]"); then
        rm -f "$tmp"
        echo -e "${RED}Échec : impossible de joindre Alertmanager sur http://127.0.0.1:9093${NC}" >&2
        echo "  → Lance la stack sur cette machine : docker compose up -d alertmanager" >&2
        echo "  → Ou exécute ce script sur le VPS où tourne le monitoring." >&2
        return 1
    fi
    if [[ "$http_code" != 200 ]] && [[ "$http_code" != 202 ]]; then
        echo -e "${RED}Alertmanager a répondu HTTP ${http_code}${NC}" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

show_help() {
    echo ""
    echo "CodeLab Monitoring — Commandes disponibles :"
    echo ""
    echo "  bash scripts/manage.sh status        Statut de tous les services"
    echo "  bash scripts/manage.sh logs [svc]    Logs d'un service (ex: loki, grafana)"
    echo "  bash scripts/manage.sh restart [svc] Redémarrer un service"
    echo "  bash scripts/manage.sh update        Mettre à jour les images Docker"
    echo "  bash scripts/manage.sh backup        Sauvegarder les volumes"
    echo "  bash scripts/manage.sh reload-prom   Recharger la config Prometheus sans redémarrage"
    echo "  bash scripts/manage.sh disk          Utilisation disque des volumes"
    echo "  bash scripts/manage.sh test-alert          Alerte test severity=warning (email seulement)"
    echo "  bash scripts/manage.sh test-alert-critical Alerte test severity=critical (email + Telegram)"
    echo "  bash scripts/manage.sh sync-secrets        Régénérer le secret SMTP Alertmanager depuis .env"
    echo ""
}

case "${1:-help}" in

    status)
        echo -e "${BLUE}Statut des services :${NC}"
        docker compose ps
        echo ""
        echo -e "${BLUE}Utilisation des ressources :${NC}"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
        ;;

    logs)
        SERVICE="${2:-grafana}"
        echo -e "${BLUE}Logs de $SERVICE (Ctrl+C pour quitter) :${NC}"
        docker compose logs -f --tail=100 "$SERVICE"
        ;;

    restart)
        SERVICE="${2:-}"
        if [ -z "$SERVICE" ]; then
            echo -e "${YELLOW}Usage : bash scripts/manage.sh restart [service]${NC}"
            exit 1
        fi
        echo -e "${BLUE}Redémarrage de $SERVICE...${NC}"
        docker compose restart "$SERVICE"
        echo -e "${GREEN}$SERVICE redémarré.${NC}"
        ;;

    sync-secrets)
        bash scripts/sync-secrets-from-env.sh
        echo -e "${GREEN}Secrets synchronisés. Redémarre alertmanager si tu as changé SMTP_PASSWORD : docker compose restart alertmanager${NC}"
        ;;

    update)
        echo -e "${BLUE}Mise à jour des images Docker...${NC}"
        bash scripts/sync-secrets-from-env.sh
        docker compose pull
        docker compose up -d
        docker image prune -f
        echo -e "${GREEN}Mise à jour terminée.${NC}"
        ;;

    backup)
        VOL_PFX="$(compose_volume_prefix)"
        GVOL="${VOL_PFX}_grafana_data"
        PVOL="${VOL_PFX}_prometheus_data"
        for v in "$GVOL" "$PVOL"; do
            if ! docker volume inspect "$v" &>/dev/null; then
                echo -e "${RED}Volume introuvable : $v${NC}" >&2
                echo "  Préfixe détecté : ${VOL_PFX} (dossier ou COMPOSE_PROJECT_NAME dans .env)" >&2
                echo "  Volumes présents : docker volume ls | grep grafana\\|prometheus" >&2
                exit 1
            fi
        done

        BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo -e "${BLUE}Sauvegarde dans $BACKUP_DIR (volumes ${GVOL}, ${PVOL})...${NC}"

        # Grafana (dashboards, users, etc.)
        docker run --rm \
            -v "${GVOL}:/data" \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf /backup/grafana.tar.gz -C /data .
        echo -e "${GREEN}Grafana sauvegardé.${NC}"

        # Prometheus (métriques)
        docker run --rm \
            -v "${PVOL}:/data" \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf /backup/prometheus.tar.gz -C /data .
        echo -e "${GREEN}Prometheus sauvegardé.${NC}"

        # Configs
        tar czf "$BACKUP_DIR/configs.tar.gz" configs/
        echo -e "${GREEN}Configs sauvegardées.${NC}"

        echo -e "${GREEN}Sauvegarde complète dans : $BACKUP_DIR${NC}"
        ls -lh "$BACKUP_DIR"
        ;;

    reload-prom)
        echo -e "${BLUE}Rechargement de la configuration Prometheus...${NC}"
        curl -s -X POST http://localhost:9090/-/reload
        echo -e "${GREEN}Prometheus rechargé (vérifier : http://localhost:9090/config)${NC}"
        ;;

    disk)
        echo -e "${BLUE}Utilisation disque des volumes Docker :${NC}"
        docker system df -v | grep -A 20 "VOLUME NAME"
        echo ""
        echo -e "${BLUE}Espace disque global :${NC}"
        df -h /
        ;;

    test-alert)
        echo -e "${BLUE}Envoi d'une alerte de test (warning → email seulement, délai ~30s group_wait)...${NC}"
        if ! post_test_alert_to_alertmanager warning; then
            exit 1
        fi
        echo -e "${GREEN}Requête acceptée par Alertmanager.${NC}"
        echo -e "${YELLOW}Pas d'email ? Vérifie SMTP : docker compose logs --tail=80 alertmanager${NC}"
        ;;

    test-alert-critical)
        echo -e "${BLUE}Envoi d'une alerte de test (critical → email + Telegram, délai ~15s group_wait)...${NC}"
        if ! post_test_alert_to_alertmanager critical; then
            exit 1
        fi
        echo -e "${GREEN}Requête acceptée par Alertmanager.${NC}"
        echo -e "${YELLOW}Pas de notification ? docker compose logs --tail=80 alertmanager alertmanager_telegram${NC}"
        ;;

    *)
        show_help
        ;;
esac
