"""Analyse d'une journée de positions GPS : distance, conduite, arrêts, vitesses.

Le GPS « respire » même à l'arrêt (bruit de quelques mètres) : sans filtrage,
un camion garé toute la nuit accumule des kilomètres fantômes. D'où les seuils
sur la précision, la longueur des segments et la vitesse.
"""
from datetime import datetime, time, timedelta

from django.conf import settings
from django.utils import timezone

from .journal import haversine_m
from .models import Position

# Points ignorés au-delà de cette imprécision (m).
_MAX_ACCURACY_M = 60
# Un déplacement plus court que ça entre deux pings est du bruit (m).
_MIN_SEGMENT_M = 15
# Un segment ne compte comme "conduite" qu'au-dessus de cette vitesse (km/h).
_MIN_DRIVE_KMH = 4
# Au-delà de ce trou entre deux pings, on ne compte pas le temps (s).
_MAX_GAP_S = 600
# Rayon de regroupement d'un arrêt (m).
_STOP_RADIUS_M = 60


def day_bounds(day):
    """Bornes datetime aware (fuseau du projet) de la journée `day`."""
    start = timezone.make_aware(datetime.combine(day, time.min))
    return start, start + timedelta(days=1)


def _iso_local(dt) -> str:
    """ISO en heure locale du projet (les datetimes sont stockés en UTC)."""
    return timezone.localtime(dt).isoformat()


def analyze_day(driver, day, include_points=True) -> dict:
    """Statistiques du jour pour un chauffeur ; `points` optionnels (replay)."""
    start, end = day_bounds(day)
    qs = (
        Position.objects.filter(
            driver=driver, recorded_at__gte=start, recorded_at__lt=end
        )
        .order_by("recorded_at")
        .only("point", "recorded_at", "speed", "accuracy")
    )
    pts = [p for p in qs if (p.accuracy or 0) <= _MAX_ACCURACY_M]

    if not pts:
        return {
            "points": [] if include_points else None,
            "distance_km": 0.0, "driving_min": 0.0,
            "first_ts": None, "last_ts": None,
            "max_kmh": 0.0, "avg_kmh": 0.0,
            "stops": [], "ping_count": 0,
        }

    distance_m = 0.0
    driving_s = 0.0
    max_kmh = 0.0
    for prev, cur in zip(pts, pts[1:]):
        seg_m = haversine_m(prev.point.y, prev.point.x, cur.point.y, cur.point.x)
        dt_s = (cur.recorded_at - prev.recorded_at).total_seconds()
        if seg_m >= _MIN_SEGMENT_M:
            distance_m += seg_m
        if 0 < dt_s <= _MAX_GAP_S and (seg_m / dt_s) * 3.6 >= _MIN_DRIVE_KMH:
            driving_s += dt_s
    for p in pts:
        max_kmh = max(max_kmh, (p.speed or 0) * 3.6)

    driving_h = driving_s / 3600
    avg_kmh = (distance_m / 1000) / driving_h if driving_h > 0.05 else 0.0

    return {
        "points": [
            {
                "lat": p.point.y,
                "lng": p.point.x,
                "ts": _iso_local(p.recorded_at),
                "kmh": round((p.speed or 0) * 3.6, 1),
            }
            for p in pts
        ] if include_points else None,
        "distance_km": round(distance_m / 1000, 2),
        "driving_min": round(driving_s / 60),
        "first_ts": _iso_local(pts[0].recorded_at),
        "last_ts": _iso_local(pts[-1].recorded_at),
        "max_kmh": round(max_kmh),
        "avg_kmh": round(avg_kmh, 1),
        "stops": _detect_stops(pts),
        "ping_count": len(pts),
    }


def _detect_stops(pts) -> list[dict]:
    """Regroupe les points immobiles (< _STOP_RADIUS_M autour d'une ancre)
    pendant au moins STOP_MIN_MINUTES."""
    min_s = settings.STOP_MIN_MINUTES * 60
    stops = []
    anchor = None  # (position ancre, ts de début)

    def flush(last_ts):
        if anchor is None:
            return
        dur = (last_ts - anchor[1]).total_seconds()
        if dur >= min_s:
            stops.append({
                "lat": anchor[0].point.y,
                "lng": anchor[0].point.x,
                "start": _iso_local(anchor[1]),
                "end": _iso_local(last_ts),
                "minutes": round(dur / 60),
            })

    prev_ts = None
    for p in pts:
        if anchor is not None:
            gap = (p.recorded_at - prev_ts).total_seconds() if prev_ts else 0
            moved = haversine_m(
                anchor[0].point.y, anchor[0].point.x, p.point.y, p.point.x
            ) > _STOP_RADIUS_M
            if moved or gap > _MAX_GAP_S:
                flush(prev_ts)
                anchor = (p, p.recorded_at)
        else:
            anchor = (p, p.recorded_at)
        prev_ts = p.recorded_at
    flush(prev_ts)
    return stops
