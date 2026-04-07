#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# manage.sh — Commandes de gestion quotidienne
# Usage : bash manage.sh [commande]
# ═══════════════════════════════════════════════════════════════

set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    echo "  bash scripts/manage.sh test-alert    Envoyer une alerte de test"
    echo "  bash scripts/manage.sh sync-secrets    Régénérer le secret SMTP Alertmanager depuis .env"
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
        BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo -e "${BLUE}Sauvegarde dans $BACKUP_DIR...${NC}"

        # Grafana (dashboards, users, etc.)
        docker run --rm \
            -v monitoring_grafana_data:/data \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf /backup/grafana.tar.gz -C /data .
        echo -e "${GREEN}Grafana sauvegardé.${NC}"

        # Prometheus (métriques)
        docker run --rm \
            -v monitoring_prometheus_data:/data \
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
        echo -e "${BLUE}Envoi d'une alerte de test vers Alertmanager...${NC}"
        curl -s -X POST http://localhost:9093/api/v1/alerts \
            -H 'Content-Type: application/json' \
            -d '[{
                "labels": {
                    "alertname": "TestAlerte",
                    "severity": "warning",
                    "project": "test"
                },
                "annotations": {
                    "summary": "Alerte de test CodeLab Monitoring",
                    "description": "Ceci est une alerte de test pour vérifier la configuration."
                }
            }]'
        echo -e "${GREEN}Alerte envoyée. Vérifier l'email/Telegram.${NC}"
        ;;

    *)
        show_help
        ;;
esac
