#!/usr/bin/env sh
# Démarrage du conteneur en production (Render) : migrations puis serveur ASGI.
set -e

python manage.py migrate --noinput

exec daphne -b 0.0.0.0 -p "${PORT:-8000}" carbtrack.asgi:application
