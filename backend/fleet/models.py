"""Modèles CarbTrack — chauffeurs, véhicules, itinéraires (couloirs) et positions GPS.

Les géométries sont stockées en `geography=True` (SRID 4326) afin que les
distances PostGIS (`ST_DWithin`, `ST_Distance`) soient retournées en **mètres**,
ce qui rend la détection de sortie de couloir directe et précise.
"""
import secrets

from django.contrib.gis.db import models as gis
from django.contrib.auth.hashers import check_password, make_password
from django.db import models
from django.utils import timezone


def generate_token() -> str:
    return secrets.token_hex(24)


class Driver(models.Model):
    """Un chauffeur. Authentifié par téléphone + PIN ; l'app porte un token."""

    name = models.CharField("nom", max_length=120)
    phone = models.CharField("téléphone", max_length=32, unique=True)
    device_id = models.CharField("identifiant appareil", max_length=120, blank=True)
    pin_hash = models.CharField(max_length=256, blank=True)
    auth_token = models.CharField(max_length=64, unique=True, default=generate_token)
    # Camion/engin assigné au chauffeur. Un compte ↔ un camion.
    vehicle = models.ForeignKey(
        "Vehicle", null=True, blank=True, on_delete=models.SET_NULL,
        related_name="drivers", verbose_name="camion assigné",
    )
    ROLE_DRIVER = "driver"
    ROLE_SUPERVISOR = "supervisor"
    ROLE_CHOICES = [
        (ROLE_DRIVER, "Chauffeur / opérateur"),
        (ROLE_SUPERVISOR, "Superviseur (admin app)"),
    ]
    role = models.CharField("rôle", max_length=16, choices=ROLE_CHOICES, default=ROLE_DRIVER)
    active = models.BooleanField("actif", default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "chauffeur / opérateur"
        verbose_name_plural = "chauffeurs / opérateurs"

    def __str__(self):
        return f"{self.name} ({self.phone})"

    def set_pin(self, raw_pin: str):
        self.pin_hash = make_password(raw_pin)

    def check_pin(self, raw_pin: str) -> bool:
        return bool(self.pin_hash) and check_password(raw_pin, self.pin_hash)

    def rotate_token(self):
        self.auth_token = generate_token()

    # Permet à DRF (IsAuthenticated) de traiter un Driver comme un acteur authentifié.
    @property
    def is_authenticated(self) -> bool:
        return True

    @property
    def is_supervisor(self) -> bool:
        return self.role == self.ROLE_SUPERVISOR


class Vehicle(models.Model):
    """Un engin/véhicule. `ext_id_engin` reliera plus tard à GestionCarburantPro."""

    identifier = models.CharField("immatriculation / code", max_length=64, unique=True)
    label = models.CharField("désignation", max_length=120, blank=True)
    ext_id_engin = models.CharField(
        "id engin externe (GestionCarburantPro)", max_length=64, blank=True
    )
    active = models.BooleanField("actif", default=True)

    class Meta:
        verbose_name = "véhicule"
        verbose_name_plural = "véhicules"

    def __str__(self):
        return self.label or self.identifier


class Route(models.Model):
    """Itinéraire de référence : une polyligne + une largeur de couloir tolérée (m)."""

    name = models.CharField("nom", max_length=120)
    geom = gis.LineStringField("tracé", geography=True, srid=4326)
    corridor_m = models.FloatField("largeur du couloir (m)", default=100)
    active = models.BooleanField("actif", default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "itinéraire"
        verbose_name_plural = "itinéraires"

    def __str__(self):
        return self.name


class Assignment(models.Model):
    """Affectation d'un chauffeur/véhicule à un itinéraire de référence.

    Le suivi est 24/7, mais la déviation se juge contre l'itinéraire affecté
    en cours (`end_at` nul = affectation active).
    """

    driver = models.ForeignKey(Driver, on_delete=models.CASCADE, related_name="assignments")
    vehicle = models.ForeignKey(
        Vehicle, null=True, blank=True, on_delete=models.SET_NULL, related_name="assignments"
    )
    route = models.ForeignKey(Route, on_delete=models.CASCADE, related_name="assignments")
    start_at = models.DateTimeField(default=timezone.now)
    end_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "affectation"
        verbose_name_plural = "affectations"

    def __str__(self):
        return f"{self.driver} → {self.route}"

    @classmethod
    def active_for(cls, driver):
        return (
            cls.objects.filter(driver=driver, end_at__isnull=True)
            .select_related("route", "vehicle")
            .order_by("-start_at")
            .first()
        )


class Position(models.Model):
    """Un ping GPS. `off_route`/`dist_m` sont calculés à l'ingestion."""

    driver = models.ForeignKey(Driver, on_delete=models.CASCADE, related_name="positions")
    vehicle = models.ForeignKey(
        Vehicle, null=True, blank=True, on_delete=models.SET_NULL, related_name="positions"
    )
    route = models.ForeignKey(
        Route, null=True, blank=True, on_delete=models.SET_NULL, related_name="positions"
    )
    point = gis.PointField(geography=True, srid=4326)
    recorded_at = models.DateTimeField("horodatage appareil")
    speed = models.FloatField("vitesse (m/s)", null=True, blank=True)
    accuracy = models.FloatField("précision (m)", null=True, blank=True)
    off_route = models.BooleanField("hors couloir", default=False)
    dist_m = models.FloatField("écart au couloir (m)", null=True, blank=True)
    client_id = models.CharField(max_length=64, unique=True, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "position"
        verbose_name_plural = "positions"
        indexes = [
            models.Index(fields=["driver", "recorded_at"]),
            models.Index(fields=["vehicle", "recorded_at"]),
        ]

    def __str__(self):
        return f"{self.driver} @ {self.recorded_at:%Y-%m-%d %H:%M}"


class Geofence(models.Model):
    """Zone nommée (base vie, station, chantier…) : centre + rayon en mètres.

    Sert au journal d'événements : arrivée/départ détectés à l'ingestion des
    positions, et aux arrêts (un arrêt dans une zone nommée est normal).
    """

    KIND_BASE = "base"
    KIND_STATION = "station"
    KIND_CHANTIER = "chantier"
    KIND_AUTRE = "autre"
    KIND_CHOICES = [
        (KIND_BASE, "Base vie"),
        (KIND_STATION, "Station carburant"),
        (KIND_CHANTIER, "Chantier"),
        (KIND_AUTRE, "Autre"),
    ]

    name = models.CharField("nom", max_length=120)
    kind = models.CharField("type", max_length=16, choices=KIND_CHOICES, default=KIND_CHANTIER)
    center = gis.PointField("centre", geography=True, srid=4326)
    radius_m = models.FloatField("rayon (m)", default=300)
    active = models.BooleanField("actif", default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "zone"
        verbose_name_plural = "zones"

    def __str__(self):
        return f"{self.name} ({self.get_kind_display()})"


class Event(models.Model):
    """Journal d'exploitation : entrées/sorties de zone et arrêts prolongés.

    Pour un arrêt, `started_at`/`ended_at` bornent la durée (`ended_at` nul =
    arrêt en cours). Pour une entrée/sortie de zone, seul `started_at` compte.
    """

    KIND_ZONE_ENTER = "zone_enter"
    KIND_ZONE_EXIT = "zone_exit"
    KIND_STOP = "stop"
    KIND_CHOICES = [
        (KIND_ZONE_ENTER, "Arrivée en zone"),
        (KIND_ZONE_EXIT, "Départ de zone"),
        (KIND_STOP, "Arrêt prolongé"),
    ]

    driver = models.ForeignKey(Driver, on_delete=models.CASCADE, related_name="events")
    vehicle = models.ForeignKey(
        Vehicle, null=True, blank=True, on_delete=models.SET_NULL, related_name="events"
    )
    geofence = models.ForeignKey(
        Geofence, null=True, blank=True, on_delete=models.SET_NULL, related_name="events"
    )
    position = models.ForeignKey(
        Position, null=True, blank=True, on_delete=models.SET_NULL, related_name="events"
    )
    kind = models.CharField(max_length=16, choices=KIND_CHOICES)
    message = models.CharField(max_length=255, blank=True)
    started_at = models.DateTimeField("début")
    ended_at = models.DateTimeField("fin", null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "événement"
        verbose_name_plural = "événements"
        ordering = ["-started_at"]
        indexes = [
            models.Index(fields=["driver", "started_at"]),
            models.Index(fields=["kind", "started_at"]),
        ]

    def __str__(self):
        return f"{self.get_kind_display()} — {self.driver} @ {self.started_at:%Y-%m-%d %H:%M}"

    @property
    def duration_min(self) -> float | None:
        if self.kind != self.KIND_STOP or self.ended_at is None:
            return None
        return (self.ended_at - self.started_at).total_seconds() / 60


class Alert(models.Model):
    KIND_OFF_ROUTE = "off_route"
    KIND_SPEEDING = "speeding"
    KIND_CHOICES = [
        (KIND_OFF_ROUTE, "Sortie de couloir"),
        (KIND_SPEEDING, "Excès de vitesse"),
    ]

    driver = models.ForeignKey(Driver, on_delete=models.CASCADE, related_name="alerts")
    vehicle = models.ForeignKey(
        Vehicle, null=True, blank=True, on_delete=models.SET_NULL, related_name="alerts"
    )
    position = models.ForeignKey(
        Position, null=True, blank=True, on_delete=models.SET_NULL, related_name="alerts"
    )
    kind = models.CharField(max_length=32, choices=KIND_CHOICES, default=KIND_OFF_ROUTE)
    message = models.CharField(max_length=255, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    acked_at = models.DateTimeField("acquittée le", null=True, blank=True)

    class Meta:
        verbose_name = "alerte"
        verbose_name_plural = "alertes"
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.get_kind_display()} — {self.driver}"


class Appro(models.Model):
    """Approvisionnement (prise de carburant) saisi par un chauffeur.

    Outil principal de l'app mobile : quantité + date + véhicule + index compteur.
    `difference` = index_actuel − index_precedent (calculée à l'enregistrement).
    """

    driver = models.ForeignKey(Driver, on_delete=models.CASCADE, related_name="appros")
    vehicle = models.ForeignKey(
        Vehicle, null=True, blank=True, on_delete=models.SET_NULL, related_name="appros"
    )
    date = models.DateField("date")
    qte_litres = models.FloatField("quantité (L)")
    index_precedent = models.FloatField("index précédent", default=0)
    index_actuel = models.FloatField("index actuel", default=0)
    difference = models.FloatField("différence d'index", default=0)
    client_id = models.CharField(max_length=64, unique=True, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = "approvisionnement"
        verbose_name_plural = "approvisionnements"
        ordering = ["-date", "-created_at"]
        indexes = [
            models.Index(fields=["driver", "date"]),
            models.Index(fields=["vehicle", "date"]),
        ]

    def save(self, *args, **kwargs):
        self.difference = (self.index_actuel or 0) - (self.index_precedent or 0)
        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.driver} · {self.qte_litres} L · {self.date}"
