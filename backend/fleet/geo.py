"""Évaluation géospatiale d'un point par rapport au couloir d'un itinéraire.

Utilise PostGIS via l'ORM : avec des champs `geography`, `Distance` renvoie
des **mètres**. Un point est "hors couloir" si sa distance au tracé dépasse
`route.corridor_m`.
"""
from django.contrib.gis.db.models.functions import Distance

from .models import Route


def evaluate_point(route: Route, point) -> tuple[bool, float]:
    """Retourne (off_route, dist_m) pour `point` vis-à-vis de `route`.

    `point` est un django.contrib.gis.geos.Point (SRID 4326).
    """
    row = (
        Route.objects.filter(pk=route.pk)
        .annotate(d=Distance("geom", point))
        .values_list("d", flat=True)
        .first()
    )
    # `d` est un objet Distance ; .m donne les mètres (champ geography).
    dist_m = float(row.m) if row is not None else float("inf")
    return dist_m > route.corridor_m, dist_m
