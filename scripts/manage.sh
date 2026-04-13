#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# manage.sh — Commandes de gestion quotidienne
# Usage : bash manage.sh [commande]
# ═══════════════════════════════════════════════════════════════

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

dc() {
    local compose_file="${ROOT_DIR}/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        echo -e "${RED}Fichier introuvable : ${compose_file}${NC}" >&2
        exit 1
    fi
    docker compose -f "$compose_file" --project-directory "${ROOT_DIR}" "$@"
}

# Préfixe des volumes = nom du projet Compose
compose_volume_prefix() {
    local cid proj from_env
    local -a vol_hint

    # 1) Label officiel depuis le conteneur
    for svc in grafana prometheus; do
        cid="$(dc ps -q "$svc" 2>/dev/null | head -n1 || true)"
        if [[ -n "$cid" ]]; then
            proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)"
            if [[ -n "$proj" ]]; then
                echo "$proj"
                return
            fi
        fi
    done

    # 2) Déduire depuis le volume grafana_data
    mapfile -t vol_hint < <(docker volume ls -q 2>/dev/null | grep '_grafana_data' || true)
    if [[ ${#vol_hint[@]} -eq 1 ]]; then
        echo "${vol_hint[0]%_grafana_data}"
        return
    fi

    # 3) COMPOSE_PROJECT_NAME dans .env
    from_env=""
    if [[ -f .env ]]; then
        from_env="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[\"'\'']//;s/[\"'\'']$//' || true)"
    fi
    if [[ -n "${from_env}" ]]; then
        echo "${from_env}"
        return
    fi

    # 4) Nom du dossier
    basename "$(pwd)"
}

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ALERTMANAGER_API_V2="${ALERTMANAGER_API_V2:-http://127.0.0.1:9093/alertmanager/api/v2/alerts}"

post_test_alert_to_alertmanager() {
    local severity="$1"
    local tmp http_code
    tmp=$(mktemp)
    local ends_at
    ends_at=$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+10M '+%Y-%m-%dT%H:%M:%SZ')
    if ! http_code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "${ALERTMANAGER_API_V2}" \
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
            },
            \"endsAt\": \"${ends_at}\"
        }]"); then
        rm -f "$tmp"
        echo -e "${RED}Échec : impossible de joindre Alertmanager (${ALERTMANAGER_API_V2})${NC}" >&2
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
    echo "  bash scripts/manage.sh status              Statut de tous les services"
    echo "  bash scripts/manage.sh logs [svc]          Logs d'un service (ex: loki, grafana)"
    echo "  bash scripts/manage.sh restart [svc]       Redémarrer un service"
    echo "  bash scripts/manage.sh update              Mettre à jour les images Docker"
    echo "  bash scripts/manage.sh backup              Sauvegarder les volumes"
    echo "  bash scripts/manage.sh reload-prom         Recharger la config Prometheus"
    echo "  bash scripts/manage.sh disk                Utilisation disque des volumes"
    echo "  bash scripts/manage.sh test-alert          Alerte test warning (email)"
    echo "  bash scripts/manage.sh test-alert-critical Alerte test critical (email + Telegram)"
    echo "  bash scripts/manage.sh sync-secrets        Régénérer le secret SMTP depuis .env"
    echo ""
}

case "${1:-help}" in

    status)
        echo -e "${BLUE}Statut des services :${NC}"
        dc ps
        echo ""
        echo -e "${BLUE}Utilisation des ressources :${NC}"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
        ;;

    logs)
        SERVICE="${2:-grafana}"
        echo -e "${BLUE}Logs de $SERVICE (Ctrl+C pour quitter) :${NC}"
        dc logs -f --tail=100 "$SERVICE"
        ;;

    restart)
        SERVICE="${2:-}"
        if [ -z "$SERVICE" ]; then
            echo -e "${YELLOW}Usage : bash scripts/manage.sh restart [service]${NC}"
            exit 1
        fi
        echo -e "${BLUE}Redémarrage de $SERVICE...${NC}"
        dc restart "$SERVICE"
        echo -e "${GREEN}$SERVICE redémarré.${NC}"
        ;;

    sync-secrets)
        bash scripts/sync-secrets-from-env.sh
        echo -e "${GREEN}Secrets synchronisés.${NC}"
        ;;

    update)
        echo -e "${BLUE}Mise à jour des images Docker...${NC}"
        bash scripts/sync-secrets-from-env.sh
        dc pull
        dc up -d --remove-orphans
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
                docker volume ls 2>/dev/null | grep -E 'grafana|prometheus' >&2 || docker volume ls >&2
                exit 1
            fi
        done

        BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo -e "${BLUE}Sauvegarde dans $BACKUP_DIR...${NC}"

        docker run --rm \
            -v "${GVOL}:/data" \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf /backup/grafana.tar.gz -C /data .
        echo -e "${GREEN}Grafana sauvegardé.${NC}"

        docker run --rm \
            -v "${PVOL}:/data" \
            -v "$(pwd)/$BACKUP_DIR":/backup \
            alpine tar czf /backup/prometheus.tar.gz -C /data .
        echo -e "${GREEN}Prometheus sauvegardé.${NC}"

        tar czf "$BACKUP_DIR/configs.tar.gz" configs/
        echo -e "${GREEN}Configs sauvegardées.${NC}"
        echo -e "${GREEN}Sauvegarde complète dans : $BACKUP_DIR${NC}"
        ls -lh "$BACKUP_DIR"
        ;;

    reload-prom)
        echo -e "${BLUE}Rechargement de la configuration Prometheus...${NC}"
        curl -s -X POST http://localhost:9090/-/reload
        echo -e "${GREEN}Prometheus rechargé.${NC}"
        ;;

    disk)
        echo -e "${BLUE}Utilisation disque des volumes Docker :${NC}"
        docker system df -v | grep -A 20 "VOLUME NAME"
        echo ""
        echo -e "${BLUE}Espace disque global :${NC}"
        df -h /
        ;;

    test-alert)
        echo -e "${BLUE}Envoi d'une alerte de test (warning)...${NC}"
        if ! post_test_alert_to_alertmanager warning; then exit 1; fi
        echo -e "${GREEN}Requête acceptée par Alertmanager.${NC}"
        ;;

    test-alert-critical)
        echo -e "${BLUE}Envoi d'une alerte de test (critical)...${NC}"
        if ! post_test_alert_to_alertmanager critical; then exit 1; fi
        echo -e "${GREEN}Requête acceptée par Alertmanager.${NC}"
        ;;

    *)
        show_help
        ;;
esac
