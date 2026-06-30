"""Dashboard web (staff). Pages + endpoints JSON protégés par session Django."""
import json

from django.contrib.auth.decorators import login_required
from django.contrib.gis.geos import GEOSGeometry
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from fleet.models import Alert, Appro, Assignment, Driver, Position, Route


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


# ── API JSON (session staff) ────────────────────────────────────────────────

@login_required
def api_latest(request):
    """Dernière position de chaque chauffeur + compteur d'alertes ouvertes."""
    latest = {}
    qs = (
        Position.objects.select_related("driver", "vehicle")
        .order_by("driver_id", "-recorded_at")
    )
    for pos in qs:
        if pos.driver_id in latest:
            continue
        latest[pos.driver_id] = {
            "driver_id": pos.driver_id,
            "driver": pos.driver.name,
            "vehicle": pos.vehicle.identifier if pos.vehicle else None,
            "lat": pos.point.y,
            "lng": pos.point.x,
            "recorded_at": pos.recorded_at.isoformat(),
            "off_route": pos.off_route,
            "dist_m": pos.dist_m,
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
