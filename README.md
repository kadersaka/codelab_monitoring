# CodeLab Monitoring Stack
> Loki + Grafana + Prometheus + Alertmanager  
> Serveur : Peramix (8 vCPU / 24 GB RAM / 200 GB NVMe)

---

## Architecture

```
Tous tes serveurs (OCI, Hostinger, etc.)
      │
      ├── Promtail      → pousse les logs vers Loki
      └── Node Exporter → expose les métriques système
             │
             ▼ (HTTPS + Basic Auth)
      ┌──────────────────────────────┐
      │       Serveur Peramix        │
      │                              │
      │  Loki           (logs)       │
      │  Prometheus     (métriques)  │
      │  Grafana        (UI)         │
      │  Alertmanager   (alertes)    │
      │  (volumes Docker sur disque) │
      │  Portainer      (Docker UI)  │
      └──────────────────────────────┘
```

---

## Installation

### Étape 1 — Préparer le serveur Peramix

```bash
# Cloner / copier ce dossier sur Peramix
scp -r monitoring/ root@206.183.131.155:/opt/monitoring
ssh root@206.183.131.155
cd /opt/monitoring
```

### Étape 2 — Configurer les variables

```bash
cp .env.example .env
nano .env   # Remplir toutes les valeurs
```

**Variables obligatoires à changer dans `.env` :**

| Variable | Description |
|----------|-------------|
| `GRAFANA_DOMAIN` | `monitoring.codelab.bj` |
| `GRAFANA_ADMIN_PASSWORD` | Mot de passe admin Grafana |
| `LOKI_PASSWORD_PAYGATE` | Mot de passe Loki pour PayGate |
| `SMTP_*` | Config email pour les alertes |
| `TELEGRAM_BOT_TOKEN` | Token bot Telegram |
| `TELEGRAM_CHAT_ID` | ID du chat Telegram pour les alertes |

### Étape 3 — Lancer l'installation

```bash
chmod +x scripts/install.sh
bash scripts/install.sh
```

### Étape 4 — Configurer Nginx Proxy Manager

1. Accéder à `http://206.183.131.155:81`
2. Login par défaut : `admin@example.com` / `changeme`
3. **Changer le mot de passe immédiatement**
4. Créer les Proxy Hosts :

| Domain | Forward Host | Forward Port | SSL |
|--------|-------------|--------------|-----|
| `monitoring.codelab.bj` | `grafana` | `3000` | Let's Encrypt ✅ |
| `portainer.codelab.bj` | `portainer` | `9443` | Let's Encrypt ✅ |

5. Pour Loki (reçoit les logs des agents distants), ajouter un Proxy Host :

| Domain | Forward Host | Forward Port | Auth |
|--------|-------------|--------------|------|
| `loki.codelab.bj` | `loki` | `3100` | Basic Auth (Access List NPM) ✅ |

### Étape 5 — Configurer Prometheus

Éditer `configs/prometheus.yml` et remplacer les placeholders :

```bash
nano configs/prometheus.yml
# Remplacer <IP_SERVEUR_OCI> par l'IP réelle de ton serveur OCI
# Remplacer <IP_SERVEUR_HOSTINGER_B> par l'IP de ton serveur Hostinger
```

Recharger Prometheus :
```bash
bash scripts/manage.sh reload-prom
```

---

## Ajouter un nouveau serveur

### Sur le nouveau serveur

```bash
# Copier et lancer le script d'installation agent
scp scripts/install-agent.sh root@IP_NOUVEAU_SERVEUR:/tmp/
ssh root@IP_NOUVEAU_SERVEUR
bash /tmp/install-agent.sh
# Suivre les instructions interactives
```

### Sur Peramix — mettre à jour Prometheus

```bash
nano configs/prometheus.yml
# Ajouter le nouveau serveur dans la section scrape_configs
```

```yaml
- job_name: node_nouveau_serveur
  static_configs:
    - targets: ['IP_NOUVEAU_SERVEUR:9100']
      labels:
        server: nom-du-serveur
        project: nom-du-projet
```

```bash
bash scripts/manage.sh reload-prom
```

### Sur Peramix — ajouter le tenant Loki

```bash
nano configs/retention-overrides.yml
# Ajouter le nouveau tenant
```

```yaml
  nom-du-projet:
    retention_period: 90d
    ingestion_rate_mb: 5
```

```bash
docker compose restart loki
```

---

## Ajouter un nouveau projet Django

1. **Intégration Django** : voir `django-integration.py`

2. **Datasource Loki** dans Grafana :
   - Settings → Data Sources → Add
   - Type: Loki, URL: `http://loki:3100`
   - Header: `X-Scope-OrgID` = `nom-du-projet`

3. **Importer les dashboards** depuis grafana.com :
   - Node Exporter Full : ID `1860`
   - Django Prometheus : ID `9528`
   - Loki Logs : ID `13639`

---

## Commandes de gestion quotidienne

```bash
# Statut de tous les services
bash scripts/manage.sh status

# Voir les logs d'un service
bash scripts/manage.sh logs grafana
bash scripts/manage.sh logs loki

# Redémarrer un service
bash scripts/manage.sh restart grafana

# Mettre à jour toutes les images
bash scripts/manage.sh update

# Sauvegarder les données
bash scripts/manage.sh backup

# Recharger Prometheus sans redémarrage
bash scripts/manage.sh reload-prom

# Voir l'usage disque
bash scripts/manage.sh disk

# Tester les alertes
bash scripts/manage.sh test-alert
```

---

## URLs d'accès

| Service | URL | Notes |
|---------|-----|-------|
| Grafana | `https://monitoring.codelab.bj` | Dashboards + Logs |
| Loki | `https://loki.codelab.bj` | Push logs (Promtail distant) + Basic Auth |
| Portainer | `https://portainer.codelab.bj` | Gestion Docker |
| NPM | `http://206.183.131.155:81` | Config reverse proxy |

---

## Allocation mémoire estimée

| Service | RAM allouée |
|---------|-------------|
| Loki | 4 GB |
| Prometheus | 2 GB |
| Grafana | 1 GB |
| Alertmanager | 256 MB |
| Promtail | 256 MB |
| Node Exporter | 128 MB |
| cAdvisor | 256 MB |
| Portainer | 256 MB |
| Nginx Proxy | 256 MB |
| Relais Telegram | 128 MB |
| **Total** | **~8.6 GB** |
| **Libre** | **~15.4 GB** |

---

## Telegram (Alertmanager)

Les alertes **`severity: critical`** (receivers `paygate_critical` et `critical_all`) envoient un **email** et appellent le service Docker **`alertmanager_telegram`**, qui poste sur l’API Telegram. Configure **`TELEGRAM_BOT_TOKEN`** et **`TELEGRAM_CHAT_ID`** dans **`.env`**, puis redémarre : `docker compose up -d alertmanager_telegram alertmanager`.

Pour les alertes **Grafana** (optionnel), ajoute un canal **Telegram** dans l’interface Grafana avec le même bot.

---

## Sécurité

- Tous les services internes sont sur `127.0.0.1` uniquement
- Seuls les ports 80, 443 et 22 sont ouverts sur le firewall
- Fail2Ban protège le SSH
- TLS Let's Encrypt sur toutes les URLs publiques
- Basic Auth sur l'endpoint Loki pour les agents distants
- Les credentials Loki sont différents par projet (isolation)

---

## Dépannage

### Docker Snap (`open ... docker-compose.yml: no such file` même avec un chemin absolu)

Le **Docker Snap** ne peut souvent pas lire les fichiers sous `/opt`. Le fichier existe sur le disque, mais le client Compose du Snap ne le voit pas.

**Recommandé en production** : remplacer le Snap par **Docker Engine** (paquet officiel) :

```bash
snap remove docker
curl -fsSL https://get.docker.com | sh
```

Puis :

```bash
cd /opt/codelab_monitoring
bash scripts/manage.sh update
bash scripts/dc ps
```

(`dc` dans le README = exécute **`bash scripts/dc`**, pas la commande système `dc` des calculatrices.)

### Commandes utiles

```bash
# Voir les logs d'un service en erreur
bash scripts/manage.sh logs loki

# Vérifier que Loki accepte les logs
curl -s http://localhost:3100/ready

# Vérifier que Prometheus scrape bien
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health

# Tester la connexion Promtail → Loki depuis un serveur distant
curl -u "paygate:LOKI_PASSWORD" \
     -H "X-Scope-OrgID: paygate" \
     https://loki.codelab.bj/loki/api/v1/labels
```
