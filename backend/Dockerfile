FROM python:3.12-slim

# GeoDjango a besoin de GDAL/GEOS/PROJ
RUN apt-get update && apt-get install -y --no-install-recommends \
        binutils libproj-dev gdal-bin libgdal-dev \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Collecte des fichiers statiques (admin) au build → démarrages rapides en prod.
RUN python manage.py collectstatic --noinput

EXPOSE 8000

# Prod (Render) : script de démarrage = migrations + serveur ASGI Daphne.
# (En local, docker-compose surcharge cette commande.)
CMD ["sh", "render-start.sh"]
