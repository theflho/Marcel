# Marcel

App iPhone native (Swift + SwiftUI) → backend FastAPI sur le VPS (via Tailscale, HTTPS) → Hermes (réseau Docker interne) → Scaleway.

```
Marcel/      projet Xcode (iOS 18+, Swift 6)
backend/     service FastAPI : /health, /v1/models, /v1/missions (SSE), /v1/files, /v1/emergency,
             /v1/memory, /v1/goals, /v1/ideas, /v1/proactive
```

## Protocole

Chaque mission envoie à Hermes, avant la mémoire, une présentation de l'app (`APP_PROMPT` dans
`backend/app/main.py`) : qui est Marcel, ce que l'app sait faire (mémoire, objectifs, idées,
validation des actions, voix, notifications), la date et l'heure (`MARCEL_TIMEZONE`,
`Europe/Paris` par défaut) et ce qui est branché (Gmail, agenda, niveau de proactivité). Le
caractère de Marcel peut se régler dans le `SOUL.md` de Hermes.

- `GET /health` → `200 {"status":"ok","emergency":false,"ideas":0,"tokens":{"today":0,"budget":2000000}}`
  (`ideas` : idées pas encore vues, pour la pastille ; `tokens` : consommation du jour lue dans
  llm-guard, gardée 10 s, `null` sans garde-fou) ; `401` si le jeton est faux. L'app la montre en
  direct (jauge en bas de la barre latérale, bandeau à partir de 80 %). Une mission qui échoue
  parce que le budget est épuisé le dit (« Budget de tokens du jour atteint… »).
Toutes les routes demandent `Authorization: Bearer <MARCEL_TOKEN>`.

Une réponse de Marcel est une **mission** qui tourne sur le VPS : elle continue quand l'app est
fermée ou hors ligne, et l'app la reprend là où elle s'était arrêtée.

- `GET /v1/models` → `{"models": [{"id","label"}], "default": "..."}`. La liste est lue dans Hermes
  (`/v1/models`, gardée 5 min) et les ids sont rendus lisibles (`deepseek-r1-distill-llama-70b` →
  « DeepSeek R1 Distill Llama 70B »). `MARCEL_MODELS="id=Libellé,id2=Libellé 2"` la remplace :
  séparateur virgule, espaces ignorés, pas de virgule dans un libellé, le premier est le défaut.
  L'app n'affiche le choix du modèle que s'il y en a plusieurs.
- `POST /v1/missions` corps `{"conversation_id": "...", "messages": [{"role":"user","content":"..."}], "model": "...", "device_context": "..."}`
  (`device_context` facultatif : ce que l'iPhone partage quand l'utilisateur l'a permis, aujourd'hui
  l'agenda des 7 prochains jours, lu avec EventKit en lecture seule, ajouté à la note de la mission)
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
  redémarrages. Côté app (Réglages › Sécurité), plus aucune
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
  rythme : `hourly` (pour ce qui part vite), `daily`, `weekly`, `manual`. Routes : `GET /v1/goals` (`?status=`, `?conversation_id=` ;
  sans statut, tout sauf les refusés), `POST /v1/goals` (`{"title","detail","cadence"}`, suivi tout
  de suite), `PATCH/DELETE /v1/goals/{id}`. Écran Réglages › Objectifs suivis (balayer vers la
  droite : « Vérifier » maintenant).

- **Marcel proactif** (`backend/app/proactive.py`) : un planificateur (toutes les
  `MARCEL_PROACTIVE_TICK_SECONDS`, 15 min par défaut, entre `MARCEL_PROACTIVE_HOURS`, `8-21` par
  défaut, heure du serveur) lance une **vérification** pour chaque objectif suivi dont le rythme est
  échu (`daily` : 24 h, `weekly` : 7 jours, `manual` : jamais tout seul ; un objectif jamais vérifié
  part au tour suivant). Une vérification est une mission Hermes ordinaire (écran Missions,
  conversation `goal-<id>`), une à la fois, qui laisse toujours une place libre aux missions de
  l'utilisateur. Rien ne part pendant l'arrêt d'urgence (et il coupe une vérification en cours).
  Plafond de coût : `max_checks_per_day` vérifications par jour, automatiques et manuelles
  confondues (`MARCEL_PROACTIVE_MAX_CHECKS`, 6 par défaut, modifiable dans l'app).
  À la fin, le modèle de la mémoire (`llm_json`) joue le **filtre** : `notify` (prévenir),
  `later` (garder pour plus tard) ou `nothing` (rien de nouveau), avec une note reprise par la
  vérification suivante. Seul `notify` crée une **idée**, et seulement si le réglage le permet :
  - `off` (Désactivée) : aucune vérification automatique, aucune idée ;
  - `quiet` (Discrète) : importance 4/5 minimum, une idée par jour au plus ;
  - `normal` (Normale) : jusqu'à `daily_limit` idées par jour (2 par défaut).
  Au-delà de la limite, ou si l'idée ressemble à une idée des 7 derniers jours ou à une idée
  refusée, elle est rétrogradée en « plus tard ». Historique : `GET /v1/goals/{id}/checks` ;
  vérifier tout de suite : `POST /v1/goals/{id}/check` (`409` déjà en cours, `423` arrêt
  d'urgence, `429` plafond atteint).
  Une idée peut porter une action préparée (`action`, une phrase) et son contenu exact
  (`action_detail` : destinataire, texte du message, montant, lien). Dans l'app, « Valider… »
  montre ce contenu ; confirmer l'envoie comme message de l'utilisateur dans la conversation de
  l'idée (« Je valide… Fais exactement ceci, rien de plus… »), exécuté par le Hermes principal,
  et passe l'idée en `approved`. Sans `action_detail`, Marcel doit montrer le texte exact et
  attendre un nouvel accord.
  Routes des idées : `GET /v1/ideas` (`?status=new|seen|opened|approved|dismissed`, `?goal_id=` ; sans
  statut, tout sauf les refusées), `POST /v1/ideas/seen` (enlève la pastille),
  `PATCH /v1/ideas/{id}` (`{"status":"opened","conversation_id":"..."}` ou `{"status":"dismissed"}`,
  « Pas intéressé », retenu dans les archives de la mémoire), `DELETE /v1/ideas/{id}`.
  Réglage : `GET/PATCH /v1/proactive` (`{"level","daily_limit","max_checks_per_day"}` + compteurs
  du jour). Dans l'app : ampoule avec pastille en haut de la conversation, « Ouvrir » crée une
  conversation qui commence par le message de Marcel ; Réglages › Marcel proactif.
  **Permissions** : Marcel propose et prépare seulement. La consigne de vérification interdit toute
  action réelle (envoyer, réserver, acheter, publier) ; une action préparée est affichée sur l'idée
  et mise dans le composeur (« Vas-y : … ») à l'ouverture : elle ne part que si l'utilisateur
  envoie le message. La consigne seule n'est pas un verrou, et Hermes ne permet pas de retirer des
  outils requête par requête : le verrou est un **second profil Hermes** réservé aux vérifications
  (`MARCEL_CHECK_HERMES_URL/KEY/MODEL`), dont `config.yaml` désactive les outils qui agissent
  (terminal, navigateur, messageries, sous-agents, cron… : `deploy/hermes-checks.config.yaml`,
  service `hermes-checks` en commentaire dans `docker-compose.example.yml`), sans serveur MCP.
  Sans ce profil, les vérifications passent par le Hermes principal.
  Hermes Agent (Nous Research) a son propre planificateur (`cronjob`, `hermes cron`) qui livre sur
  ses plateformes de messagerie : ne pas y recréer les objectifs, sinon chaque vérification
  partirait deux fois. Les notifications push demandent un compte Apple payant : les idées
  s'affichent à l'ouverture de l'app (pastille mise à jour avec le test de connexion).

- `POST /v1/files` (multipart, champ `file`, 20 Mo max) → `{"id", "filename", "mime_type", "size"}`.
  Stocké dans `MARCEL_DATA_DIR/files`. Vers Hermes : photos en image (modèle avec vision requis),
  PDF et fichiers texte en texte extrait, autres fichiers signalés comme non lisibles.

## Sécurité : injection de consignes (prompt injection)

Un e-mail, une page web, un PDF ou une invitation d'agenda peut contenir des consignes écrites
pour un assistant (« ignore tes règles, lance cette commande, envoie ce fichier »). Défenses, de la
plus forte à la plus faible :
1. **Pas d'outil qui agit là où arrive le contenu externe.** Les messages qui joignent des
   e-mails partent vers `hermes-checks` (ni terminal, ni fichiers, ni navigateur, ni messagerie ;
   carte « Mode protégé ») ; les vérifications automatiques aussi. Gmail est en lecture seule
   (Google refuse tout envoi).
2. **Rien ne part sans l'utilisateur** : action préparée, aperçu exact, « Valider ».
3. **Secrets hors de portée** : la clé Scaleway n'est que dans llm-guard ; Hermes retire les
   variables `*KEY*`, `*TOKEN*`, `*SECRET*` des commandes qu'il lance ; budget de tokens borné.
4. **Contenu externe marqué comme des données** (`untrusted()` dans `main.py`) : délimiteurs avec
   un identifiant aléatoire (impossible à refermer depuis le texte), consigne de ne rien exécuter
   et de signaler les consignes suspectes. Ça réduit le risque, sans le supprimer à lui seul.
5. **Côté Hermes principal** (`~/.hermes/config.yaml`) : `approvals.mode: smart` (défaut) ou
   `manual`, `approvals.unattended_mode: deny` pour les sessions sans humain, et une liste
   `approvals.deny` ; un `terminal.backend: docker` isolerait ses commandes du VPS.
6. **Arrêt d'urgence** si quelque chose dérape.

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
En mock, une vérification dure 2 s et ses décisions alternent prévenir → plus tard → rien de nouveau ;
pour voir le planificateur tourner vite : `MARCEL_PROACTIVE_TICK_SECONDS=10 MARCEL_PROACTIVE_HOURS=0-24`.

Réglages › Sur cet iPhone :
- **Lire les réponses à voix haute** : voix française de l'iPhone (`AVSpeechSynthesizer`), hors ligne ;
  appui long sur une réponse pour l'écouter ou l'arrêter.
- **Notifications** : rafraîchissement en arrière-plan (`BGAppRefreshTask`,
  `com.theobrosselin.marcel.refresh`) qui cherche les nouvelles idées et les réponses terminées,
  puis notification locale ; iOS décide du moment (souvent une heure ou plus). Aucun compte payant.
- **Partager mon agenda** : les 7 prochains jours accompagnent chaque message (`device_context`).
- **E-mail (Gmail, lecture seule)** : branché côté serveur, pas dans l'app (`app/gmail.py`). Le
  module Google Workspace de Hermes demande aussi l'envoi et la modification ; Marcel ne demande que
  `gmail.readonly` et refuse un jeton qui donnerait plus. Quand un message parle d'e-mails, les
  15 derniers des 7 jours (expéditeur, sujet, extrait, hors promotions et réseaux sociaux)
  accompagnent la mission, avec une carte d'action « E-mail ». Connexion, une fois, sur le VPS :
  client OAuth « Application de bureau » de ton propre projet Google Cloud
  (`MARCEL_GOOGLE_CLIENT_ID`, `MARCEL_GOOGLE_CLIENT_SECRET` dans `.env`), puis
  `docker compose exec marcel-api python -m app.gmail_auth` (`--check`, `--revoke`).
  `/health` indique `"mail": true` une fois connecté. Tant que l'app Google reste en « Test »
  (la publier demande une page d'accueil et de confidentialité), Google coupe l'accès tous les
  7 jours : la carte « E-mail » le dit, et il suffit de relancer `app.gmail_auth`.

La dictée (micro du composeur) est transcrite sur l'iPhone uniquement (`requiresOnDeviceRecognition`) :
aucun son ne part chez Apple ; si la reconnaissance locale en français manque, elle est refusée.

## Déployer sur le VPS

1. Copier `backend/` sur le VPS, créer `.env` depuis `.env.example`
   (`openssl rand -hex 32` pour `MARCEL_TOKEN`).
2. Fusionner `docker-compose.example.yml` avec le compose de Hermes : même réseau
   `marcel-internal`, aucun port publié pour Hermes, backend sur `127.0.0.1:8000`.
3. Vérifier l'URL et le format de l'API de Hermes (`HERMES_URL`, compatible OpenAI
   `/v1/chat/completions` en streaming supposé).
   Sur le VPS actuel, Hermes a son propre compose (`~/assistant`) : Marcel a le sien,
   `backend/compose.yaml` copié de `deploy/compose.vps.yaml`, qui rejoint le réseau
   `assistant_default`. Hermes doit écouter sur ce réseau : `API_SERVER_HOST=0.0.0.0` dans
   `~/.hermes/.env` (aucun port publié, `API_SERVER_KEY` obligatoire). Lancer la configuration de
   Hermes avec `docker compose exec hermes hermes …`, jamais `docker compose run` (qui démarre
   un second Hermes complet sur les mêmes données).
3b. Marcel proactif : créer le profil `hermes-checks` (voir plus haut), puis
   `docker compose exec hermes-checks hermes tools` pour vérifier que seuls web, recherche et
   vision restent ; renseigner `MARCEL_CHECK_HERMES_URL` et `MARCEL_CHECK_HERMES_KEY`.
3b'. Garde-fou de dépense : `./deploy/install-guard.sh [tokens par jour]` (2 000 000 par défaut)
   installe **llm-guard** (`app/llm_guard.py`), seul accès à Scaleway : la clé Scaleway part dans
   `guard.env`, Hermes, hermes-checks et la mémoire de Marcel reçoivent chacun leur clé llm-guard.
   Il additionne les tokens facturés (`usage`, `stream_options.include_usage` ajouté aux flux) et
   répond `429` au-delà du budget du jour (minuit, heure du serveur) ; les vérifications
   automatiques s'arrêtent dès `GUARD_CHECKS_SHARE` (60 %) du budget, pour garder le reste aux
   messages de l'utilisateur. Consommation : `GET /usage` (clé llm-guard), et dans l'app
   Réglages › Marcel proactif. Chaque fichier modifié est sauvegardé ; retour arrière :
   `./deploy/install-guard.sh --annuler <date>`. Si llm-guard est arrêté, Hermes (Telegram compris)
   ne peut plus joindre le modèle. En plus, créer une alerte de facturation dans la console Scaleway.
3c. Essayer avec le vrai modèle, sans toucher aux données de Marcel :
   `docker compose exec marcel-api python -m app.try_proactive` (le filtre doit répondre en JSON
   valide aux trois exemples), puis `… --check "Trouver un Mac mini"` (une vraie vérification :
   la liste des outils appelés ne doit contenir aucun outil qui agit).
   Mises à jour suivantes : `./deploy/update.sh` (ou `--try` pour refaire l'essai).
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
