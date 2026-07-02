"""Journal d'exploitation, alimenté à l'ingestion des positions.

Pour chaque nouvelle position (comparée à la précédente du même chauffeur) :
- transitions de zone (Geofence)  → Event zone_enter / zone_exit
- arrêt prolongé hors zone        → Event stop (ouvert puis clôturé)
- excès de vitesse (transition)   → Alert speeding (retournée pour broadcast)

Les points arrivent triés par horodatage (y compris le rattrapage offline),
ce qui permet une détection en flux sans état en mémoire.
"""
import math

from django.conf import settings
from django.contrib.gis.db.models.functions import Distance

from .models import Alert, Event, Geofence

# Sous ce seuil (m/s ≈ 2,9 km/h), le véhicule est considéré à l'arrêt.
_STOP_SPEED_MS = 0.8
# Rayon (m) au-delà duquel on considère que le véhicule a quitté son point d'arrêt.
_STOP_RADIUS_M = 60
# Une précision GPS pire que ça rend vitesse/position trop bruitées pour décider.
_MAX_ACCURACY_M = 50


def haversine_m(lat1, lng1, lat2, lng2) -> float:
    """Distance en mètres entre deux points (suffisant pour nos seuils)."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def zones_at(point) -> dict:
    """Zones actives contenant `point` — {id: Geofence}."""
    hits = {}
    qs = Geofence.objects.filter(active=True).annotate(d=Distance("center", point))
    for gf in qs:
        if float(gf.d.m) <= gf.radius_m:
            hits[gf.pk] = gf
    return hits


def process_position(driver, pos, prev):
    """Met à jour le journal pour `pos`. Retourne une Alert à diffuser, ou None.

    `prev` est la Position précédente du chauffeur (ou None).
    """
    cur_zones = zones_at(pos.point)
    _zone_transitions(driver, pos, prev, cur_zones)
    _stop_tracking(driver, pos, prev, cur_zones)
    return _speeding(driver, pos, prev)


def _zone_transitions(driver, pos, prev, cur_zones):
    prev_zones = zones_at(prev.point) if prev is not None else {}
    for pk, gf in cur_zones.items():
        if pk not in prev_zones:
            Event.objects.create(
                driver=driver, vehicle=pos.vehicle, geofence=gf, position=pos,
                kind=Event.KIND_ZONE_ENTER, started_at=pos.recorded_at,
                message=f"Arrivé à {gf.name}",
            )
    for pk, gf in prev_zones.items():
        if pk not in cur_zones:
            Event.objects.create(
                driver=driver, vehicle=pos.vehicle, geofence=gf, position=pos,
                kind=Event.KIND_ZONE_EXIT, started_at=pos.recorded_at,
                message=f"Quitté {gf.name}",
            )


def _stop_tracking(driver, pos, prev, cur_zones):
    """Ouvre/clôture un Event 'stop'. Les arrêts courts sont supprimés à la clôture.

    Un arrêt dans une zone nommée n'est pas journalisé (stationner à la base
    vie ou au chantier est normal — l'arrivée en zone est déjà l'événement).
    """
    stopped = (pos.speed or 0) < _STOP_SPEED_MS
    open_stop = (
        Event.objects.filter(driver=driver, kind=Event.KIND_STOP, ended_at__isnull=True)
        .order_by("-started_at")
        .first()
    )

    if open_stop is not None:
        anchor = open_stop.position
        moved = (
            anchor is not None
            and haversine_m(anchor.point.y, anchor.point.x, pos.point.y, pos.point.x)
            > _STOP_RADIUS_M
        )
        if not stopped or moved:
            open_stop.ended_at = pos.recorded_at
            dur_min = (open_stop.ended_at - open_stop.started_at).total_seconds() / 60
            if dur_min < settings.STOP_MIN_MINUTES:
                open_stop.delete()
            else:
                open_stop.message = f"Arrêt de {dur_min:.0f} min"
                open_stop.save(update_fields=["ended_at", "message"])
        return

    if prev is None or not stopped or cur_zones:
        return
    if (prev.speed or 0) >= _STOP_SPEED_MS:
        return
    if (pos.accuracy or 0) > _MAX_ACCURACY_M:
        return
    gap_s = (pos.recorded_at - prev.recorded_at).total_seconds()
    near_prev = (
        haversine_m(prev.point.y, prev.point.x, pos.point.y, pos.point.x) < _STOP_RADIUS_M
    )
    if 0 < gap_s <= 600 and near_prev:
        Event.objects.create(
            driver=driver, vehicle=pos.vehicle, position=pos,
            kind=Event.KIND_STOP, started_at=prev.recorded_at,
            message="Arrêt en cours…",
        )


def _speeding(driver, pos, prev):
    """Alerte à la transition sous→au-dessus de la limite (pas de spam)."""
    if (pos.accuracy or 0) > _MAX_ACCURACY_M:
        return None
    limit = settings.SPEED_LIMIT_KMH
    cur_kmh = (pos.speed or 0) * 3.6
    prev_kmh = ((prev.speed or 0) * 3.6) if prev is not None else 0.0
    if cur_kmh > limit and prev_kmh <= limit:
        return Alert.objects.create(
            driver=driver, vehicle=pos.vehicle, position=pos,
            kind=Alert.KIND_SPEEDING,
            message=f"Vitesse {cur_kmh:.0f} km/h (limite {limit:.0f} km/h)",
        )
    return None
