# Marcel

App iPhone native (Swift + SwiftUI) → backend FastAPI sur le VPS (via Tailscale, HTTPS) → Hermes (réseau Docker interne) → Scaleway.

```
Marcel/      projet Xcode (iOS 18+, Swift 6)
backend/     service FastAPI : /health, /v1/models, /v1/missions (SSE), /v1/files, /v1/emergency
```

## Protocole

- `GET /health` → `200 {"status":"ok","emergency":false}` ; `401` si le jeton est faux.
Toutes les routes demandent `Authorization: Bearer <MARCEL_TOKEN>`.

Une réponse de Marcel est une **mission** qui tourne sur le VPS : elle continue quand l'app est
fermée ou hors ligne, et l'app la reprend là où elle s'était arrêtée.

- `GET /v1/models` → `{"models": [{"id","label"}], "default": "..."}`. La liste est lue dans Hermes
  (`/v1/models`, gardée 5 min) et les ids sont rendus lisibles (`deepseek-r1-distill-llama-70b` →
  « DeepSeek R1 Distill Llama 70B »). `MARCEL_MODELS="id=Libellé,id2=Libellé 2"` la remplace :
  séparateur virgule, espaces ignorés, pas de virgule dans un libellé, le premier est le défaut.
  L'app n'affiche le choix du modèle que s'il y en a plusieurs.
- `POST /v1/missions` corps `{"conversation_id": "...", "messages": [{"role":"user","content":"..."}], "model": "..."}`
  (chaque message peut porter `"attachments": ["<id>", …]`, ids renvoyés par `/v1/files` ; `model` facultatif)
  → `{"id", "status", "length", "model", "title", "actions", …}` immédiatement ;
  `429` si 4 missions tournent déjà, `423` pendant l'arrêt d'urgence, `400` si le modèle est inconnu.
- `GET /v1/missions/{id}/events?offset=N` → SSE du texte à partir de `N` (en points de code Unicode),
  puis en direct jusqu'à la fin : `data: {"type":"delta","text":"..."}` …
  Les étapes de l'agent (appels d'outils Hermes) arrivent en liste complète à chaque changement :
  `{"type":"actions","actions":[{"id","name","detail","status"}]}` (`running`, `done`, `cancelled`).
  puis `{"type":"done"}`, `{"type":"stopped"}` ou `{"type":"error","message":"..."}`.
  Un commentaire `: ping` part toutes les 15 s pour garder la connexion ouverte.
- `POST /v1/missions/{id}/cancel` → arrête la mission (le texte déjà écrit est gardé).
- `GET /v1/missions/{id}` → état et texte complet ; `GET /v1/missions?conversation_id=…&active=true` → liste.
- Statuts : `running`, `done`, `stopped`, `failed`, `interrupted` (le serveur a redémarré pendant la mission).
  Les missions sont enregistrées dans `MARCEL_DATA_DIR/marcel.db` (SQLite).
- Arrêt d'urgence : `POST /v1/emergency/stop` coupe toutes les missions et refuse les nouvelles
  (`423`) jusqu'à `POST /v1/emergency/resume` ; état dans `GET /v1/emergency`. Il survit aux
  redémarrages. Côté app (bouton rouge dans la barre latérale ou Réglages › Sécurité), plus aucune
  requête ne part — ni test de connexion, ni envoi, ni reprise — tant qu'on n'a pas touché « Reprendre ».

- Mémoire en trois niveaux (`MARCEL_DATA_DIR/marcel.db`), pour ne jamais saturer :
  - **noyau** : quelques faits stables, envoyés avec chaque mission, plafonnés à
    `MARCEL_MEMORY_CORE_CHARS` caractères (1 500 par défaut) ;
  - **archives** : sans limite, recherche plein texte (FTS5) ; seuls les ~8 souvenirs liés à la
    question accompagnent la mission (carte d'action « Mémoire » dans l'app) ;
  - **rangement** chaque nuit à `MARCEL_MEMORY_TIDY_HOUR` h (3 h par défaut) ou à la demande :
    expire les faits périmés, fusionne les doublons, fait monter au noyau ce qui sert souvent
    (3 fois en 30 jours) et redescendre ce qui n'a pas servi depuis 60 jours ou dépasse le budget.
    Les souvenirs épinglés ne bougent jamais.
  Après chaque mission terminée, le modèle extrait les faits durables de l'échange
  (`MARCEL_MEMORY_LLM_URL/KEY/MODEL`, Hermes par défaut ; un accès direct au modèle évite de faire
  tourner l'agent pour ces petites tâches). Chaque changement est journalisé et annulable.
  Routes : `GET/POST /v1/memory` (`?q=`, `?tier=core|archive`), `PATCH/DELETE /v1/memory/{id}`,
  `GET /v1/memory/log`, `POST /v1/memory/log/{id}/undo` (annule tout le lot d'un rangement ou
  d'un import), `POST /v1/memory/tidy`, `POST /v1/memory/import` (`{"text": "..."}`, entrées
  séparées par `§` comme dans le `MEMORY.md` de Hermes, sinon une par ligne).
  Pour libérer la mémoire intégrée de Hermes, importer son `MEMORY.md` ici puis le vider.

- Objectifs (`goals`, même base) : ce que l'utilisateur veut accomplir et que Marcel suit.
  Pendant l'extraction de la mémoire, le modèle repère un objectif qui dure (« je cherche un Mac
  mini ») et le **propose** seulement : statut `proposed`, carte « Marcel peut suivre ça pour toi »
  au-dessus du composeur avec « Suivre » / « Non merci ». Un objectif refusé (`dismissed`) n'est
  plus jamais reproposé, ni un objectif proche d'un existant. Les objectifs suivis (`active`)
  accompagnent chaque mission. Statuts : `proposed`, `active`, `paused`, `done`, `dismissed` ;
  rythme : `daily`, `weekly`, `manual` (stocké pour les vérifications automatiques, pas encore
  exécutées). Routes : `GET /v1/goals` (`?status=`, `?conversation_id=` ; sans statut, tout sauf
  les refusés), `POST /v1/goals` (`{"title","detail","cadence"}`, suivi tout de suite),
  `PATCH/DELETE /v1/goals/{id}`. Écran Réglages › Objectifs suivis.

- `POST /v1/files` (multipart, champ `file`, 20 Mo max) → `{"id", "filename", "mime_type", "size"}`.
  Stocké dans `MARCEL_DATA_DIR/files`. Vers Hermes : photos en image (modèle avec vision requis),
  PDF et fichiers texte en texte extrait, autres fichiers signalés comme non lisibles.

## Tester en local (simulateur)

```bash
cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
MARCEL_TOKEN=dev-local-token MARCEL_MOCK=1 MARCEL_DATA_DIR=.data .venv/bin/uvicorn app.main:app --port 8000
```

Dans le simulateur, le serveur « Mac (développement) » (`http://localhost:8000`) est utilisé par défaut ;
saisir le jeton dans Réglages › Serveurs. Un message contenant « mission » donne une réponse lente
en 8 étapes (environ 20 s, avec cartes d'actions) pour tester la fermeture de l'app pendant que
Marcel travaille. Le mode mock propose deux modèles DeepSeek pour tester le choix du modèle.
En mock, la mémoire retient les phrases où l'on parle de soi (« Je cherche un Mac mini… ») et
« Tu te souviens de… » affiche les souvenirs transmis ; écran Réglages › Mémoire de Marcel.
Une phrase comme « Je cherche… », « Je veux… », « Je prépare… » fait proposer un objectif ;
« Quels objectifs tu suis ? » liste ceux qui sont suivis.

La dictée (micro du composeur) est transcrite sur l'iPhone uniquement (`requiresOnDeviceRecognition`) :
aucun son ne part chez Apple ; si la reconnaissance locale en français manque, elle est refusée.

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
