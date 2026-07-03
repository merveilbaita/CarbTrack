"""Présence des chauffeurs : silence GPS et statut en ligne.

Grâce au mode veille de l'app (signal toutes les 5 min même à l'arrêt),
un silence prolongé pendant les heures de travail est anormal : téléphone
éteint, app tuée, ou longue zone sans réseau (dans ce cas les points
arrivent en retard et l'alerte est levée automatiquement à leur arrivée).

Pas de worker dédié : la vérification est déclenchée par le polling du
dashboard et par l'ingestion des positions, avec un anti-rebond en cache.
"""
from datetime import timedelta

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone

from .models import Alert, Driver, Position
from .realtime import broadcast_alert

# Seuils du statut affiché (minutes depuis le dernier signal).
ONLINE_MAX_MIN = 7      # veille = 1 signal / 5 min, + marge
OFFLINE_AFTER_MIN = 60

_CHECK_CACHE_KEY = "presence:last_check"
_CHECK_EVERY_S = 60


def status_for(age_min: float | None) -> str:
    """'online' / 'silent' / 'offline' pour l'affichage dashboard."""
    if age_min is None:
        return "offline"
    if age_min <= ONLINE_MAX_MIN:
        return "online"
    if age_min <= OFFLINE_AFTER_MIN:
        return "silent"
    return "offline"


def in_work_hours(now=None) -> bool:
    h = timezone.localtime(now or timezone.now()).hour
    return settings.WORK_START_HOUR <= h < settings.WORK_END_HOUR


def resolve_silence(driver):
    """Signal revenu : acquitte les alertes de silence encore ouvertes."""
    Alert.objects.filter(
        driver=driver, kind=Alert.KIND_SILENCE, acked_at__isnull=True
    ).update(acked_at=timezone.now())


def check_silences(force=False):
    """Lève une alerte par chauffeur silencieux depuis SILENCE_AFTER_MIN.

    Anti-rebond global (60 s) pour ne pas répéter le travail à chaque ping
    ou chaque polling. Une seule alerte ouverte par chauffeur à la fois.
    """
    if not force:
        if cache.get(_CHECK_CACHE_KEY):
            return
        cache.set(_CHECK_CACHE_KEY, 1, _CHECK_EVERY_S)

    now = timezone.now()
    if not in_work_hours(now):
        return

    threshold = now - timedelta(minutes=settings.SILENCE_AFTER_MIN)
    for driver in Driver.objects.filter(active=True, role=Driver.ROLE_DRIVER):
        last = (
            Position.objects.filter(driver=driver)
            .order_by("-recorded_at")
            .only("recorded_at")
            .first()
        )
        # Jamais émis = pas encore équipé : rien à signaler.
        if last is None or last.recorded_at > threshold:
            continue
        already_open = Alert.objects.filter(
            driver=driver, kind=Alert.KIND_SILENCE, acked_at__isnull=True
        ).exists()
        if already_open:
            continue
        age_min = int((now - last.recorded_at).total_seconds() / 60)
        alert = Alert.objects.create(
            driver=driver,
            vehicle=driver.vehicle,
            kind=Alert.KIND_SILENCE,
            message=(
                f"Aucun signal depuis {age_min} min "
                "(téléphone éteint, app arrêtée ou hors réseau)"
            ),
        )
        broadcast_alert({
            "id": alert.id,
            "driver": driver.name,
            "vehicle": driver.vehicle.identifier if driver.vehicle else None,
            "message": alert.message,
            "created_at": alert.created_at.isoformat(),
        })
