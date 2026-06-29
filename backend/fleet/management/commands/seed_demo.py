"""Crée un jeu de données de démonstration pour tester le suivi.

  python manage.py seed_demo

Crée : 1 chauffeur (phone 0000000000 / PIN 0000), 1 véhicule, 1 itinéraire
(couloir de 100 m le long d'un tronçon à Kinshasa) et une affectation active.
Affiche le token du chauffeur à utiliser dans l'app / les tests curl.
"""
from django.contrib.gis.geos import LineString
from django.core.management.base import BaseCommand
from django.utils import timezone

from fleet.models import Assignment, Driver, Route, Vehicle


class Command(BaseCommand):
    help = "Crée des données de démonstration (chauffeur, véhicule, itinéraire, affectation)."

    def handle(self, *args, **options):
        driver, _ = Driver.objects.get_or_create(
            phone="0000000000", defaults={"name": "Chauffeur Démo"}
        )
        driver.set_pin("0000")
        driver.active = True
        driver.save()

        vehicle, _ = Vehicle.objects.get_or_create(
            identifier="DEMO-01",
            defaults={"label": "Camion citerne démo"},
        )
        # Lien compte ↔ camion
        driver.vehicle = vehicle
        driver.save()

        # Tronçon de référence (lng, lat) — axe approximatif à Kinshasa.
        line = LineString(
            (15.300, -4.330),
            (15.320, -4.325),
            (15.340, -4.320),
            (15.360, -4.318),
            srid=4326,
        )
        route, _ = Route.objects.get_or_create(
            name="Itinéraire démo",
            defaults={"geom": line, "corridor_m": 100},
        )

        Assignment.objects.filter(driver=driver, end_at__isnull=True).update(
            end_at=timezone.now()
        )
        Assignment.objects.create(
            driver=driver, vehicle=vehicle, route=route, start_at=timezone.now()
        )

        self.stdout.write(self.style.SUCCESS("Données de démo créées."))
        self.stdout.write(f"  Chauffeur : {driver.name}  phone=0000000000  PIN=0000")
        self.stdout.write(f"  TOKEN     : {driver.auth_token}")
        self.stdout.write(f"  Véhicule  : {vehicle.identifier}")
        self.stdout.write(f"  Itinéraire: {route.name} (couloir {route.corridor_m:.0f} m)")
        self.stdout.write("")
        self.stdout.write("Test (point DANS le couloir) :")
        self.stdout.write(
            "  curl -s -X POST http://localhost:8000/api/positions "
            f'-H "Authorization: Token {driver.auth_token}" -H "Content-Type: application/json" '
            "-d '{\"positions\":[{\"lat\":-4.325,\"lng\":15.320}]}'"
        )
        self.stdout.write("Test (point HORS couloir) :")
        self.stdout.write(
            "  curl -s -X POST http://localhost:8000/api/positions "
            f'-H "Authorization: Token {driver.auth_token}" -H "Content-Type: application/json" '
            "-d '{\"positions\":[{\"lat\":-4.360,\"lng\":15.320}]}'"
        )
