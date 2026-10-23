# Marcel

App iPhone native (Swift + SwiftUI) → backend FastAPI sur le VPS (via Tailscale, HTTPS) → Hermes (réseau Docker interne) → Scaleway.

```
Marcel/      projet Xcode (iOS 18+, Swift 6)
backend/     service FastAPI : /health et /v1/chat/stream (SSE)
```

## Protocole

- `GET /health` → `200 {"status":"ok"}` ; `401` si le jeton est faux.
- `POST /v1/chat/stream` avec `Authorization: Bearer <MARCEL_TOKEN>`
  corps `{"conversation_id": "...", "messages": [{"role":"user","content":"..."}]}`
  chaque message peut porter `"attachments": ["<id>", …]` (ids renvoyés par `/v1/files`) ;
  réponse SSE, une ligne JSON par événement :
  `data: {"type":"delta","text":"..."}` … `data: {"type":"done"}` ou `data: {"type":"error","message":"..."}`

- `POST /v1/files` (multipart, champ `file`, 20 Mo max) → `{"id", "filename", "mime_type", "size"}`.
  Stocké dans `MARCEL_DATA_DIR/files`. Vers Hermes : photos en image (modèle avec vision requis),
  PDF et fichiers texte en texte extrait, autres fichiers signalés comme non lisibles.

## Tester en local (simulateur)

```bash
cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
MARCEL_TOKEN=dev-local-token MARCEL_MOCK=1 MARCEL_DATA_DIR=.data .venv/bin/uvicorn app.main:app --port 8000
```

Dans le simulateur, l'adresse par défaut est `http://localhost:8000` ; saisir le jeton dans Réglages.

## Déployer sur le VPS

1. Copier `backend/` sur le VPS, créer `.env` depuis `.env.example`
   (`openssl rand -hex 32` pour `MARCEL_TOKEN`).
2. Fusionner `docker-compose.example.yml` avec le compose de Hermes : même réseau
   `marcel-internal`, aucun port publié pour Hermes, backend sur `127.0.0.1:8000`.
3. Vérifier l'URL et le format de l'API de Hermes (`HERMES_URL`, compatible OpenAI
   `/v1/chat/completions` en streaming supposé).
4. Activer « HTTPS Certificates » dans la console Tailscale, puis sur le VPS :
   `sudo tailscale serve --bg 8000`
   → `https://vps-ecc4ab15.tail9a9dd4.ts.net` (tailnet uniquement, certificat valide).

## Installer sur l'iPhone (Apple ID gratuit)

1. Xcode → Réglages → Comptes → ajouter l'Apple ID.
2. Ouvrir `Marcel/Marcel.xcodeproj`, cible Marcel → Signing & Capabilities →
   Team : « (Personal Team) ». Changer le Bundle Identifier s'il est refusé.
3. iPhone branché, déverrouillé, Mode développeur activé ; le choisir comme destination, ⌘R.
4. Au premier lancement : Réglages iPhone → Général → VPN et gestion de l'appareil →
   faire confiance au certificat de développeur.
5. Réinstaller depuis Xcode tous les 7 jours (limite du compte gratuit).
