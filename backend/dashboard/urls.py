from django.urls import path

from . import views

urlpatterns = [
    # Pages
    path("", views.map_view, name="dashboard-map"),
    path("routes/", views.routes_view, name="dashboard-routes"),
    path("alerts/", views.alerts_view, name="dashboard-alerts"),
    path("appros/", views.appros_view, name="dashboard-appros"),
    path("history/", views.history_view, name="dashboard-history"),
    path("events/", views.events_view, name="dashboard-events"),
    path("zones/", views.zones_view, name="dashboard-zones"),

    # API JSON (session staff)
    path("dash-api/latest", views.api_latest, name="dash-api-latest"),
    path("dash-api/routes", views.api_routes, name="dash-api-routes"),
    path("dash-api/routes/<int:route_id>", views.api_route_delete, name="dash-api-route-delete"),
    path("dash-api/routes/<int:route_id>/assign", views.api_route_assign, name="dash-api-route-assign"),
    path("dash-api/routes/<int:route_id>/unassign", views.api_route_unassign, name="dash-api-route-unassign"),
    path("dash-api/alerts", views.api_alerts, name="dash-api-alerts"),
    path("dash-api/alerts/<int:alert_id>/ack", views.api_alert_ack, name="dash-api-alert-ack"),
    path("dash-api/appros", views.api_appros, name="dash-api-appros"),
    path("dash-api/track", views.api_track, name="dash-api-track"),
    path("dash-api/directions", views.api_directions, name="dash-api-directions"),
    path("dash-api/daily", views.api_daily, name="dash-api-daily"),
    path("dash-api/events", views.api_events, name="dash-api-events"),
    path("dash-api/zones", views.api_geofences, name="dash-api-zones"),
    path("dash-api/zones/<int:zone_id>", views.api_geofence_delete, name="dash-api-zone-delete"),
]
