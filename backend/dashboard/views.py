"""Dashboard web (staff). Pages + endpoints JSON protégés par session Django."""
import csv
import json
import math
import urllib.error
import urllib.parse
import urllib.request

from django.contrib.auth.decorators import login_required
from django.contrib.gis.geos import GEOSGeometry, Point
from django.http import HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, render
from django.utils import timezone
from django.utils.dateparse import parse_date
from django.views.decorators.http import require_http_methods

from fleet.models import (
    Alert, Appro, Assignment, Driver, Event, Geofence, Position, Route,
)
from fleet.presence import check_silences, status_for
from fleet.tracking_stats import analyze_day, day_bounds


# ── Pages ───────────────────────────────────────────────────────────────────

@login_required
def map_view(request):
    return render(request, "dashboard/map.html", {"active": "map"})


@login_required
def routes_view(request):
    drivers = list(Driver.objects.filter(active=True).order_by("name").values("id", "name"))
    return render(request, "dashboard/routes.html", {"active": "routes", "drivers": drivers})


@login_required
def alerts_view(request):
    return render(request, "dashboard/alerts.html", {"active": "alerts"})


@login_required
def appros_view(request):
    drivers = Driver.objects.order_by("name").values("id", "name")
    return render(request, "dashboard/appros.html",
                  {"active": "appros", "drivers": list(drivers)})


@login_required
def history_view(request):
    drivers = list(
        Driver.objects.filter(active=True).select_related("vehicle")
        .order_by("name")
    )
    ctx = {
        "active": "history",
        "drivers": [
            {"id": d.id, "name": d.name,
             "vehicle": d.vehicle.identifier if d.vehicle else None}
            for d in drivers
        ],
    }
    return render(request, "dashboard/history.html", ctx)


@login_required
def events_view(request):
    return render(request, "dashboard/events.html", {"active": "events"})


@login_required
def zones_view(request):
    return render(request, "dashboard/zones.html", {"active": "zones"})


# ── API JSON (session staff) ────────────────────────────────────────────────

@login_required
def api_latest(request):
    """Dernière position de chaque chauffeur (+ statut de présence)
    + compteur d'alertes ouvertes. Déclenche aussi la vérification des
    silences GPS (anti-rebond côté presence)."""
    check_silences()
    now = timezone.now()
    latest = {}
    qs = (
        Position.objects.select_related("driver", "vehicle")
        .order_by("driver_id", "-recorded_at")
    )
    for pos in qs:
        if pos.driver_id in latest:
            continue
        age_min = (now - pos.recorded_at).total_seconds() / 60
        latest[pos.driver_id] = {
            "driver_id": pos.driver_id,
            "driver": pos.driver.name,
            "vehicle": pos.vehicle.identifier if pos.vehicle else None,
            "lat": pos.point.y,
            "lng": pos.point.x,
            "recorded_at": pos.recorded_at.isoformat(),
            "off_route": pos.off_route,
            "dist_m": pos.dist_m,
            "age_min": round(age_min),
            "status": status_for(age_min),
        }
    open_alerts = Alert.objects.filter(acked_at__isnull=True).count()
    return JsonResponse({"positions": list(latest.values()), "open_alerts": open_alerts})


@login_required
@require_http_methods(["GET", "POST"])
def api_routes(request):
    if request.method == "GET":
        routes = []
        for r in Route.objects.all().order_by("name"):
            assigned = list(
                Assignment.objects.filter(route=r, end_at__isnull=True)
                .select_related("driver")
                .values("driver_id", "driver__name")
            )
            routes.append({
                "id": r.id,
                "name": r.name,
                "corridor_m": r.corridor_m,
                "active": r.active,
                "geometry": json.loads(r.geom.geojson),
                "assigned": [
                    {"driver_id": a["driver_id"], "driver": a["driver__name"]}
                    for a in assigned
                ],
            })
        return JsonResponse({"routes": routes})

    # POST — création d'un itinéraire depuis le tracé dessiné
    data = json.loads(request.body or "{}")
    geometry = data.get("geometry")
    if not geometry:
        return JsonResponse({"detail": "geometry (LineString) requise."}, status=400)
    geom = GEOSGeometry(json.dumps(geometry))
    geom.srid = 4326
    route = Route.objects.create(
        name=data.get("name") or "Itinéraire",
        geom=geom,
        corridor_m=float(data.get("corridor_m") or 100),
    )
    return JsonResponse({"id": route.id, "status": "ok"})


@login_required
@require_http_methods(["DELETE"])
def api_route_delete(request, route_id):
    get_object_or_404(Route, pk=route_id).delete()
    return JsonResponse({"status": "deleted"})


@login_required
@require_http_methods(["POST"])
def api_route_assign(request, route_id):
    """Assigne un chauffeur à un itinéraire (remplace son affectation active)."""
    route = get_object_or_404(Route, pk=route_id)
    data = json.loads(request.body or "{}")
    driver = get_object_or_404(Driver, pk=data.get("driver_id"))
    # Une seule affectation active par chauffeur : on clôt les précédentes.
    Assignment.objects.filter(driver=driver, end_at__isnull=True).update(
        end_at=timezone.now()
    )
    Assignment.objects.create(
        driver=driver, vehicle=driver.vehicle, route=route, start_at=timezone.now()
    )
    return JsonResponse({"status": "assigned", "driver": driver.name})


@login_required
@require_http_methods(["POST"])
def api_route_unassign(request, route_id):
    """Retire l'affectation active d'un chauffeur sur cet itinéraire."""
    data = json.loads(request.body or "{}")
    Assignment.objects.filter(
        route_id=route_id, driver_id=data.get("driver_id"), end_at__isnull=True
    ).update(end_at=timezone.now())
    return JsonResponse({"status": "unassigned"})


@login_required
def api_alerts(request):
    qs = (
        Alert.objects.select_related("driver", "vehicle", "position")
        .order_by("-created_at")[:100]
    )
    alerts = [{
        "id": a.id,
        "kind": a.get_kind_display(),
        "driver": a.driver.name,
        "vehicle": a.vehicle.identifier if a.vehicle else None,
        "message": a.message,
        "created_at": a.created_at.isoformat(),
        "acked": a.acked_at is not None,
        "lat": a.position.point.y if a.position else None,
        "lng": a.position.point.x if a.position else None,
    } for a in qs]
    return JsonResponse({"alerts": alerts})


@login_required
@require_http_methods(["POST"])
def api_alert_ack(request, alert_id):
    alert = get_object_or_404(Alert, pk=alert_id)
    alert.acked_at = timezone.now()
    alert.save(update_fields=["acked_at"])
    return JsonResponse({"status": "acked"})


@login_required
def api_appros(request):
    qs = Appro.objects.select_related("driver", "vehicle").order_by("-date", "-created_at")
    driver_id = request.GET.get("driver")
    if driver_id:
        qs = qs.filter(driver_id=driver_id)
    appros = [{
        "id": a.id,
        "date": a.date.isoformat(),
        "driver": a.driver.name,
        "vehicle": a.vehicle.identifier if a.vehicle else None,
        "qte_litres": a.qte_litres,
        "index_precedent": a.index_precedent,
        "index_actuel": a.index_actuel,
        "difference": a.difference,
    } for a in qs[:300]]
    return JsonResponse({"appros": appros})


# ── Tracking : replay, activité journalière, journal, zones ────────────────

def _parse_day(request):
    """Paramètre ?date=YYYY-MM-DD (défaut : aujourd'hui, fuseau projet)."""
    return parse_date(request.GET.get("date") or "") or timezone.localdate()


@login_required
def api_track(request):
    """Trajet d'un chauffeur sur une journée : points + stats + arrêts."""
    driver = get_object_or_404(Driver, pk=request.GET.get("driver"))
    day = _parse_day(request)
    stats = analyze_day(driver, day, include_points=True)
    stats["driver"] = driver.name
    stats["vehicle"] = driver.vehicle.identifier if driver.vehicle else None
    stats["date"] = day.isoformat()
    return JsonResponse(stats)


def _float_param(request, name):
    try:
        value = float(request.GET[name])
    except (KeyError, TypeError, ValueError):
        raise ValueError(f"{name} requis.")
    if not math.isfinite(value):
        raise ValueError(f"{name} invalide.")
    return value


@login_required
def api_directions(request):
    """Calcule un itinéraire routier entre la position actuelle et une cible.

    Utilise OSRM public, sans clé API. En cas d'indisponibilité du routeur, le
    client garde la destination et peut ouvrir Google Maps.
    """
    try:
        origin_lat = _float_param(request, "origin_lat")
        origin_lng = _float_param(request, "origin_lng")
        dest_lat = _float_param(request, "dest_lat")
        dest_lng = _float_param(request, "dest_lng")
    except ValueError as exc:
        return JsonResponse({"detail": str(exc)}, status=400)

    coords = f"{origin_lng},{origin_lat};{dest_lng},{dest_lat}"
    query = urllib.parse.urlencode({
        "overview": "full",
        "geometries": "geojson",
        "steps": "false",
    })
    url = f"https://router.project-osrm.org/route/v1/driving/{coords}?{query}"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "CarbTrack/1.0"})
        with urllib.request.urlopen(req, timeout=12) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return JsonResponse({
            "status": "fallback",
            "detail": f"Calcul routier indisponible: {exc}",
        }, status=502)

    routes = payload.get("routes") or []
    if not routes:
        return JsonResponse({"status": "fallback", "detail": "Aucun trajet trouve."}, status=404)

    route = routes[0]
    return JsonResponse({
        "status": "ok",
        "distance_m": route.get("distance"),
        "duration_s": route.get("duration"),
        "geometry": route.get("geometry"),
    })


@login_required
def api_daily(request):
    """Activité du jour par chauffeur/véhicule. `?csv=1` → export CSV."""
    day = _parse_day(request)
    rows = []
    for d in Driver.objects.filter(active=True).select_related("vehicle").order_by("name"):
        s = analyze_day(d, day, include_points=False)
        if not s["ping_count"]:
            continue
        rows.append({
            "driver_id": d.id,
            "driver": d.name,
            "vehicle": d.vehicle.identifier if d.vehicle else None,
            "distance_km": s["distance_km"],
            "driving_min": s["driving_min"],
            "first_ts": s["first_ts"],
            "last_ts": s["last_ts"],
            "stops": len(s["stops"]),
            "max_kmh": s["max_kmh"],
            "avg_kmh": s["avg_kmh"],
        })

    if request.GET.get("csv"):
        resp = HttpResponse(content_type="text/csv; charset=utf-8")
        resp["Content-Disposition"] = f'attachment; filename="activite_{day.isoformat()}.csv"'
        w = csv.writer(resp, delimiter=";")
        w.writerow(["Date", "Chauffeur", "Véhicule", "Distance (km)",
                    "Conduite (min)", "Premier signal", "Dernier signal",
                    "Arrêts", "V. max (km/h)", "V. moy (km/h)"])
        for r in rows:
            w.writerow([day.isoformat(), r["driver"], r["vehicle"] or "",
                        str(r["distance_km"]).replace(".", ","), r["driving_min"],
                        (r["first_ts"] or "")[11:16], (r["last_ts"] or "")[11:16],
                        r["stops"], r["max_kmh"],
                        str(r["avg_kmh"]).replace(".", ",")])
        return resp

    return JsonResponse({"date": day.isoformat(), "rows": rows})


@login_required
def api_events(request):
    """Journal du jour (zones, arrêts), plus récent d'abord."""
    day = _parse_day(request)
    start, end = day_bounds(day)
    qs = (
        Event.objects.filter(started_at__gte=start, started_at__lt=end)
        .select_related("driver", "vehicle", "geofence", "position")
        .order_by("-started_at")
    )
    driver_id = request.GET.get("driver")
    if driver_id:
        qs = qs.filter(driver_id=driver_id)
    events = [{
        "id": e.id,
        "kind": e.kind,
        "kind_label": e.get_kind_display(),
        "driver": e.driver.name,
        "vehicle": e.vehicle.identifier if e.vehicle else None,
        "zone": e.geofence.name if e.geofence else None,
        "message": e.message,
        "started_at": timezone.localtime(e.started_at).isoformat(),
        "ended_at": timezone.localtime(e.ended_at).isoformat() if e.ended_at else None,
        "minutes": round(e.duration_min) if e.duration_min is not None else None,
        "lat": e.position.point.y if e.position else None,
        "lng": e.position.point.x if e.position else None,
    } for e in qs[:300]]
    return JsonResponse({"date": day.isoformat(), "events": events})


@login_required
@require_http_methods(["GET", "POST"])
def api_geofences(request):
    if request.method == "GET":
        zones = [{
            "id": g.id,
            "name": g.name,
            "kind": g.kind,
            "kind_label": g.get_kind_display(),
            "lat": g.center.y,
            "lng": g.center.x,
            "radius_m": g.radius_m,
        } for g in Geofence.objects.filter(active=True).order_by("name")]
        return JsonResponse({"zones": zones})

    data = json.loads(request.body or "{}")
    try:
        lat, lng = float(data["lat"]), float(data["lng"])
    except (KeyError, TypeError, ValueError):
        return JsonResponse({"detail": "lat/lng requis."}, status=400)
    zone = Geofence.objects.create(
        name=data.get("name") or "Zone",
        kind=data.get("kind") or Geofence.KIND_CHANTIER,
        center=Point(lng, lat, srid=4326),
        radius_m=float(data.get("radius_m") or 300),
    )
    return JsonResponse({"id": zone.id, "status": "ok"})


@login_required
@require_http_methods(["DELETE"])
def api_geofence_delete(request, zone_id):
    get_object_or_404(Geofence, pk=zone_id).delete()
    return JsonResponse({"status": "deleted"})
