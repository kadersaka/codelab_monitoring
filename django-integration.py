# ═══════════════════════════════════════════════════════════════
# Intégration Django — Monitoring
# Ce fichier montre exactement ce qu'il faut ajouter dans ton
# projet Django (PayGate ou autre) pour l'intégrer au monitoring
# ═══════════════════════════════════════════════════════════════


# ────────────────────────────────────────────────────────────────
# 1. requirements/base.txt — Ajouter ces lignes
# ────────────────────────────────────────────────────────────────
# django-prometheus==0.3.1       # Métriques Django → Prometheus
# sentry-sdk[django]==1.39.1     # Exceptions → Sentry self-hosted
# python-logging-loki==0.3.1     # Logs directs → Loki (optionnel)


# ────────────────────────────────────────────────────────────────
# 2. config/settings/base.py — Modifications à apporter
# ────────────────────────────────────────────────────────────────

DJANGO_PROMETHEUS_EXPORT_MIGRATIONS = False

INSTALLED_APPS = [
    # Ajouter EN PREMIER dans la liste
    'django_prometheus',
    # ... tes autres apps
]

MIDDLEWARE = [
    # Ajouter EN PREMIER
    'django_prometheus.middleware.PrometheusBeforeMiddleware',
    # ... tes autres middlewares ...
    # Ajouter EN DERNIER
    'django_prometheus.middleware.PrometheusAfterMiddleware',
]


# ────────────────────────────────────────────────────────────────
# 3. config/settings/production.py — Sentry + Logging Loki
# ────────────────────────────────────────────────────────────────

import sentry_sdk
from sentry_sdk.integrations.django import DjangoIntegration
from sentry_sdk.integrations.celery import CeleryIntegration
from sentry_sdk.integrations.redis import RedisIntegration
from sentry_sdk.integrations.logging import LoggingIntegration
import logging

# Sentry — envoyer uniquement les ERROR et CRITICAL
sentry_logging = LoggingIntegration(
    level=logging.ERROR,
    event_level=logging.ERROR,
)

sentry_sdk.init(
    dsn=env('SENTRY_DSN'),  # Récupéré depuis ton Sentry self-hosted sur Peramix
    integrations=[
        DjangoIntegration(),
        CeleryIntegration(),
        RedisIntegration(),
        sentry_logging,
    ],
    traces_sample_rate=0.1,     # 10% des requêtes tracées (performance)
    profiles_sample_rate=0.05,  # 5% profilés
    send_default_pii=False,     # CRITIQUE : ne pas envoyer données personnelles
    environment=env('DJANGO_ENV', default='production'),
    release=env('APP_VERSION', default='1.0.0'),
    # Filtrer les données sensibles
    before_send=lambda event, hint: filter_sentry_event(event),
)

def filter_sentry_event(event):
    """Supprimer les données sensibles avant envoi à Sentry."""
    sensitive_keys = {'password', 'api_key', 'api_secret', 'token', 
                      'authorization', 'x-api-key', 'x-api-secret'}
    
    if 'request' in event:
        headers = event['request'].get('headers', {})
        for key in list(headers.keys()):
            if key.lower() in sensitive_keys:
                headers[key] = '[Filtered]'
        
        data = event['request'].get('data', {})
        if isinstance(data, dict):
            for key in list(data.keys()):
                if key.lower() in sensitive_keys:
                    data[key] = '[Filtered]'
    
    return event


# ────────────────────────────────────────────────────────────────
# 4. config/urls.py — Endpoint /metrics pour Prometheus
# ────────────────────────────────────────────────────────────────

from django.urls import path, include

urlpatterns = [
    # ... tes URLs existantes ...

    # Métriques Prometheus — protéger par IP si exposé publiquement
    path('metrics', include('django_prometheus.urls')),
]


# ────────────────────────────────────────────────────────────────
# 5. apps/transactions/metrics.py — Métriques custom PayGate
# Créer ce fichier et importer dans apps.py (ready())
# ────────────────────────────────────────────────────────────────

from prometheus_client import Counter, Histogram, Gauge

# Compteur de transactions par type, statut, partenaire, réseau, pays
paygate_transactions_total = Counter(
    'paygate_transactions_total',
    'Nombre total de transactions',
    ['tx_type', 'status', 'partner', 'network', 'country']
)

# Distribution des montants
paygate_transaction_amount = Histogram(
    'paygate_transaction_amount',
    'Montant des transactions',
    ['tx_type', 'currency'],
    buckets=[1000, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000]
)

# Transactions actuellement en PROCESSING
paygate_processing_transactions = Gauge(
    'paygate_processing_transactions',
    'Transactions en état PROCESSING',
    ['partner']
)

# Compteur de timeouts par partenaire
paygate_payout_timeout_total = Counter(
    'paygate_payout_timeout_total',
    'Nombre de timeouts payout par partenaire',
    ['partner', 'network']
)

# Durée des appels API vers les partenaires
paygate_provider_request_duration = Histogram(
    'paygate_provider_request_duration_seconds',
    'Durée des appels HTTP vers les agrégateurs partenaires',
    ['partner', 'endpoint', 'status'],
    buckets=[0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0]
)

# Solde des wallets par devise (pour monitoring)
paygate_wallet_total_balance = Gauge(
    'paygate_wallet_total_balance',
    'Somme des soldes wallets par devise',
    ['currency']
)


# ────────────────────────────────────────────────────────────────
# 6. Usage dans le code TransactionService
# ────────────────────────────────────────────────────────────────

# Dans TransactionService, après chaque transaction :

# from apps.transactions.metrics import (
#     paygate_transactions_total,
#     paygate_transaction_amount,
#     paygate_payout_timeout_total,
# )

# Après succès d'une transaction :
# paygate_transactions_total.labels(
#     tx_type=tx.tx_type,
#     status=tx.status,
#     partner=tx.aggregator_partner.code,
#     network=tx.network,
#     country=tx.country_code,
# ).inc()

# paygate_transaction_amount.labels(
#     tx_type=tx.tx_type,
#     currency=tx.currency.code,
# ).observe(float(tx.amount))

# En cas de timeout payout :
# paygate_payout_timeout_total.labels(
#     partner=partner.code,
#     network=data['network'],
# ).inc()


# ────────────────────────────────────────────────────────────────
# 7. Celery task pour mettre à jour les métriques de solde
# Lancer toutes les 5 minutes via Celery Beat
# ────────────────────────────────────────────────────────────────

# @shared_task
# def update_wallet_metrics():
#     from apps.wallets.models import Wallet
#     from django.db.models import Sum
#     from apps.transactions.metrics import paygate_wallet_total_balance
#
#     balances = Wallet.objects.values('currency__code').annotate(
#         total=Sum('balance')
#     )
#     for row in balances:
#         paygate_wallet_total_balance.labels(
#             currency=row['currency__code']
#         ).set(float(row['total'] or 0))
