#!/usr/bin/env sh
# Démarrage du conteneur en production (Render) : migrations, compte admin, serveur ASGI.
set -e

python manage.py migrate --noinput

# Crée le compte admin au premier démarrage SI les variables DJANGO_SUPERUSER_* sont
# fournies (idempotent : ne fait rien si le compte existe déjà ou si les variables manquent).
python manage.py createsuperuser --noinput 2>/dev/null \
  && echo ">> Compte admin créé." \
  || echo ">> Compte admin déjà présent ou variables non définies (OK)."

exec daphne -b 0.0.0.0 -p "${PORT:-8000}" carbtrack.asgi:application
