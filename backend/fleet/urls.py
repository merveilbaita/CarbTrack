from django.urls import path

from . import views

urlpatterns = [
    path("ping", views.health, name="api-ping"),
    path("auth/login", views.login, name="api-login"),
    path("positions", views.ingest_positions, name="api-positions"),
    path("positions/latest", views.positions_latest, name="api-positions-latest"),
    path("fleet/latest", views.fleet_latest, name="api-fleet-latest"),
    path("routes", views.create_route, name="api-create-route"),
    path("zones", views.create_zone, name="api-create-zone"),
    path("vehicles", views.vehicles_list, name="api-vehicles"),
    path("appros", views.ingest_appros, name="api-appros"),
    path("appros/recent", views.appros_recent, name="api-appros-recent"),
]
