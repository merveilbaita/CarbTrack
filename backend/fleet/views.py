"""API CarbTrack.

- POST /api/auth/login        (public)  téléphone + pin -> token
- POST /api/positions         (token)   ingestion batch de pings GPS
- GET  /api/positions/latest  (public*) dernière position par véhicule (dashboard)

(*) `latest` est ouvert en v1 pour le polling du dashboard interne ; à sécuriser
    (session staff / token dashboard) avant exposition publique.
"""
import json
import math
import urllib.error
import urllib.parse
import urllib.request

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
from .journal import process_position
from .models import (
    Alert, Appro, Assignment, Driver, Event, Geofence, Intervention, Position, Route, Vehicle,
)
from .presence import check_silences, resolve_silence, status_for
from .realtime import broadcast_alert, broadcast_position
from .tracking_stats import day_bounds


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

    # Position précédente : transitions hors-couloir, zones, arrêts, vitesse.
    prev = Position.objects.filter(driver=driver).order_by("-recorded_at").first()
    prev_off = prev.off_route if prev is not None else False

    results = []
    for item in sorted(items, key=lambda x: x.get("ts") or ""):
        res, pos, created = _ingest_one(driver, assignment, item)
        results.append(res)
        if created and pos is not None:
            # Journal (zones/arrêts/trajets) + alertes vitesse / zone rouge.
            for journal_alert in process_position(driver, pos, prev):
                broadcast_alert({
                    "id": journal_alert.id,
                    "driver": driver.name,
                    "vehicle": pos.vehicle.identifier if pos.vehicle else None,
                    "message": journal_alert.message,
                    "created_at": journal_alert.created_at.isoformat(),
                })
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
            prev = pos

    if any(r.get("status") == "ok" for r in results):
        resolve_silence(driver)   # signal revenu : clôt l'alerte de silence
    check_silences()              # et vérifie les autres chauffeurs (anti-rebond 60 s)

    return Response({"accepted": len(results), "results": results})


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def positions_latest(request):
    """Dernière position de chaque chauffeur (pour le polling de la carte)."""
    return Response({"positions": _latest_positions_payload()})


@api_view(["GET"])
def fleet_latest(request):
    """Dernières positions de la flotte, réservé aux superviseurs de l'app."""
    driver = request.user
    if not getattr(driver, "is_supervisor", False):
        return Response({"detail": "Réservé aux superviseurs."}, status=403)
    return Response({"positions": _latest_positions_payload()})


@api_view(["GET"])
def events_list(request):
    """Journal du jour pour l'app superviseur."""
    driver = request.user
    if not getattr(driver, "is_supervisor", False):
        return Response({"detail": "Réservé aux superviseurs."}, status=403)

    day = parse_date(request.GET.get("date") or "") or timezone.localdate()
    start, end = day_bounds(day)
    qs = (
        Event.objects.filter(started_at__gte=start, started_at__lt=end)
        .select_related("driver", "vehicle", "geofence", "position")
        .order_by("-started_at")
    )
    event_ids = list(qs.values_list("id", flat=True)[:300])
    active_interventions = {
        i.event_id: _intervention_payload(i)
        for i in Intervention.objects.filter(
            event_id__in=event_ids,
            status__in=[Intervention.STATUS_EN_ROUTE, Intervention.STATUS_ARRIVED],
        ).select_related("supervisor")
    }
    events = [{
        "id": e.id,
        "kind": e.kind,
        "kind_label": e.get_kind_display(),
        "driver": e.driver.name,
        "driver_phone": e.driver.phone,
        "driver_whatsapp": e.driver.whatsapp_phone,
        "driver_emergency_phone": e.driver.emergency_phone,
        "vehicle": e.vehicle.identifier if e.vehicle else None,
        "zone": e.geofence.name if e.geofence else None,
        "message": e.message,
        "started_at": timezone.localtime(e.started_at).isoformat(),
        "ended_at": timezone.localtime(e.ended_at).isoformat() if e.ended_at else None,
        "minutes": round(e.duration_min) if e.duration_min is not None else None,
        "lat": e.position.point.y if e.position else None,
        "lng": e.position.point.x if e.position else None,
        "intervention": active_interventions.get(e.id),
    } for e in qs[:300]]
    return Response({"date": day.isoformat(), "events": events})


@api_view(["GET"])
def admin_summary(request):
    """Résumé opérationnel pour l'accueil admin mobile."""
    supervisor, denied = _supervisor_or_403(request)
    if denied is not None:
        return denied

    now = timezone.now()
    day = parse_date(request.GET.get("date") or "") or timezone.localdate()
    start, end = day_bounds(day)

    latest = _latest_positions_payload()
    status_counts = {"online": 0, "silent": 0, "offline": 0}
    for item in latest:
        recorded_at = parse_datetime(item.get("recorded_at") or "")
        age_min = (
            (now - recorded_at).total_seconds() / 60
            if recorded_at is not None else None
        )
        status_counts[status_for(age_min)] += 1

    active_interventions = [
        _intervention_payload(i)
        for i in Intervention.objects.filter(
            status__in=[Intervention.STATUS_EN_ROUTE, Intervention.STATUS_ARRIVED]
        ).select_related("event", "supervisor")[:20]
    ]
    critical_events = list(
        Event.objects.filter(started_at__gte=start, started_at__lt=end)
        .filter(kind__in=[Event.KIND_STOP, Event.KIND_ZONE_ENTER])
        .select_related("driver", "vehicle", "geofence", "position")
        .order_by("-started_at")[:10]
    )
    critical_payload = [{
        "id": e.id,
        "kind": e.kind,
        "kind_label": e.get_kind_display(),
        "driver": e.driver.name,
        "vehicle": e.vehicle.identifier if e.vehicle else None,
        "message": e.message,
        "started_at": timezone.localtime(e.started_at).isoformat(),
    } for e in critical_events]

    return Response({
        "date": day.isoformat(),
        "supervisor": supervisor.name,
        "fleet": {
            "tracked": len(latest),
            "online": status_counts["online"],
            "silent": status_counts["silent"],
            "offline": status_counts["offline"],
        },
        "alerts": {
            "open": Alert.objects.filter(acked_at__isnull=True).count(),
        },
        "interventions": {
            "active": len(active_interventions),
            "items": active_interventions,
        },
        "events": {
            "today": Event.objects.filter(started_at__gte=start, started_at__lt=end).count(),
            "critical": critical_payload,
        },
    })


def _supervisor_or_403(request):
    driver = request.user
    if not getattr(driver, "is_supervisor", False):
        return None, Response({"detail": "Réservé aux superviseurs."}, status=403)
    return driver, None


def _intervention_payload(intervention):
    return {
        "id": intervention.id,
        "event_id": intervention.event_id,
        "status": intervention.status,
        "status_label": intervention.get_status_display(),
        "supervisor": intervention.supervisor.name,
        "started_at": timezone.localtime(intervention.started_at).isoformat(),
        "arrived_at": (
            timezone.localtime(intervention.arrived_at).isoformat()
            if intervention.arrived_at else None
        ),
        "ended_at": (
            timezone.localtime(intervention.ended_at).isoformat()
            if intervention.ended_at else None
        ),
    }


@api_view(["GET", "POST"])
def event_intervention(request, event_id):
    """Crée ou retourne l'intervention active liée à un événement."""
    supervisor, denied = _supervisor_or_403(request)
    if denied is not None:
        return denied

    event = Event.objects.filter(pk=event_id).first()
    if event is None:
        return Response({"detail": "Événement introuvable."}, status=404)

    intervention = (
        Intervention.objects.filter(
            event=event,
            status__in=[Intervention.STATUS_EN_ROUTE, Intervention.STATUS_ARRIVED],
        )
        .select_related("supervisor")
        .order_by("-started_at")
        .first()
    )
    if intervention is None and request.method == "POST":
        intervention = Intervention.objects.create(event=event, supervisor=supervisor)
    if intervention is None:
        return Response({"intervention": None})
    return Response({"intervention": _intervention_payload(intervention)})


@api_view(["POST"])
def intervention_status(request, intervention_id):
    """Met à jour le statut d'une intervention."""
    _supervisor, denied = _supervisor_or_403(request)
    if denied is not None:
        return denied

    intervention = Intervention.objects.filter(pk=intervention_id).select_related("supervisor").first()
    if intervention is None:
        return Response({"detail": "Intervention introuvable."}, status=404)

    new_status = request.data.get("status")
    now = timezone.now()
    if new_status == Intervention.STATUS_ARRIVED:
        intervention.status = Intervention.STATUS_ARRIVED
        intervention.arrived_at = intervention.arrived_at or now
        intervention.save(update_fields=["status", "arrived_at"])
    elif new_status == Intervention.STATUS_DONE:
        intervention.status = Intervention.STATUS_DONE
        intervention.ended_at = intervention.ended_at or now
        intervention.save(update_fields=["status", "ended_at"])
    else:
        return Response({"detail": "Statut invalide."}, status=400)
    return Response({"intervention": _intervention_payload(intervention)})


def _float_param(request, name):
    try:
        value = float(request.GET[name])
    except (KeyError, TypeError, ValueError):
        raise ValueError(f"{name} requis.")
    if not math.isfinite(value):
        raise ValueError(f"{name} invalide.")
    return value


@api_view(["GET"])
def directions(request):
    """Trajet routier OSRM pour l'app superviseur."""
    _supervisor, denied = _supervisor_or_403(request)
    if denied is not None:
        return denied
    try:
        origin_lat = _float_param(request, "origin_lat")
        origin_lng = _float_param(request, "origin_lng")
        dest_lat = _float_param(request, "dest_lat")
        dest_lng = _float_param(request, "dest_lng")
    except ValueError as exc:
        return Response({"detail": str(exc)}, status=400)

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
        return Response({"status": "fallback", "detail": str(exc)}, status=502)

    routes = payload.get("routes") or []
    if not routes:
        return Response({"status": "fallback", "detail": "Aucun trajet trouvé."}, status=404)
    route = routes[0]
    return Response({
        "status": "ok",
        "distance_m": route.get("distance"),
        "duration_s": route.get("duration"),
        "geometry": route.get("geometry"),
    })


def _latest_positions_payload():
    """Dernière position de chaque chauffeur."""
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
    return list(latest.values())


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


@api_view(["POST"])
def create_zone(request):
    """Crée une zone (géofence) depuis le terrain : le superviseur se tient
    sur le site et envoie sa position comme centre, avec nom/type/rayon."""
    driver = request.user
    if not getattr(driver, "is_supervisor", False):
        return Response({"detail": "Réservé aux superviseurs."}, status=403)

    try:
        lat = float(request.data["lat"])
        lng = float(request.data["lng"])
    except (KeyError, TypeError, ValueError):
        return Response({"detail": "lat/lng requis."}, status=400)

    kind = request.data.get("kind") or Geofence.KIND_CHANTIER
    if kind not in dict(Geofence.KIND_CHOICES):
        kind = Geofence.KIND_AUTRE

    zone = Geofence.objects.create(
        name=request.data.get("name") or "Zone terrain",
        kind=kind,
        center=Point(lng, lat, srid=4326),
        radius_m=float(request.data.get("radius_m") or 300),
    )
    return Response({
        "id": zone.id,
        "status": "ok",
        "name": zone.name,
        "kind": zone.kind,
        "radius_m": zone.radius_m,
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
