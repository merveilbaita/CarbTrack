"""API CarbTrack.

- POST /api/auth/login        (public)  téléphone + pin -> token
- POST /api/positions         (token)   ingestion batch de pings GPS
- GET  /api/positions/latest  (public*) dernière position par véhicule (dashboard)

(*) `latest` est ouvert en v1 pour le polling du dashboard interne ; à sécuriser
    (session staff / token dashboard) avant exposition publique.
"""
from django.contrib.gis.geos import LineString, Point
from django.db.models import Max
from django.utils.dateparse import parse_date, parse_datetime
from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import (
    api_view,
    authentication_classes,
    permission_classes,
)
from rest_framework.permissions import AllowAny
from rest_framework.response import Response

from .geo import evaluate_point
from .models import Alert, Appro, Assignment, Driver, Position, Route, Vehicle
from .realtime import broadcast_alert, broadcast_position


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def health(request):
    """Sonde de santé publique (health check Render) — ne touche pas la BD."""
    return Response({"status": "ok"})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def login(request):
    phone = (request.data.get("phone") or "").strip()
    pin = str(request.data.get("pin") or "")
    try:
        driver = Driver.objects.get(phone=phone, active=True)
    except Driver.DoesNotExist:
        return Response({"detail": "Identifiants invalides."}, status=status.HTTP_401_UNAUTHORIZED)
    if not driver.check_pin(pin):
        return Response({"detail": "Identifiants invalides."}, status=status.HTTP_401_UNAUTHORIZED)

    device_id = request.data.get("device_id")
    if device_id:
        driver.device_id = str(device_id)
        driver.save(update_fields=["device_id"])

    return Response({
        "token": driver.auth_token,
        "driver": {
            "id": driver.id,
            "name": driver.name,
            "phone": driver.phone,
            "role": driver.role,
            "vehicle": _vehicle_payload(driver.vehicle),
        },
    })


def _vehicle_payload(vehicle):
    """Sérialise un véhicule + son dernier index connu (None si pas de véhicule)."""
    if vehicle is None:
        return None
    last_index = (
        Appro.objects.filter(vehicle=vehicle).aggregate(m=Max("index_actuel"))["m"]
        or 0
    )
    return {
        "id": vehicle.id,
        "identifier": vehicle.identifier,
        "label": vehicle.label,
        "last_index": last_index,
    }


def _ingest_one(driver, assignment, item):
    """Traite un ping. Retourne (result_dict, position_or_None, created_bool)."""
    client_id = item.get("client_id")
    if client_id and Position.objects.filter(client_id=client_id).exists():
        return {"client_id": client_id, "status": "duplicate"}, None, False

    try:
        lat = float(item["lat"])
        lng = float(item["lng"])
    except (KeyError, TypeError, ValueError):
        return {"client_id": client_id, "status": "error", "detail": "lat/lng manquants ou invalides"}, None, False

    recorded_at = parse_datetime(item["ts"]) if item.get("ts") else timezone.now()
    if recorded_at is None:
        recorded_at = timezone.now()

    point = Point(lng, lat, srid=4326)
    route = assignment.route if assignment else None
    vehicle = assignment.vehicle if assignment else None

    off_route, dist_m = (False, None)
    if route is not None:
        off_route, dist_m = evaluate_point(route, point)

    pos = Position.objects.create(
        driver=driver,
        vehicle=vehicle,
        route=route,
        point=point,
        recorded_at=recorded_at,
        speed=item.get("speed"),
        accuracy=item.get("accuracy"),
        off_route=off_route,
        dist_m=dist_m,
        client_id=client_id or None,
    )
    return (
        {"client_id": client_id, "status": "ok", "off_route": off_route, "dist_m": dist_m},
        pos,
        True,
    )


@api_view(["POST"])
def ingest_positions(request):
    driver = request.user  # Driver, via DriverTokenAuthentication
    assignment = Assignment.active_for(driver)

    items = request.data.get("positions")
    if not isinstance(items, list):
        return Response({"detail": "Champ 'positions' (liste) requis."}, status=400)

    # État "hors couloir" précédent pour ne créer une alerte qu'à la transition.
    last = (
        Position.objects.filter(driver=driver)
        .order_by("-recorded_at")
        .values_list("off_route", flat=True)
        .first()
    )
    prev_off = bool(last) if last is not None else False

    results = []
    for item in sorted(items, key=lambda x: x.get("ts") or ""):
        res, pos, created = _ingest_one(driver, assignment, item)
        results.append(res)
        if created and pos is not None:
            broadcast_position({
                "driver_id": driver.id,
                "driver": driver.name,
                "vehicle": pos.vehicle.identifier if pos.vehicle else None,
                "lat": pos.point.y,
                "lng": pos.point.x,
                "recorded_at": pos.recorded_at.isoformat(),
                "off_route": pos.off_route,
                "dist_m": pos.dist_m,
            })
            if pos.off_route and not prev_off:
                alert = Alert.objects.create(
                    driver=driver,
                    vehicle=pos.vehicle,
                    position=pos,
                    kind=Alert.KIND_OFF_ROUTE,
                    message=(
                        f"Sortie de couloir ({pos.dist_m:.0f} m du tracé)"
                        if pos.dist_m is not None else "Sortie de couloir"
                    ),
                )
                broadcast_alert({
                    "id": alert.id,
                    "driver": driver.name,
                    "vehicle": pos.vehicle.identifier if pos.vehicle else None,
                    "message": alert.message,
                    "created_at": alert.created_at.isoformat(),
                })
            prev_off = pos.off_route

    return Response({"accepted": len(results), "results": results})


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def positions_latest(request):
    """Dernière position de chaque chauffeur (pour le polling de la carte)."""
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
    return Response({"positions": list(latest.values())})


# ── Enregistrement d'itinéraire (superviseur, depuis l'app) ────────────────

@api_view(["POST"])
def create_route(request):
    """Crée un itinéraire à partir d'un tracé GPS enregistré (superviseur only)."""
    driver = request.user
    if not getattr(driver, "is_supervisor", False):
        return Response({"detail": "Réservé aux superviseurs."}, status=403)

    points = request.data.get("points") or []
    if len(points) < 2:
        return Response({"detail": "Trajet trop court (2 points minimum)."}, status=400)

    try:
        coords = [(float(p["lng"]), float(p["lat"])) for p in points]
    except (KeyError, TypeError, ValueError):
        return Response({"detail": "Points invalides."}, status=400)

    line = LineString(coords, srid=4326)
    # Simplifie le tracé (réduit les milliers de points GPS) ~5 m de tolérance.
    simplified = line.simplify(0.00005, preserve_topology=True)
    if simplified is None or simplified.geom_type != "LineString" or len(simplified.coords) < 2:
        simplified = line
    simplified.srid = 4326

    route = Route.objects.create(
        name=request.data.get("name") or "Itinéraire enregistré",
        geom=simplified,
        corridor_m=float(request.data.get("corridor_m") or 200),
    )
    return Response({
        "id": route.id,
        "status": "ok",
        "points_bruts": len(coords),
        "points_simplifies": len(simplified.coords),
    })


# ── Approvisionnements (outil principal de l'app chauffeur) ─────────────────

@api_view(["GET"])
def vehicles_list(request):
    """Véhicules actifs + dernier index connu (pour pré-remplir l'appro)."""
    qs = (
        Vehicle.objects.filter(active=True)
        .annotate(last_index=Max("appros__index_actuel"))
        .order_by("identifier")
    )
    data = [
        {
            "id": v.id,
            "identifier": v.identifier,
            "label": v.label,
            "last_index": v.last_index or 0,
        }
        for v in qs
    ]
    return Response({"vehicles": data})


@api_view(["POST"])
def ingest_appros(request):
    """Crée un lot d'appros saisis par le chauffeur authentifié (idempotent)."""
    driver = request.user
    items = request.data.get("appros")
    if not isinstance(items, list):
        return Response({"detail": "Champ 'appros' (liste) requis."}, status=400)

    results = []
    for item in items:
        client_id = item.get("client_id")
        if client_id and Appro.objects.filter(client_id=client_id).exists():
            results.append({"client_id": client_id, "status": "duplicate"})
            continue
        try:
            date = parse_date(str(item.get("date"))) or timezone.localdate()
            qte = float(item["qte_litres"])
            # Véhicule fourni, sinon le camion assigné au chauffeur.
            vehicle = (
                Vehicle.objects.filter(id=item.get("vehicle_id")).first()
                if item.get("vehicle_id") is not None else None
            ) or driver.vehicle
            appro = Appro.objects.create(
                driver=driver,
                vehicle=vehicle,
                date=date,
                qte_litres=qte,
                index_precedent=float(item.get("index_precedent") or 0),
                index_actuel=float(item.get("index_actuel") or 0),
                client_id=client_id or None,
            )
            results.append({
                "client_id": client_id,
                "status": "ok",
                "id": appro.id,
                "difference": appro.difference,
            })
        except (KeyError, TypeError, ValueError) as e:
            results.append({"client_id": client_id, "status": "error", "detail": str(e)})

    return Response({"accepted": len(results), "results": results})


@api_view(["GET"])
def appros_recent(request):
    """Derniers appros du chauffeur authentifié (historique de l'app)."""
    driver = request.user
    qs = (
        Appro.objects.filter(driver=driver)
        .select_related("vehicle")
        .order_by("-date", "-created_at")[:20]
    )
    data = [
        {
            "id": a.id,
            "date": a.date.isoformat(),
            "vehicle": a.vehicle.identifier if a.vehicle else None,
            "qte_litres": a.qte_litres,
            "index_precedent": a.index_precedent,
            "index_actuel": a.index_actuel,
            "difference": a.difference,
        }
        for a in qs
    ]
    return Response({"appros": data})
