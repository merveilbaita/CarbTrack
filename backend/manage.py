#!/usr/bin/env python
"""Utilitaire en ligne de commande Django pour CarbTrack."""
import os
import sys


def main():
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "carbtrack.settings")
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError(
            "Django introuvable. Activez l'environnement virtuel / le conteneur."
        ) from exc
    execute_from_command_line(sys.argv)


if __name__ == "__main__":
    main()
