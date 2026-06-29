from django.urls import path

from . import views

urlpatterns = [
    # Pages
    path("", views.map_view, name="dashboard-map"),
    path("routes/", views.routes_view, name="dashboard-routes"),
    path("alerts/", views.alerts_view, name="dashboard-alerts"),
    path("appros/", views.appros_view, name="dashboard-appros"),

    # API JSON (session staff)
    path("dash-api/latest", views.api_latest, name="dash-api-latest"),
    path("dash-api/routes", views.api_routes, name="dash-api-routes"),
    path("dash-api/routes/<int:route_id>", views.api_route_delete, name="dash-api-route-delete"),
    path("dash-api/alerts", views.api_alerts, name="dash-api-alerts"),
    path("dash-api/alerts/<int:alert_id>/ack", views.api_alert_ack, name="dash-api-alert-ack"),
    path("dash-api/appros", views.api_appros, name="dash-api-appros"),
]
