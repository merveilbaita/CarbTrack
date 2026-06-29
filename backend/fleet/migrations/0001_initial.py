import django.contrib.gis.db.models.fields
import django.db.models.deletion
import django.utils.timezone
from django.contrib.postgres.operations import CreateExtension
from django.db import migrations, models

import fleet.models


class Migration(migrations.Migration):

    initial = True

    dependencies = []

    operations = [
        CreateExtension("postgis"),
        migrations.CreateModel(
            name="Driver",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120, verbose_name="nom")),
                ("phone", models.CharField(max_length=32, unique=True, verbose_name="téléphone")),
                ("device_id", models.CharField(blank=True, max_length=120, verbose_name="identifiant appareil")),
                ("pin_hash", models.CharField(blank=True, max_length=256)),
                ("auth_token", models.CharField(default=fleet.models.generate_token, max_length=64, unique=True)),
                ("active", models.BooleanField(default=True, verbose_name="actif")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"verbose_name": "chauffeur", "verbose_name_plural": "chauffeurs"},
        ),
        migrations.CreateModel(
            name="Route",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120, verbose_name="nom")),
                ("geom", django.contrib.gis.db.models.fields.LineStringField(geography=True, srid=4326, verbose_name="tracé")),
                ("corridor_m", models.FloatField(default=100, verbose_name="largeur du couloir (m)")),
                ("active", models.BooleanField(default=True, verbose_name="actif")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"verbose_name": "itinéraire", "verbose_name_plural": "itinéraires"},
        ),
        migrations.CreateModel(
            name="Vehicle",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("identifier", models.CharField(max_length=64, unique=True, verbose_name="immatriculation / code")),
                ("label", models.CharField(blank=True, max_length=120, verbose_name="désignation")),
                ("ext_id_engin", models.CharField(blank=True, max_length=64, verbose_name="id engin externe (GestionCarburantPro)")),
                ("active", models.BooleanField(default=True, verbose_name="actif")),
                ("current_driver", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="vehicles", to="fleet.driver", verbose_name="chauffeur courant")),
            ],
            options={"verbose_name": "véhicule", "verbose_name_plural": "véhicules"},
        ),
        migrations.CreateModel(
            name="Assignment",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("start_at", models.DateTimeField(default=django.utils.timezone.now)),
                ("end_at", models.DateTimeField(blank=True, null=True)),
                ("driver", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="assignments", to="fleet.driver")),
                ("route", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="assignments", to="fleet.route")),
                ("vehicle", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="assignments", to="fleet.vehicle")),
            ],
            options={"verbose_name": "affectation", "verbose_name_plural": "affectations"},
        ),
        migrations.CreateModel(
            name="Position",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("point", django.contrib.gis.db.models.fields.PointField(geography=True, srid=4326)),
                ("recorded_at", models.DateTimeField(verbose_name="horodatage appareil")),
                ("speed", models.FloatField(blank=True, null=True, verbose_name="vitesse (m/s)")),
                ("accuracy", models.FloatField(blank=True, null=True, verbose_name="précision (m)")),
                ("off_route", models.BooleanField(default=False, verbose_name="hors couloir")),
                ("dist_m", models.FloatField(blank=True, null=True, verbose_name="écart au couloir (m)")),
                ("client_id", models.CharField(blank=True, max_length=64, null=True, unique=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("driver", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="positions", to="fleet.driver")),
                ("route", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="positions", to="fleet.route")),
                ("vehicle", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="positions", to="fleet.vehicle")),
            ],
            options={"verbose_name": "position", "verbose_name_plural": "positions"},
        ),
        migrations.CreateModel(
            name="Alert",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(choices=[("off_route", "Sortie de couloir")], default="off_route", max_length=32)),
                ("message", models.CharField(blank=True, max_length=255)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("acked_at", models.DateTimeField(blank=True, null=True, verbose_name="acquittée le")),
                ("driver", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="alerts", to="fleet.driver")),
                ("position", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="alerts", to="fleet.position")),
                ("vehicle", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="alerts", to="fleet.vehicle")),
            ],
            options={"verbose_name": "alerte", "verbose_name_plural": "alertes", "ordering": ["-created_at"]},
        ),
        migrations.AddIndex(
            model_name="position",
            index=models.Index(fields=["driver", "recorded_at"], name="fleet_posit_driver__87e65d_idx"),
        ),
        migrations.AddIndex(
            model_name="position",
            index=models.Index(fields=["vehicle", "recorded_at"], name="fleet_posit_vehicle_2e23a2_idx"),
        ),
    ]
