"""Configuration Django pour CarbTrack (suivi GPS de flotte)."""
import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-insecure-change-me")
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"
ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "*").split(",")

# Render fournit automatiquement le hostname public — on l'ajoute aux hôtes autorisés.
RENDER_HOST = os.environ.get("RENDER_EXTERNAL_HOSTNAME")
if RENDER_HOST:
    ALLOWED_HOSTS.append(RENDER_HOST)

# Origines de confiance pour le CSRF (admin/dashboard en HTTPS).
CSRF_TRUSTED_ORIGINS = [
    o for o in os.environ.get("DJANGO_CSRF_TRUSTED_ORIGINS", "").split(",") if o
]
if RENDER_HOST:
    CSRF_TRUSTED_ORIGINS.append(f"https://{RENDER_HOST}")

# ── Réglages métier tracking ────────────────────────────────────────────────
# Vitesse max tolérée (km/h) avant alerte « excès de vitesse ».
SPEED_LIMIT_KMH = float(os.environ.get("SPEED_LIMIT_KMH", "60"))
# Durée minimale (min) pour qu'un arrêt hors zone soit journalisé.
STOP_MIN_MINUTES = float(os.environ.get("STOP_MIN_MINUTES", "10"))
# Silence GPS : alerte si aucun signal depuis X min (l'app en veille émet
# toutes les 5 min), uniquement pendant les heures de travail [début, fin).
SILENCE_AFTER_MIN = float(os.environ.get("SILENCE_AFTER_MIN", "15"))
WORK_START_HOUR = int(os.environ.get("WORK_START_HOUR", "5"))
WORK_END_HOUR = int(os.environ.get("WORK_END_HOUR", "19"))

INSTALLED_APPS = [
    "daphne",  # doit précéder staticfiles : runserver en mode ASGI (WebSockets)
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.gis",
    "channels",
    "rest_framework",
    "fleet",
    "dashboard",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",  # sert les statiques en prod
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "carbtrack.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "carbtrack.wsgi.application"
ASGI_APPLICATION = "carbtrack.asgi.application"

# Redis si disponible (dev docker-compose), sinon couche en mémoire (free hosting,
# un seul process Daphne) — suffisant pour le push WebSocket du dashboard.
_REDIS_URL = os.environ.get("REDIS_URL")
if _REDIS_URL:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {"hosts": [_REDIS_URL]},
        }
    }
else:
    CHANNEL_LAYERS = {"default": {"BACKEND": "channels.layers.InMemoryChannelLayer"}}

# Prod : DATABASE_URL (Neon). Dev : variables POSTGRES_* (docker-compose).
_DATABASE_URL = os.environ.get("DATABASE_URL")
if _DATABASE_URL:
    import dj_database_url

    DATABASES = {
        "default": dj_database_url.parse(
            _DATABASE_URL,
            engine="django.contrib.gis.db.backends.postgis",
            conn_max_age=600,
            ssl_require=True,
        )
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.contrib.gis.db.backends.postgis",
            "NAME": os.environ.get("POSTGRES_DB", "carbtrack"),
            "USER": os.environ.get("POSTGRES_USER", "carbtrack"),
            "PASSWORD": os.environ.get("POSTGRES_PASSWORD", "carbtrack"),
            "HOST": os.environ.get("POSTGRES_HOST", "localhost"),
            "PORT": os.environ.get("POSTGRES_PORT", "5432"),
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
]

LANGUAGE_CODE = "fr-fr"
TIME_ZONE = "Africa/Kinshasa"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}

# Le dashboard web est réservé au staff ; redirection vers le login admin.
LOGIN_URL = "/admin/login/"

# Sécurité en production (DEBUG=False), derrière le proxy TLS de Render.
if not DEBUG:
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_SSL_REDIRECT = os.environ.get("DJANGO_SSL_REDIRECT", "1") == "1"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "fleet.auth.DriverTokenAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_RENDERER_CLASSES": [
        "rest_framework.renderers.JSONRenderer",
    ],
}
