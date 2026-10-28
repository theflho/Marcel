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
  L'app n'affiche le choix du modèle que s'il y en a plusieurs. **Attention** : Hermes ignore le
  `model` d'une requête tant que `gateway.platforms.api_server.direct_model_requests: true` n'est
  pas dans son `config.yaml` ; sans ce réglage, le choix de l'app ne change rien.
- **Modèle renfort** (facultatif) : `MARCEL_STRONG_MODEL` (ex. `claude-sonnet-4-5`) et
  `MARCEL_STRONG_LABEL` ajoutent à la liste ce modèle « (renfort) » et, en tête, **Auto** : le modèle
  habituel, et le renfort quand le message le demande (document joint à étudier, message de plus de
  1 500 caractères, ou mots comme « analyse », « contrat », « stratégie », « script », « en
  profondeur »). Carte « Modèle renfort » avec la raison, et la réponse affiche le modèle vraiment
  utilisé. Jamais pour les e-mails ni les réglages d'assistants ; jamais pour les vérifications ni
  les routines. Le renfort passe par llm-guard, qui l'envoie à son fournisseur selon le nom du
  modèle (`GUARD_ROUTES="claude-|https://api.anthropic.com/v1|<clé>|300000"` dans `guard.env` :
  préfixe, adresse compatible OpenAI, clé, tokens par jour), avec **son propre budget** ; une fois
  épuisé, Auto reprend le modèle habituel (carte « budget du jour atteint »). Les messages envoyés
  au renfort quittent Scaleway : ce fournisseur les voit.
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

## Routines (tâches à heure fixe)

Une **routine** est une tâche que Marcel fait seul à heure fixe, sans suivi dans le temps
(« chaque lundi à 8 h, le point de ma semaine », « chaque soir, résume mes e-mails ») ; un objectif,
lui, suit quelque chose jusqu'à ce qu'il aboutisse. `backend/app/routines.py`.
- Création : Réglages › **Routines** (titre, consigne, jours, heure), ou Marcel lui-même quand
  l'utilisateur le demande (bloc ` ```routine ` en fin de réponse, appliqué par le serveur, jamais
  quand la réponse s'appuie sur un e-mail ou un fichier).
- Départ : le planificateur regarde chaque minute ; heure du serveur (`MARCEL_TIMEZONE`). Une routine
  manquée (serveur arrêté) part à son retour jusqu'à 3 h plus tard, sinon elle attend la suivante.
  Plafond : `MARCEL_ROUTINES_MAX_PER_DAY` (10). Rien pendant l'arrêt d'urgence ni quand la part
  « vérifications » du budget de tokens est dépensée. « Lancer » (balayage) la fait partir tout de suite.
- Sur un e-mail : `email` / `email:expéditeur` (Gmail, regardé toutes les 5 min) ou `boite` /
  `boite:expéditeur` (la boîte AgentMail de Marcel, regardée chaque minute : pour les alertes d'un site
  dont le compte est à son adresse, ex. `boite:ticketmaster`). Lu en Mode protégé ; « Rien à
  signaler. » ne dérange pas. Le premier relevé note seulement ce qui est là.
- **Sans outil qui agit** : la routine va au Hermes des vérifications (`hermes-checks`), sans la
  mémoire (il lit le web) mais avec les totaux, le planning, les objectifs et le dernier compte rendu
  du robot ; si elle parle d'e-mails, au **modèle seul** sans aucun outil (Mode protégé), mémoire
  comprise. Elle prépare, elle n'envoie rien.
- Résultat : chaque routine a **sa conversation** sur l'iPhone (identifiant fixe), où arrivent ses
  réponses et où l'utilisateur peut répondre (le Marcel complet reprend alors). Notification locale
  quand l'app est fermée.
- Routes : `GET/POST /v1/routines`, `PATCH/DELETE /v1/routines/{id}`, `POST /v1/routines/{id}/run`,
  `GET /v1/routines/{id}/runs`, `GET /v1/routine-runs` (passages terminés pas encore remis à
  l'iPhone, avec le texte), `POST /v1/routine-runs/{id}/delivered`.

## Marcel modifie son propre code

Marcel a des outils MCP pour travailler sur le dépôt (l'app et le serveur), comme un développeur,
dans **sa propre copie** (`/data/code/repo` du conteneur, git installé dans l'image) :

| Outil | Ce qu'il fait |
|---|---|
| `marcel_code_commencer` | nouvelle branche `marcel/<sujet>-<date>` depuis la dernière version de main |
| `marcel_code_reprendre` | revient sur la branche d'une de ses pull requests ouvertes |
| `marcel_code_fichiers`, `_lire`, `_chercher` | parcourir le code (lecture avec numéros de ligne, `git grep`) |
| `marcel_code_ecrire`, `_remplacer` | créer un fichier, remplacer un passage exact et unique |
| `marcel_code_verifier`, `_diff` | Python compilé, shell relu, JSON lu ; diff par rapport à main |
| `marcel_code_proposer` | commit, push, ouvre (ou met à jour) la pull request — **refusé si la vérification échoue** |
| `marcel_code_ci` | résultat de la CI GitHub sur la PR, avec la fin du journal de ce qui a échoué |
| `marcel_code_fusionner` | fusion *squash* dans main — **seulement ses PR `marcel/…`, et seulement au vert** |
| `marcel_code_annuler` | défait une PR fusionnée (PR de revert fusionnée aussitôt ; le déploiement suit) |
| `marcel_code_etat` | branche, fichiers modifiés, PR ouvertes, derniers déploiements |
| `marcel_journaux` | dernières lignes du journal du serveur (secrets masqués) et du dernier déploiement raté |

Garde-fous qui ne dépendent pas du modèle (`app/code_tools.py`) :
- jamais sur main (seulement une branche `marcel/…`), rien hors du dépôt ni dans `.git/` ;
- des fichiers **protégés** que seul l'utilisateur modifie : secrets (`.env`, `*.key`…), `.github/`
  (donc la CI), `backend/deploy/auto-update.sh`, `backend/app/code_tools.py`, `llm_guard.py`
  (budgets), `mcp.py` (accès des outils), `server_log.py` (secrets masqués), `hermes_config.py`
  et `backend/tests/test_server.py` ;
- dans `backend/app/main.py`, les **garde-fous** sont entre `# garde-fou : <nom>` et
  `# fin garde-fou : <nom>` (jeton, arrêt d'urgence, mode protégé des conversations et des
  routines, contenu extérieur jamais rendu ni appliqué, navigateur et `browser_vault`, fusion au
  vert). Chaque bloc doit rester identique à celui de main et ce qu'il définit ne peut pas être
  redéfini ailleurs : refusé à l'écriture et avant le push. C'est une barrière solide, pas une
  preuve : du code nouveau ailleurs pourrait contourner un garde-fou, d'où la relecture des PR.
La clé GitHub est passée à chaque commande git, jamais écrite dans la copie.

**CI** (`.github/workflows/ci.yml`, sur chaque PR et sur main) : tests du serveur (`pytest`,
`pyflakes`, `bash -n`) et compilation de l'app pour le simulateur (macOS, sans signature).
`marcel_code_fusionner` lit les *check runs* de la PR et refuse tant qu'ils ne sont pas tous verts ;
il ne fusionne que ses propres PR (`marcel/…`), jamais celles de Claude Code ou de Codex. Un
changement d'app fusionné arrive sur l'iPhone quand on le réinstalle depuis Xcode.

**Annuler** : `marcel_code_annuler`, ou le bouton **Annuler** sur une fusion dans Réglages › Code de
Marcel (`POST /v1/code/revert {"number"}`). L'app envoie une notification pour une fusion, une
annulation, un retour arrière ou une panne.

Réglage : `MARCEL_GITHUB_REPO` (ex. `theflho/Marcel`) et `MARCEL_GITHUB_TOKEN`, clé GitHub
*fine-grained* limitée à ce dépôt : **Contents**, **Issues** et **Pull requests** en lecture et
écriture, **Actions** en lecture (résultats et journaux de la CI). Suivi : Réglages › **Code de Marcel** (PR proposées et fusionnées, déploiements, retours
arrière ; `GET /v1/code-log`).

**Déploiement automatique** (`backend/deploy/auto-update.sh`, sur le VPS, à mettre soi-même dans
la crontab de `ubuntu`) :
```
*/5 * * * * cd ~/marcel/backend && ./deploy/auto-update.sh >> ~/marcel-auto-update.log 2>&1
```
Toutes les 5 minutes : si main a avancé, `git merge --ff-only`, `docker compose up -d --build`,
puis `/health` pendant 2 minutes. S'il ne répond pas, retour au commit précédent, reconstruction,
et cette version n'est **plus retentée** (`.auto-update-refused` ; la suivante l'est). Rien ne part
pendant l'arrêt d'urgence. Chaque résultat est envoyé à `POST /v1/deploy/report`, avec la fin du
journal du build et du serveur quand ça rate (Marcel le lit avec `marcel_journaux`). Le script
refuse de tourner deux fois en même temps (flock).

**Config de Hermes par le code** : après chaque déploiement réussi, le script copie les skills dans
`skills/marcel/` du dossier de Hermes et fusionne `backend/deploy/hermes-overrides.yaml` dans son
`config.yaml` (`app/hermes_config.py`, commentaires gardés, copie `config.yaml.avant-marcel`), en
conteneur jetable sous l'utilisateur de Hermes. Sur le VPS, Hermes tourne sous l'utilisateur
`hermes` (service systemd `hermes-gateway`, dossier `/home/hermes/.hermes`, réglables par
`MARCEL_HERMES_HOME` et `MARCEL_HERMES_SERVICE`) ; un Hermes en conteneur se règle avec
`MARCEL_HERMES_CONTAINER`. Puis Hermes redémarre, ce qui le reconnecte au MCP ; s'il ne répond plus,
l'ancienne config revient et celle-ci n'est plus retentée (`.hermes-overrides-refused`). Le fichier
ne fait qu'ajouter ou changer des clés ; sont refusés : `model`, les fournisseurs, `gateway`, tout
secret en clair (seul `${MARCEL_MCP_TOKEN}` est remplacé, pour le serveur MCP `marcel`, qui reste
interne : `http://127.0.0.1:8000/mcp` pour un Hermes sur la machine, `http://marcel-api:…` en conteneur).

**Gros chantier, en option : Claude Code ou Codex.** Marcel peut aussi, s'il le juge mieux,
rédiger une demande pour un agent de code (bloc ` ```demande-code `, carte « Envoyer à … »). L'agent
se choisit dans Réglages › **Code de Marcel** (ou `MARCEL_CODE_AGENT=claude|codex` par défaut ;
`PUT /v1/code-requests/agent`). Le serveur relit la demande dans la réponse de Marcel elle-même,
refuse si elle s'appuie sur un e-mail ou un fichier joint, et ouvre une issue avec l'étiquette de
l'agent :
- `marcel` → `.github/workflows/marcel-code.yml`, **Claude Code** (`anthropics/claude-code-action@v1`,
  secret `ANTHROPIC_API_KEY`), branche `claude/issue-<n>-…` ;
- `marcel-codex` → `.github/workflows/marcel-codex.yml`, **Codex d'OpenAI** (`openai/codex-action@v1`,
  secret `OPENAI_API_KEY`, variable facultative `MARCEL_CODEX_MODEL`), branche `codex/issue-<n>-…`.
  Codex travaille sans la clé GitHub ; le workflow refuse de pousser s'il a touché un fichier
  protégé, lance `py_compile` et ouvre la PR avec son résumé.
Seules les issues ouvertes par le propriétaire du dépôt lancent un agent. La PR se relit et se
fusionne sur GitHub. Routes : `GET /v1/code-requests`, `POST /v1/code-requests` `{"mission_id"}`.

## Outils et skills de Marcel pour Hermes

Le Hermes principal reçoit les outils MCP de Marcel (`deploy/hermes-mcp.config.yaml`) :
- en lecture : `marcel_resume`, `marcel_planning`, `marcel_offres`, `marcel_robot`,
  `marcel_historique`, `marcel_reponse`, `marcel_memoire`, `marcel_objectifs`, `marcel_routines`,
  `marcel_chercher` ;
- qui agissent : `marcel_retenir` (mémoire), `marcel_creer_objectif`, `marcel_creer_routine`,
  `marcel_lancer_routine`, `marcel_bot` (un bot qui répond sur Telegram, voir plus bas), et les
  outils `marcel_code_*` ci-dessus. **Aucun** ne supprime ni
  n'épingle : ça reste à l'utilisateur, dans l'app.

Et quatre skills (`backend/deploy/hermes-skills/`, copiées dans `~/.hermes/skills/marcel/` par
`update.sh` et `auto-update.sh`) : `marcel-code` (le déroulé d'une modification et quand ne pas
fusionner), `marcel-donnees` (où chercher avant de redemander), `marcel-routines-objectifs`,
`marcel-bots` (« /planning … » sur Telegram → `marcel_bot`).
Hermes les lit à son prochain lancement (`hermes skills list` pour vérifier).

**Hermes passe par llm-guard** : sur le VPS, le Hermes principal (et les profils des bots, copiés de
lui) appelle `http://127.0.0.1:4000/v1` avec la clé « hermes » de `GUARD_KEYS`
(`HERMES_CUSTOM_API_SCALEWAY_AI_API_KEY` dans `/home/hermes/.hermes/.env`) : la clé Scaleway ne
reste que dans `guard.env`, et ses tokens comptent dans le budget du jour. llm-guard est publié sur
`127.0.0.1:4000` seulement (`deploy/compose.vps.yaml`), puisque ce Hermes tourne hors de Docker.

## Les outils de Hermes dans l'app

Par défaut, le serveur d'API de Hermes (celui que l'app appelle) coupe `clarify`,
`text_to_speech`, `computer_use` et `kanban`. `deploy/hermes-overrides.yaml` lui donne la liste du
terminal (`platform_toolsets.api_server`) plus le kanban, et les profils des bots la recopient.
Restent coupés : `clarify` (l'API n'a personne à qui poser la question : Marcel la pose dans sa
réponse) et `text_to_speech` (le fichier son resterait sur le serveur : l'app lit les réponses à voix
haute). `computer_use` n'apparaît que si le serveur a un écran (`cua-driver`).

## Hermes, seul cerveau

Tout ce qui pense passe par Hermes : Marcel, chaque bot (son profil, toujours avec ses outils), les
e-mails (profil `marcel-protege`, sans rien), et les petits appels JSON de Marcel (tri des idées).
La **mémoire est celle de Hermes** (`MEMORY.md`, `USER.md`, ses sessions, une par profil) : Marcel
n'envoie plus la sienne, n'apprend plus rien après une conversation et ne range plus rien la nuit ;
ses outils `marcel_retenir` et `marcel_memoire` ont disparu. Ses anciens souvenirs restent visibles
dans Réglages › Mémoire. Le profil `marcel-protege` est fait par `app/hermes_profiles.py` (« bare ») :
pas de `mcp_servers`, `platform_toolsets.api_server: []`, pas de plugin, mémoire et relecture
de fond (`background review`) coupées, rien pour livrer.

## L'app, plateforme de Hermes (comme Telegram)

Hermes est le cerveau, l'app un écran. Ce que Hermes envoie seul (résultats de ses tâches cron,
`send_message`) passe par le plugin de plateforme `marcel` (`deploy/hermes-plugins/marcel`,
installé dans `~/.hermes/plugins/` et activé par `plugins.enabled` dans hermes-overrides.yaml) :
`POST /v1/hermes/deliver` (clé MCP), et Marcel le range dans la conversation « Hermes » du bot,
que l'app relève avec les messages Telegram (`GET /v1/bot-messages`, `via: "Hermes"`) et notifie.
Marcel ne décide rien : il transporte. Le serveur d'API de Hermes, lui, ne pousse jamais rien.
- **Qui reçoit** : chaque profil livre à son bot. `app/hermes_profiles.py` met dans son `.env`
  `MARCEL_DELIVER_KEY` (le `MARCEL_MCP_TOKEN`) et `MARCEL_HOME_CHANNEL=<bot>` (`marcel` pour le
  profil principal) ; une tâche créée depuis l'app n'a pas d'origine et va donc à ce canal
  d'accueil. Si le `.env` principal change, `auto-update.sh` redémarre Hermes.
- **Ce qui reste à Marcel** : les routines sur un e-mail (`email`, `boite`), lues en mode protégé,
  et les objectifs, dont les vérifications tournent sans outil qui agit et sans mémoire.
  La règle « routine » vaut aussi pour une tâche cron.

## Un bot = un profil Hermes

Chaque bot (Planning, Pointage, Offres, Mails, Veille et ceux que l'utilisateur crée) est un
**profil Hermes** `marcel-<bot>` : son `SOUL.md`, sa mémoire, ses sessions et ses skills à lui.
Le gateway principal les sert tous sur son port, sous `/p/<profil>/` (`gateway.multiplex_profiles`),
et les prend à chaud : créer ou retirer un profil ne redémarre rien.
- **Qui décide** : `GET /v1/hermes/profiles` donne les profils voulus, un par bot, avec leur `SOUL.md`.
  `deploy/auto-update.sh` les synchronise à chaque passage (toutes les 5 min, avant de chercher une
  nouvelle version) : il crée les manquants avec `hermes profile create --clone-from default`
  (modèle, outils, MCP et skills du profil principal, jamais ses jetons de messagerie), retire ceux
  dont le bot n'existe plus, puis `app/hermes_profiles.py` finit chacun : `SOUL.md`, serveur MCP
  `marcel` copié du profil principal avec `X-Marcel-Bot: <bot>`, mêmes outils d'API
  (`platform_toolsets.api_server`), `.env` sans `API_SERVER_*` (le port
  reste au gateway principal). Rien n'est refait tant que la liste et la config principale ne
  changent pas (`.hermes-profiles-applied`). Seuls les profils `marcel-*` sont touchés.
- **Qui répond** : une conversation d'un bot (toujours avec outils, sauf avec des e-mails) et sa tâche permanente
  vont à `HERMES_URL/p/marcel-<bot>/` dès que le profil répond (vérifié chaque minute) ; avant, au
  Hermes principal, comme sans profil. Les e-mails restent en Mode protégé (profil `marcel-protege`).
- **Ses outils** : l'en-tête `X-Marcel-Bot` fait suivre aux outils `marcel_*` les règles de ce bot, et
  `marcel_retenir` écrit dans sa mémoire.
- Le serveur Marcel ne touche jamais au VPS : il ne fait que dire ce qu'il faut.


Le navigateur de Hermes (`browser_exec`, `browser_cdp`…, toolset `browser`, qui demande aussi
`terminal`) clique, tape et envoie des formulaires **sans étape de confirmation**. Par défaut
(`MARCEL_BROWSER_GUARD=0`), Marcel s'en sert seul quand la tâche le demande et dit ensuite ce qu'il
a fait. Restent toujours :
- `browser_vault` (identifiants et carte enregistrés) suit les règles **Comptes** (« Créer un compte
  ou s'y connecter », tout seul par défaut) et **Réservations et achats** (demander par défaut) de
  Réglages › Règles : ouvert si l'une est sur « Tout seul », ou sur « Demander » après « Vas-y » ;
  sinon la réponse s'arrête au premier appel. Jamais dans une routine. Le prompt donne à Marcel le
  **plafond par achat** (50 € par défaut, réglé dans Règles) : au-delà, il attend « Vas-y ». Ce
  plafond n'est qu'une consigne : le vrai est celui de la carte. Ne mettre dans le coffre que
  l'identité de Marcel (sa boîte, ses mots de passe) et une **carte virtuelle plafonnée** ;
- sa boîte mail (AgentMail, `MARCEL_AGENTMAIL_KEY`, `MARCEL_AGENTMAIL_INBOX`) : il crée ses comptes
  avec elle et la lit seulement (`marcel_boite`, `marcel_boite_lire`, contenu marqué extérieur) ;
- les routines, vérifications, e-mails et assistants n'ont jamais le navigateur (Hermes bridé ou
  modèle seul).
`MARCEL_BROWSER_GUARD=1` remet l'accord préalable : la réponse est coupée dès un appel `browser*`,
sauf si le message de l'utilisateur commence par « Vas-y », « Je valide », « Fais-le »… (c'est ce
qu'envoie « Valider » sur une idée). C'est un garde-fou côté Marcel, qui coupe la requête vers
Hermes : il ne garantit pas qu'une action déjà lancée soit annulée.
Activer le navigateur du Hermes principal (sur le VPS, à faire soi-même) : `hermes tools` (choisir
`browser` pour la plateforme de l'API), Chromium installé dans le conteneur (`hermes pm install
chromium`), puis redémarrer Hermes. Sans ce réglage, Marcel n'a pas de navigateur du tout.

## Ce que Marcel voit de ses données

Le modèle ne voit que ce qui est joint à chaque message ; Hermes, dans son conteneur, n'a pas
accès à la base de Marcel. Pour qu'il ne devine pas (« 45 missions » dit un jour, introuvable le
lendemain) :
- **Carte de l'architecture** dans les consignes de Marcel (`APP_PROMPT`) : où sont les données,
  ce qui est joint (un extrait), ne pas chercher dans le terminal, les conversations restent sur
  l'iPhone, et le mot piège « mission » (mission RMA ≠ réponse de Marcel ; pas de statut
  « validée » au portail).
- **Totaux à jour** joints à chaque message, assistants compris (`data_overview`) : planning gardé
  (passé sur 45 jours, heures, à venir, en cours, prochaine), dernier compte rendu du robot, offres
  en attente / acceptées / refusées sur 30 jours, objectifs, idées, mémoire.
- **Outils de lecture MCP** pour le Hermes principal : `POST /mcp` (transport « streamable HTTP »,
  réponses JSON, sans session), clé propre `MARCEL_MCP_TOKEN` (vide = désactivé ; `423` pendant
  l'arrêt d'urgence). Outils : `marcel_resume`, `marcel_planning` (`du`, `au`, 120 jours max),
  `marcel_offres`, `marcel_robot`, `marcel_historique` (cherche dans toutes les réponses passées,
  par le sens puis par les mots, sauf celles tirées d'e-mails ou de pièces jointes),
  `marcel_reponse`, `marcel_memoire`, `marcel_objectifs`, `marcel_chercher` (mémoire, réponses
  passées et planning d'un coup, par le sens, avec un score). Lecture seule. Brancher : `deploy/hermes-mcp.config.yaml` dans le `config.yaml` du Hermes principal
  (jamais dans `hermes-checks`), puis redémarrer Hermes. Les conversations protégées (e-mails,
  assistants) restent sans aucun outil : elles n'ont que la carte et les totaux.
- **Recherche par le sens** (`app/semantic.py`) : « missions validées » retrouve « 45 missions
  lues… confirmées par l'agence » sans mot commun. Les souvenirs actifs, les réponses passées
  (365 jours, découpées en morceaux) et le planning gardé reçoivent un vecteur (embeddings
  `/v1/embeddings` compatible OpenAI, via llm-guard, modèle `MARCEL_EMBED_MODEL`, par défaut
  `bge-multilingual-gemma2`), rangé dans la table `vectors` de `marcel.db` et recalculé seulement
  quand le texte change (après chaque souvenir, chaque planning, et toutes les 10 minutes).
  À chaque message, les souvenirs proches passent avant ceux trouvés par les mots, et Marcel
  reçoit jusqu'à 3 réponses passées d'autres conversations (encadrées comme contenu externe) et
  les missions du planning proches de la question. Les réponses tirées d'e-mails ou de pièces
  jointes ne sont jamais indexées. Si le modèle d'embeddings ne répond pas (8 s), la recherche
  par les mots continue seule. Tests locaux (`MARCEL_MOCK=1`) : un substitut local (mots et
  morceaux de mots hachés) fait tourner tout le circuit, sans les synonymes. Dépendance : numpy.

## Planning RMA et rappels de pointage

Un robot (`backend/rma`, conteneur `rma`, Playwright) lit chaque jour (19 h par défaut, réglable
avec l'assistant Planning) le planning du
portail salarié RMA, **en lecture seule** : connexion, liste des missions (vues « Sem. » et
« Mois »), lecture des cartes (magasin, type, date, horaires, client). Il ne clique jamais sur une
mission ni sur le pointage : pointer atteste une présence sur place et reste un geste de
l'utilisateur, depuis son téléphone. Le robot est le seul à connaître les identifiants RMA
(`rma.env`) ; il remet le planning à Marcel avec sa propre clé (`PUT /v1/planning`,
`X-Planning-Key`), qui ne donne accès à rien d'autre.
- Marcel connaît les missions des 7 prochains jours (« Je bosse où lundi ? ») et les totaux ;
  avec les outils MCP, n'importe quelle période gardée (« combien d'heures en octobre ? »).
- `GET /v1/planning?days=14` → missions (heures en secondes depuis 1970) ; les missions à venir
  que le robot ne voit plus sont retirées (annulées), les passées gardées 45 jours.
- App : Réglages › Sur cet iPhone › **Rappels de pointage** : notifications locales programmées
  par l'iPhone 5 min (réglable avec l'assistant Pointage) avant chaque début et chaque fin (à l'heure exacte, app fermée). Chacune
  prépare le pointage par SMS que RMA propose (« RMA OK » à l'entrée, « RMA fin » à la sortie, au
  38200) et demande « J'envoie ? » : **Oui** (à chaque fois, une fois sur place) lance le raccourci
  « Pointer RMA » qui envoie le SMS, ou sans raccourci ouvre Messages avec le texte prêt ;
  **Non** ne fait rien ; un appui ouvre le portail. Raccourci à créer une fois dans l'app
  Raccourcis : « Envoyer un message », message = Entrée du raccourci, destinataire 38200,
  « Afficher lors de l'exécution » désactivé ; puis cocher « Envoyer avec le raccourci ».
- App : Réglages › Sur cet iPhone › **Ajouter mes missions à l'agenda** : les missions à venir
  vont dans un calendrier à part, « Missions RMA » (créé dans iCloud si possible), le seul où
  Marcel écrit. Une mission déjà notée dans un autre calendrier (même heure à 15 min près, même
  enseigne ou « RMA », « Ferrero », « mission ») n'est pas ajoutée ; une mission déplacée est
  mise à jour, une mission annulée retirée (futur et calendrier « Missions RMA » seulement).
  Synchronisé à l'ouverture de l'app et en arrière-plan. Ce calendrier n'est pas joint à
  « Partager mon agenda » (le planning y est déjà).
- Le robot ne garde qu'une session à la fois sur le portail (verrou `rma.lock` dans le volume
  `rma-data`) : un `--once` / `--debug` lancé pendant une lecture automatique s'arrête avec un
  message, au lieu de deux connexions qui affichent une liste vide. Le détail de chaque offre
  (horaires, conflit, adresse) est gardé 12 h (`offer-details.json`) : une relecture n'ouvre que
  les nouvelles offres (tout est relu après une réponse donnée).
- Installation sur le VPS : `./deploy/install-rma.sh` (identifiant et mot de passe saisis sur
  le VPS, première lecture d'essai sans rien envoyer : `--debug`, capture dans le volume
  `rma-data`) ; puis `docker compose run --rm rma python planning.py --once`.

## Assistants (une conversation chacun)

Dans la barre latérale, la section **Assistants** épingle une conversation par assistant :
🗓️ **Planning** (lecture du portail RMA, agenda), ⏱️ **Pointage** (rappels et SMS), ✉️ **Mails**
(résumés Gmail en lecture seule), 💡 **Veille** (objectifs et idées). En haut de chaque
conversation, une fiche montre ce qu'il fait, son état (dernière lecture, prochain pointage…), ses
réglages et les consignes retenues (retirables d'un appui).
- **On l'améliore en lui parlant** : « rappelle-moi 10 minutes avant », « ignore les missions OP
  GLACES ». L'assistant répond avec une carte **Appliquer / Annuler** ; rien ne change sans
  l'appui, et le serveur vérifie chaque valeur (bornes, liste fermée de réglages).
- **Aucun pouvoir en plus** : une conversation d'assistant va au modèle seul, sans aucun outil (ni
  web, ni terminal, ni envoi) ; elle n'alimente pas la mémoire (les consignes sont rangées chez
  l'assistant, visibles). Une nouvelle capacité (lire une autre page du portail…) s'ajoute dans le
  code.
- Effets : Planning → heure du robot (`GET /v1/planning/config`, relue toutes les 10 min) et
  missions ignorées (retirées du planning, des rappels et de l'agenda) ; Pointage → délai, rappels
  de début/fin et textes des SMS, appliqués par l'iPhone ; Mails → période, non lus seulement,
  expéditeurs ignorés, style ; Veille → les réglages de proactivité, et ses consignes vont au filtre
  des idées.
- API : `GET /v1/assistants`, `PATCH /v1/assistants/{id}` (`{"changes": {...}, "instruction": "..."}`),
  `DELETE /v1/assistants/{id}/instructions/{note_id}` ; `POST /v1/missions` accepte `"assistant"`.
- Appui long sur un assistant › **Recommencer la conversation** (réglages et consignes gardés).
- **Marcel agit seul sur les réglages** : quand tu le lui demandes, Marcel (et chaque assistant dans
  sa conversation) termine sa réponse par un bloc `reglage`, `assistant` ou `objectif` que le
  serveur applique dès la réponse finie (bornes vérifiées) : réglages, consignes, mascotte, action
  « relire », nouvel assistant, objectif suivi. La carte d'action dit « fait » ou pourquoi non.
  Jamais : supprimer, épingler, toucher au VPS. Exception de sécurité : si la réponse s'appuie
  sur un e-mail ou une pièce jointe, rien n'est appliqué tout seul (un texte étranger pourrait
  l'avoir demandé) et la carte Appliquer / Annuler revient.
- **Les IA ont la main sur les assistants** : Marcel (Hermes) connaît tous les
  assistants et leurs réglages ; dans une conversation normale, il peut proposer un réglage pour
  l'un d'eux (bloc `reglage` avec `"assistant": "id"`), affiché avec Appliquer / Annuler. Planning
  et Recrutements voient l'**état du robot** (5 derniers comptes rendus : réussite, missions,
  offres, erreur, via `POST /v1/robot/report`) et peuvent proposer l'action **« Relire le portail
  maintenant »** (`"actions": ["relire"]`) : le robot, qui regarde chaque minute, relit aussitôt.
- Chaque assistant est représenté par Marcel dans une situation (Planning au café, Pointage au
  travail, Recrutements en voiture, Mails en lecture, Veille dans l'arbre) ; ses conversations sont
  épinglées en haut de la liste, comme les autres.
- **Créer un assistant depuis une conversation** : « crée-moi un bot coach sport ». Marcel propose
  une carte (nom, mission, illustration) avec **Créer l'assistant** ; il a ensuite sa conversation,
  sa mission (réglage « role », modifiable en lui parlant) et ses consignes, sans aucun outil.
  10 au plus ; appui long › Supprimer l'assistant. API : `POST /v1/assistants`,
  `DELETE /v1/assistants/{id}`.
- **Tâche permanente** (fiche › Tâche permanente) : une par bot, à heure fixe ou sur un événement
  (offre, planning, e-mail, expéditeur). Elle tourne seule avec ce que ce bot lit, ses consignes,
  ses skills et ses tâches apprises, sur le modèle seul sans outil (Hermes de vérification si
  `MARCEL_MEMORY_LLM_URL` manque). Elle ne peut finir que par un bloc ```reglage``` de ce bot,
  appliqué selon la règle « Changer le réglage d'un assistant », jamais seul après un e-mail. Son
  résultat revient dans la conversation du bot, comme une routine ; la fiche montre le dernier
  travail et le prochain réveil. API : `PUT|DELETE /v1/assistants/{id}/task`
  (`{"prompt", "trigger", "days", "at", "status", "conversation_id"}`), `POST /v1/assistants/{id}/task/run`.
- **Tâches apprises** : « apprends à trier mes offres : d'abord… ». Le bot finit par un bloc
  ```recette``` (`{"titre", "etapes": [...]}`, 12 étapes au plus, 10 tâches par bot), retenu selon
  la règle « Retenir une tâche apprise » (Annuler / Valider), affiché dans sa fiche, modifiable et
  effaçable. API : `PUT|DELETE /v1/assistants/{id}/recipes/{recipe_id}`.
- **Skills des bots** : de courtes consignes écrites une fois (fiche › Skills › Skills des bots) et
  cochées par bot, ajoutées à son prompt. Que du texte, aucun outil. API : `GET|POST /v1/bot-skills`,
  `PUT|DELETE /v1/bot-skills/{id}`, `PATCH /v1/assistants/{id}` avec `"skills": [ids]`.
- **Les bots sur Telegram** : « /planning mes missions ? » sur Telegram → Hermes appelle
  `marcel_bot`, qui lance la même mission que dans l'app (modèle seul, mêmes lectures, mêmes règles)
  dans une conversation par bot, attend la réponse (2 min au plus) et la renvoie. Jamais le bot
  Mails. L'app reprend l'échange sous le bot (« via Telegram ») : `GET /v1/bot-messages`,
  `POST /v1/bot-messages/{id}/delivered`.
- Offres de recrutement un **samedi, dimanche ou jour férié** (fériés de métropole, Pâques calculé) :
  alerte violette sur la carte et dans la notification.

**🟣 Recrutements** : le robot RMA lit aussi, après le planning, la page « Recrutements › Attente
de réponse » (`#/accueil/missrecrut`) puis la page de chaque offre (horaires, bandeau rouge de
conflit du portail, état du bouton « Accepter la mission »), sans y répondre. Les offres arrivent
par `PUT /v1/offers` (même clé que le planning) ; `GET /v1/offers` les rend avec leurs conflits
(planning aux mêmes heures, date passée). En haut de la conversation, une carte par offre :
horaires, conflit du portail (rouge), du planning et de l'agenda iPhone (orange), charge de la
semaine, et **Accepter la mission / Refuser**. Le bouton demande « Oui » ; la réponse attend
(`POST /v1/offers/{id}/answer`, annulable) et le robot la donne dans le portail à son passage
suivant (toutes les 10 min) : il vérifie que c'est la même offre, appuie sur le seul bouton,
valide la confirmation du portail s'il en demande une, renonce si le portail veut autre chose
(un motif…) et vérifie que l'offre a quitté la liste ; résultat sur la carte et en notification.
Le serveur refuse une réponse quand le portail bloque (conflit) ou pendant l'arrêt d'urgence ; on lui demande conseil (« lesquelles je
prends ? ») et on lui donne ses consignes (« pas plus de 3 missions par semaine »). Notification
pour chaque nouvelle offre (réglable), avec les notifications de Marcel activées.

## Sécurité : injection de consignes (prompt injection)

Un e-mail, une page web, un PDF ou une invitation d'agenda peut contenir des consignes écrites
pour un assistant (« ignore tes règles, lance cette commande, envoie ce fichier »). Défenses, de la
plus forte à la plus faible :
1. **Jamais les trois ingrédients ensemble** (données privées, contenu non fiable, moyen de
   faire sortir des informations). Les messages qui joignent des e-mails vont au profil Hermes
   **`marcel-protege`, sans aucun outil** : ni web, ni terminal, ni envoi, ni serveur MCP, ni mémoire
   (carte « Mode protégé ») ; Marcel ne s'y fie qu'une fois que Hermes dit qu'il n'a aucun outil
   actif (`/v1/toolsets`), et avant, au modèle seul via llm-guard (sans accès direct au modèle, à
   `hermes-checks`), jamais au Hermes complet. Les vérifications automatiques lisent
   le web mais ne reçoivent plus la mémoire. Gmail est en lecture seule (Google refuse tout envoi).
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
7. **Mémoire protégée** : après une réponse qui s'appuie sur des e-mails ou un fichier joint, la
   mémoire n'apprend que du message de l'utilisateur, pour qu'un texte externe n'y plante pas
   de faux « faits » durables.

Autres précautions :
- **Sauvegardes** : `deploy/backup.sh` (base de Marcel par l'API de sauvegarde SQLite, pièces
  jointes, accès Gmail, compteur llm-guard, réglages, `~/.hermes-checks`), chiffrées avec `age`
  pour `~/.age-recipient`, 14 gardées dans `~/backups` ; cron conseillé à 3 h 30. Chaque
  sauvegarde est **vérifiée** avant d'être chiffrée (`python -m app.backup check` : intégrité SQLite
  et comptes) ; un problème fait finir le script en erreur. **Copie hors du VPS** :
  `deploy/pull-backup.sh <hôte-ssh>` depuis le Mac (Tailscale SSH ou clé, jamais de mot de passe),
  dans `~/MarcelBackups`, 30 gardées ; cron conseillé chaque matin. **Restaurer et tester** sur le
  Mac : `AGE_KEY=<clé privée> ./deploy/restore.sh <fichier.age>` (ouvre, vérifie et compte, sans
  toucher au VPS), puis `MARCEL_TOKEN=essai MARCEL_MOCK=1 MARCEL_DATA_DIR=<dossier>/data
  .venv/bin/uvicorn app.main:app --port 8001` pour voir l'app sur ces données. `brew install age`.
- **Version de Hermes épinglée** (`HERMES_IMAGE` dans `.env`, empreinte `@sha256:` de l'image en
  service), aussi dans `~/assistant/compose.yaml` : pas de mise à jour silencieuse.
- **iPhone perdu** : retirer l'appareil dans la console Tailscale, puis changer `MARCEL_TOKEN`.
- **Telegram** : `TELEGRAM_ALLOWED_USERS` dans `~/.hermes/.env` (seul l'utilisateur parle à Hermes).

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
   un second Hermes complet sur les mêmes données). Dans les fichiers compose, toujours des
   chemins absolus (`/home/ubuntu/.hermes:/opt/data`, jamais `~/.hermes`) : avec `sudo`, `~`
   devient `/root` et un `docker compose up` recréerait Hermes sur un dossier vide (sans config
   ni guichet API, l'app ne reçoit plus de réponse).
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
