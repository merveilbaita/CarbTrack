# CarbTrack — Suivi GPS de flotte (anti-vol carburant)

Système de suivi GPS temps réel des chauffeurs, indépendant de **GestionCarburantPro**
(intégration prévue ultérieurement). Objectif : détecter qu'un véhicule **quitte
l'itinéraire de référence (couloir)** afin de prévenir le vol de carburant.

## Composants
- **backend/** — Django 5 + DRF + PostgreSQL/PostGIS. API d'ingestion GPS + détection de
  sortie de couloir (`ST_DWithin`) + dashboard web.
- **mobile/** — *(Phase 2)* app Android Flutter : suivi GPS continu en arrière-plan.
- **infra/** — `docker-compose.yml` (PostGIS + Redis + web).

## Démarrage (dev, via Docker)
Prérequis : Docker Desktop démarré.

```bash
cd infra
cp .env.example .env          # adapter au besoin
docker compose up --build     # construit l'image, applique les migrations, lance le serveur
```

Dans un autre terminal :
```bash
# Données de démo (chauffeur PIN 0000, véhicule, itinéraire + couloir, affectation)
docker compose exec web python manage.py seed_demo
# Superutilisateur pour l'admin Django
docker compose exec web python manage.py createsuperuser
```

- Dashboard / carte live : http://localhost:8001/
- Admin Django : http://localhost:8001/admin/

> Le web est exposé sur **8001** (le port 8000 de l'hôte est déjà pris par GestionCarburantPro).
> Fonctionne avec **Colima** comme avec Docker Desktop.

## API (v1)
| Méthode | Endpoint | Auth | Rôle |
|---|---|---|---|
| POST | `/api/auth/login` | — | `{phone, pin}` → `{token}` |
| POST | `/api/positions` | `Token <token>` | ingestion batch `{positions:[{lat,lng,ts,speed,accuracy,client_id}]}` |
| GET | `/api/positions/latest` | — (*) | dernière position par chauffeur (polling carte) |

(*) à sécuriser avant mise en prod (session staff / token dashboard).

`seed_demo` imprime des commandes `curl` prêtes pour tester un point **dans** et **hors** couloir
(remplacer le port par **8001**).

## App mobile (mobile/)
App Android Flutter du chauffeur, **2 onglets** :
- **Appro (outil principal)** — saisie des approvisionnements : véhicule (liste serveur), date,
  index compteur (précédent pré-rempli → actuel), quantité (L). File offline (`sqflite`) →
  `POST /api/appros`, historique « Derniers appros ».
- **Suivi (option)** — suivi GPS continu : **service de premier plan** (`flutter_foreground_task`
  + `geolocator`) capte la position toutes les 20 s, file offline → `POST /api/positions`,
  état hors-couloir poussé vers l'UI.

```bash
cd mobile
flutter pub get
# Test dev contre le backend local (port 8001) via un téléphone USB :
adb reverse tcp:8001 tcp:8001     # le tél. atteint le PC sur 127.0.0.1:8001
flutter run                       # login : host=127.0.0.1  port=8001  phone=0000000000  PIN=0000
```
Émulateur : utiliser `host=10.0.2.2` (au lieu de `adb reverse`). En prod : activer HTTPS dans l'écran de login.

## Dashboard web (staff)
Réservé au staff (login via `/admin/login/`). Pages :
- **Carte** (`/`) — véhicules live (polling 5 s), itinéraires + couloirs de tolérance (turf), badge alertes.
- **Itinéraires** (`/routes/`) — tracer/supprimer un couloir avec **Leaflet-Geoman** (nom + largeur m).
- **Alertes** (`/alerts/`) — sorties de couloir, acquittement.
- **Appros** (`/appros/`) — tableau des approvisionnements, filtre par chauffeur, total litres.

Endpoints JSON staff sous `/dash-api/*` (session Django, distincts de l'API chauffeur `/api/*`).

**Temps réel** : la carte se met à jour par **WebSocket** (`/ws/dashboard/`, Django Channels + Redis +
Daphne). Chaque position/alerte ingérée est poussée au groupe `dashboard` (repli polling 30 s +
reconnexion auto). Le serveur tourne en ASGI/Daphne.

## Déploiement (Render + Neon, gratuit)
1. **Neon** : créer un projet (région *us-east-1*, co-localisée avec Render *virginia*), activer PostGIS
   (`CREATE EXTENSION IF NOT EXISTS postgis;` dans le SQL Editor), copier la *connection string*
   (`postgresql://…?sslmode=require`).
2. **GitHub** : pousser ce dépôt.
3. **Render** : New → *Blueprint* → sélectionner le repo (lit `render.yaml`). Coller `DATABASE_URL`
   (la chaîne Neon). Déployer. Render fournit l'URL HTTPS `https://carbtrack.onrender.com`.
4. **Superuser** : Render → service → *Shell* → `python manage.py createsuperuser` (et `seed_demo` si besoin).
5. **App mobile** : *Adresse serveur* = `carbtrack.onrender.com`, *Port* = `443`, *HTTPS* = **ON**.

> Free Render : le service s'endort après 15 min d'inactivité (réveil 30-60 s). Les pings des
> chauffeurs le gardent éveillé en journée ; le buffer offline évite toute perte. 7 $/mois supprime
> le spin-down. Channels tourne sans Redis (couche en mémoire, 1 process Daphne).

## Phases
1. ✅ Backend cœur (modèles, API, détection couloir, carte live polling).
2. ✅ App Android Flutter (Appro + Suivi GPS, comptes liés au camion). E2E S24 validé.
3. ✅ Dashboard web (carte live, éditeur de couloir Leaflet-Geoman, alertes, appros par chauffeur).
4. ✅ Temps réel (Channels + Redis + Daphne, WebSocket push positions/alertes). *Reste : historique/replay.*
5. ✅ Hébergement prêt — **Render** (backend Docker, HTTPS gratuit) + **Neon** (Postgres PostGIS). Voir `render.yaml` et la section ci-dessous.
6. ⬜ Intégration GestionCarburantPro (corrélation prise carburant ↔ position).
