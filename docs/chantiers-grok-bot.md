# Marcel face à Grok Bot : ce qui manque

Grok Bot (xAI, sorti le 11 août 2026, encore en bêta) n'est pas un chat : chaque « bot » est un
agent qui tourne sur un ordinateur dans le cloud, garde ses connexions, apprend des tâches et
travaille quand l'app est fermée. Ce qui suit vient des retours d'utilisateurs (forums, avis,
retours après une semaine), lus en octobre 2026.

## Ce que les utilisateurs aiment

- Des bots toujours allumés, qui avancent l'app fermée et reviennent avec le résultat.
- Un « chef de cabinet » qui fait le brief du lundi et le résumé du jour, et ne remonte que les
  décisions à prendre (oui / non).
- Des routines à heure fixe **et sur événement** (un e-mail qui arrive, un ticket, un webhook).
- Des règles « demande d'abord » écrites en clair : envoyer, publier, supprimer ou acheter attend un
  accord, puis on autorise un travail précis quand on a confiance.
- Des skills partagées entre bots, et « Teach a Task » (on fait la tâche une fois devant le bot).
- Des Pages : des tableaux qui se remettent à jour seuls.
- La voix, et l'app iPhone synchronisée avec l'ordinateur.

## Ce qu'ils reprochent (et où Marcel est déjà mieux)

| Plainte sur Grok Bot | Marcel |
| --- | --- |
| On ne voit ni ne corrige ce que le bot a retenu | Mémoire visible, modifiable, effaçable (Réglages › Mémoire) |
| On ne sait pas quel modèle a travaillé, on ne peut pas choisir | Modèle affiché sous chaque réponse, choisi dans le composeur, « Auto » |
| Factures surprises, quotas vides en milieu de semaine | Jauge de tokens, budgets, plafond de routines par jour |
| Un bot bloqué réessaie trop longtemps avant de demander de l'aide | Une mission qui répète trois fois la même étape ou dépasse 30 min s'arrête : « Marcel a besoin de toi » ; arrêt d'urgence |
| Tous les bots partagent le même ordinateur et les mêmes connexions | Assistants sans outils ; e-mails lus en mode protégé ; coffre du navigateur jamais ouvert |
| Une conversation sans fin qui recharge tout l'historique | Une conversation par sujet, nouvelle conversation en un geste |

## Déjà fait dans l'app

- Menu unique, assistants en modes, commandes « / » (modes, /nouveau, /code, /donnees, /routine,
  /objectif, /web).
- Relances : un assistant revient de lui-même dans sa conversation (une fois ou chaque semaine),
  avec une notification à son nom.
- Cartes de résultat avec « Annuler », ligne d'activité, questions de suite, « écrit… » sous le nom.
- Chantier 1 (en partie) : une routine peut partir « à chaque nouvelle offre » ou « quand le planning
  change » (`"quand": "offre" | "planning"`), sans outil qui agit. Reste : « e-mail d'un expéditeur
  donné » et l'affichage du déclencheur dans l'écran Routines.
- Chantier 2 : suggestion « Fais-moi un brief chaque matin » dans l'accueil de Marcel (routine à
  7 h 30, seulement les décisions en oui / non).
- Chantier 4 : mode vocal mains libres (bouton à la place d'« Envoyer » quand le champ est vide) :
  dictée et voix sur l'iPhone, envoi après un silence, réponse lue, puis le micro se rouvre.
- Chantier 5 : « Je bloque » — trois fois la même étape ou plus de 30 minutes, la mission s'arrête et
  la notification « Marcel a besoin de toi » dit où elle bloque.

## Et les « dots » de ChatGPT (OpenAI, sortis le 29 septembre 2026)

Même idée que Grok Bot : un agent toujours allumé, avec son propre ordinateur dans le cloud. Il
travaille entre deux conversations et revient quand il y a quelque chose à voir. Réservé à ChatGPT
Pro (dès 100 $/mois), pas encore en Europe, réglage depuis l'ordinateur seulement.

| Ce que les gens aiment | Marcel |
| --- | --- |
| Des tâches permanentes : plus besoin de réécrire la même demande chaque semaine | Routines et relances |
| Le résultat est prêt au réveil, lancé la veille au soir | Missions qui tournent l'app fermée |
| Il prévient seul : e-mail urgent, agenda qui change, panne | Offres et planning oui ; e-mails urgents non (**manque**) |
| Règles réglables **action par action** (automatique → demander → rendre la main), qu'on assouplit petit à petit | Règles fixes dans le code (**manque** : réglage par type d'action) |
| Onglet Activité : en cours / programmé / terminé, plus les demandes en attente | Missions, Routines et Idées sont trois écrans séparés (**manque** : une vue unique) |
| On le regarde travailler et on peut prendre la main (mot de passe tapé sans que le modèle le voie) | Pas de vue en direct du navigateur du robot (**manque**, gros chantier) |
| Le même agent sur ChatGPT, Slack, SMS et en appel vocal | App iPhone et Telegram (via Hermes), mode vocal |

| Ce qu'ils reprochent | Marcel |
| --- | --- |
| Silence ambigu : rien d'important, ou il a raté quelque chose ? | **Manque** : le brief devrait dire « rien à signaler » et ce qu'il a regardé |
| A envoyé un e-mail sans demander, alors qu'il avait demandé la première fois | Règles appliquées par le serveur, pas par le modèle : jamais seul si un e-mail est en jeu |
| « Terminé » ne veut pas dire que c'est vraiment fait | **Manque** : vérifier le résultat avant de marquer une mission terminée |
| Coût imprévisible après le mois de lancement | Jauge de tokens et plafonds |
| Lent : deux minutes pour démarrer l'ordinateur cloud | Serveur toujours allumé |

Côté Grok (le chat, pas Grok Bot), les utilisateurs citent aussi deux choses simples :
**le style de réponse** (concis, formel, pédagogue) et **la conversation privée**, ni gardée ni
apprise. Marcel n'a ni l'un ni l'autre (**manque**).

### Ce qui manquait, fait le 25 octobre 2026

1. « Rien à signaler » : une routine le dit en premier quand rien ne bouge, et le serveur ajoute
   lui-même à la fin « Regardé : ton planning, 2 objectifs, … » (ce qu'il avait vraiment sous les yeux).
2. Conversation privée (menu « … » ou `/prive`) : rien gardé sur l'iPhone, aucune mémoire lue ni
   apprise, réponse jamais cherchée plus tard et effacée du serveur 10 minutes après.
3. Style de réponse : Réglages › Réponses (concises, normales, détaillées).
4. Vue Activité (menu « … ») : à voir (bloqué, à vérifier, idées), en cours, programmé, terminé.
5. Vérification avant « terminé » : si la réponse dit « c'est fait » sans qu'aucune action n'ait
   tourné, ou si une étape a été coupée, la mission est marquée « À vérifier » au lieu de « Livrée ».
6. E-mails : une routine peut partir à chaque nouvel e-mail (`"quand": "email"`) ou d'un expéditeur
   (`"email:adresse"`), toujours en mode protégé (modèle seul, sans outil) ; « préviens-moi d'un
   e-mail urgent » ne dérange que si c'est urgent.
7. Règles « demande d'abord » par type d'action (Réglages › Règles) : réglage, assistant, objectif,
   routine, navigateur, chacun « tout seul » ou « demander » (bouton « Valider »). Les limites fixes
   restent : jamais supprimer ni épingler, jamais le coffre, jamais seul avec un e-mail ou un fichier.
8. Voir le robot RMA travailler (Activité › Voir le robot) : son écran toutes les 2 s pendant qu'il
   lit le portail, champs masqués. « Je prends la main » l'écarte du portail jusqu'à ce qu'on la rende.
   **Reste** : piloter son navigateur depuis l'iPhone (toucher, taper), à faire seulement si utile.

### Le reste, fait aussi le 25 octobre 2026

- **Un seul Marcel.** Les bots ne sont plus des assistants à part : c'est toujours Marcel qui
  parle (« Ici Marcel, pour tes offres RMA »), le titre de la conversation reste « Marcel » avec
  le sujet en dessous, et la saisie dit « Demander à Marcel… ». RMA est un de ses sujets, pas tout
  ce qu'il est : les bots RMA s'appellent Planning RMA, Pointage RMA et Offres RMA (ex-Recrutements),
  et l'accueil de Marcel propose d'abord d'organiser la semaine.
- Suggestions d'Offres RMA : seuls les exemples du dernier paragraphe de l'accueil deviennent des
  boutons (plus « Accepter la mission », « Refuser », « Oui »).
- Écran Routines › Quand : à une heure fixe, à chaque nouvelle offre RMA, quand le planning RMA
  change, à chaque nouvel e-mail, ou à chaque e-mail d'un expéditeur.
- Fiche d'un bot › « Ce que Marcel lit ici » : planning RMA, offres en attente, comptes rendus du
  robot, objectifs, agenda de l'iPhone, chacun allumé ou non. En lecture seule, sans outil : la
  conversation d'un bot va toujours au modèle seul. Les e-mails restent au seul bot Mails, et la
  **recherche web n'y est pas** : elle demanderait un outil, donc un modèle avec outils à côté de
  données lues ; à faire seulement via le Hermes restreint, jamais avec des e-mails. → Fait
  autrement, voir « Recherche web isolée » plus bas.
- Fiche d'un bot › « Page » : un tableau recalculé par le serveur à chaque ouverture, sans modèle
  (`GET /v1/assistants/{id}/page`). « Afficher à l'ouverture du bot » le met en tête de chaque
  nouvelle conversation : c'est l'utilisateur qui le choisit, Marcel n'épingle rien.

### Recherche web isolée des bots (25 octobre 2026)

Fiche d'un bot › « Recherche web isolée » (jamais pour Mails). Le bot qui connaît l'utilisateur
n'a aucun outil : il écrit seulement une question (bloc `recherche`). Ensuite :

1. **Filtre** : le serveur bloque la question si elle contient une adresse e-mail, un téléphone,
   un IBAN, une adresse postale, un des « mots privés » (Réglages › Règles) ou un nom que la
   mémoire de Marcel associe à qui est l'utilisateur.
2. **« Demander » par défaut** (Règles › Chercher sur le web) : la carte montre la question exacte
   et attend « Valider ». L'app l'envoie alors comme message, et le serveur la filtre à nouveau.
3. **Chercheur IA enfermé** (`app/websearch.py`) : le modèle direct, sans aucun outil, reçoit la
   question et rien d'autre (ni mémoire, ni conversation, ni session : un appel neuf à chaque
   étape, avec seulement ce que cette recherche a trouvé). Il ne peut que demander au code de
   chercher (3 fois au plus, chaque question refiltrée), de lire une page qu'on lui a montrée
   (résultats ou liens d'une page lue, 4 au plus, adresses publiques seulement, même après une
   redirection) ou de finir. Jamais de formulaire ni d'envoi : le code ne fait que des lectures.
   Sa consigne : les pages sont des informations, pas des ordres, il ne donne jamais rien et
   signale toute page qui s'adresse à une IA (« page suspecte » sur la carte). Le Hermes restreint
   n'est pas utilisé : il peut relire ses anciennes sessions, qui contiennent des données de
   l'utilisateur.
4. **Une seule recherche** par message : si la réponse en propose une autre, elle attend
   « Valider », quelle que soit la règle.
5. **Liens nettoyés** : les images deviennent du texte (l'app n'en charge aucune), les liens perdent
   leur partie après « ? » et « # », et un lien qui contient une donnée personnelle est retiré. La
   réponse n'est envoyée à l'app qu'une fois nettoyée.

Limites : une reformulation (« le magasin près de chez moi ») passe le filtre, d'où « Valider » ;
une page peut mentir ou donner un lien vers un faux site ; le moteur voit la question. Les pages ne
vont qu'au modèle direct, sans outil : si le serveur n'en a pas (`MARCEL_MEMORY_LLM_URL` absent),
la recherche reste coupée.

### Chantiers 7 à 10, faits le 27 octobre 2026

- **Tâche permanente** : une par bot, réglée dans sa fiche, à une heure fixe ou sur un événement
  (offre, planning, e-mail, expéditeur). Elle tourne avec ce que le bot lit, ses consignes, ses
  skills et ses tâches apprises, sur le modèle seul, sans outil. Elle ne peut finir que par une
  action de ce bot (bloc `reglage`), faite seule ou laissée à « Appliquer » selon Réglages › Règles,
  et jamais seule après un e-mail. La fiche montre le dernier travail et le prochain réveil.
- **Tâches apprises** : « apprends à… » → bloc `recette` (titre et étapes), montré sous la réponse
  avec « Annuler » (ou « Valider » selon la règle « Retenir une tâche apprise »), puis dans la fiche,
  où on le modifie ou l'efface. Le bot les refait sur demande ou dans sa tâche permanente.
- **Skills des bots** : des consignes écrites une fois, cochées bot par bot. Que du texte.
- **Telegram** : « /planning … », « /offresrma … » → Hermes appelle `marcel_bot`, qui lance la même
  mission que dans l'app et renvoie la réponse. Une conversation par bot, que l'app reprend sous ce
  bot (« via Telegram »). Le bot Mails reste dans l'app.

Ce qui manque encore : pas de notification sur l'iPhone pour un échange Telegram (l'utilisateur
était sur Telegram), et une tâche permanente ne fait pas de recherche web (elle demanderait
« Valider » à quelqu'un d'absent).

### L'interface de Grok Bot, reprise le 27 octobre 2026

Ce que les guides décrivent de l'interface (docs xAI et Cursor, guides iPhone, articles de fond,
lus en octobre 2026), et ce que Marcel en a pris :

| Grok Bot | Marcel |
| --- | --- |
| Cartes d'accord **Allow once / Always allow / Deny**, avec l'action et ses valeurs | « Autoriser une fois », « Toujours » (passe ce type d'action à « Tout seul » dans Règles), « Refuser » ; même chose sur la carte d'un réglage proposé |
| Profil du bot : interrupteur **Notifications** « quand il a fini ou qu'il t'attend » ; **Open Settings** si l'iPhone les coupe | Fiche › Notifications › « Me prévenir », bouton « Ouvrir Réglages » ; la notification dit « … attend ton accord » quand une carte attend |
| Profil : ses **routines**, chacune avec **Active**, prochain passage, consigne et **Run history** (réussie, en cours, échec et raison) ; balayer pour supprimer ; **Add routine** ouvre un message | Fiche › Relances : interrupteur, « Prochain », consigne, « Historique » ; balayer pour supprimer ; « Ajouter une relance » ouvre sa conversation avec « Relance-moi » |
| Barre latérale : **Pin**, **Hide from sidebar**, **Hidden Bots** avec **Show in sidebar** | Appui long sur un bot : « Épingler » (en tête, avec une punaise), « Masquer du menu » ; section « Bots masqués » |
| Nom du bot en haut du chat → son profil | Déjà là : le nom en haut › « Fiche du bot » |
| **Stop now**, **Take over**, voix | Déjà là : arrêt, « Je prends la main » (robot RMA), mode vocal |

Pas repris : les chats de groupe entre bots (les guides les disent bruyants et sans cartes d'accord),
l'ordinateur dans le cloud par bot, et les modèles de bots partagés en équipe.

Sources : [Work with Grok Bot (Cursor)](https://cursor.com/docs/grok-bot/work),
[Skills and routines (xAI)](https://docs.x.ai/grok-bot/skills-routines-and-automations),
[Grok Bot on iPhone (Learn Cursor)](https://www.learncursor.dev/learn/cursor-agents/grok-bot-ios),
[A deep dive into Grok Bot (Flavio Copes)](https://flaviocopes.com/grok-bot/),
[Grok Bot sur Google Play](https://play.google.com/store/apps/details?id=ai.x.grok.bot&hl=en_US).

## Chantiers que Marcel peut faire lui-même

Chacun se lance en envoyant le message tel quel à Marcel (mode Marcel). Il suit sa skill
`marcel-code` : branche, modification, vérification, pull request, fusion seulement au vert. Pour
un chantier trop gros, il prépare une demande pour Claude Code ou Codex.

### 1. Routines sur événement — fait (déclencheur choisi aussi dans l'écran Routines)

> /code Lis docs/chantiers-grok-bot.md, chantier 1. Ajoute aux routines un déclencheur en plus de
> l'heure : « nouvelle offre RMA », « planning modifié » (lus par le robot RMA) et « e-mail d'un
> expéditeur donné ». Le bloc `routine` accepte `"quand": "offre" | "planning" | "email:adresse"`.
> La routine part au plus une fois par événement, sans outil qui agit, comme les autres (et en mode
> protégé pour les e-mails). Tests dans backend/tests, puis l'écran Routines affiche le déclencheur.

### 2. Brief du matin (chef de cabinet) — fait

> /code Lis docs/chantiers-grok-bot.md, chantier 2. Propose dans l'accueil de Marcel une suggestion
> « Fais-moi un brief chaque matin » qui crée une routine à 7 h 30 : missions du jour, offres
> nouvelles, objectifs qui bougent, e-mails importants (en mode protégé), et seulement les décisions
> à prendre, en oui / non. Le brief arrive dans sa propre conversation avec une notification.

### 3. Assistants qui agissent, avec des règles « demande d'abord » — fait (sans recherche web, voir plus bas)

> /code Lis docs/chantiers-grok-bot.md, chantier 3. Aujourd'hui un assistant n'a aucun outil.
> Ajoute à chaque assistant une liste d'outils en lecture (planning, offres, robot, recherche web),
> réglable dans sa fiche, et des règles « demande d'abord » en clair : tout ce qui envoie, publie,
> achète ou réserve s'arrête et attend « Valider » dans sa conversation. Rien ne supprime ni
> n'épingle. Les e-mails restent lus en mode protégé, sans outil.

### 4. Mode vocal mains libres — fait

> /code Lis docs/chantiers-grok-bot.md, chantier 4. Ajoute un mode vocal dans l'app : un bouton à
> côté du micro ouvre un écran plein avec la mascotte ; la dictée part seule quand l'utilisateur se
> tait, la réponse est lue à voix haute, puis le micro se rouvre. Tout reste sur l'iPhone (dictée et
> voix locales), rien d'autre n'est envoyé que le texte.

### 5. « Je bloque, aide-moi » — fait

> /code Lis docs/chantiers-grok-bot.md, chantier 5. Quand une mission tourne depuis plus de 10
> minutes, ou répète la même étape trois fois, elle s'arrête et envoie une notification : ce qu'elle
> essayait, où elle bloque, et une question simple. La réponse de l'utilisateur la relance.

### 6. Pages qui se mettent à jour — fait (Planning RMA, Pointage RMA, Offres RMA, Veille)

> /code Lis docs/chantiers-grok-bot.md, chantier 6. Un assistant peut épingler dans sa fiche une
> « page » : un petit tableau Markdown (missions de la semaine, offres en attente, objectifs)
> recalculé par le serveur à chaque ouverture, sans modèle. Commence par Planning et Recrutements.

### 7. Un bot qui travaille seul — fait (fiche › Tâche permanente)

> /code Lis docs/chantiers-grok-bot.md, chantier 7. Donne à chaque bot une tâche permanente, réglée
> dans sa fiche (« surveille les offres et prépare ma réponse »), qui part seule sur un événement
> (offre, planning, e-mail) ou à heure fixe, en t'appuyant sur les routines qui ont déjà un
> `assistant`. Le modèle reste sans outil : il propose une action parmi celles du bot (`ACTIONS`),
> et le serveur l'exécute selon Réglages › Règles (« tout seul » ou « Valider »). Le résultat arrive
> dans la conversation du bot avec une notification ; sa fiche montre « Dernier travail » et
> « Prochain réveil ». Toujours en mode protégé avec un e-mail. Tests dans backend/tests.

### 8. « Apprends-moi une tâche » — fait (bloc `recette`, fiche › Tâches apprises)

> /code Lis docs/chantiers-grok-bot.md, chantier 8. Dans la conversation d'un bot, l'utilisateur
> décrit une tâche une fois, étape par étape (ou Marcel la tire d'une conversation réussie). Le
> serveur l'enregistre comme une recette, visible, modifiable et effaçable dans la fiche du bot à
> côté de ses consignes. Le bot la rejoue sur demande ou dans sa tâche permanente (chantier 7) ;
> chaque étape qui agit suit les règles « demande d'abord ». Rien n'est appris sans être montré.

### 9. Des skills partagées entre bots — fait (fiche › Skills › Skills des bots)

> /code Lis docs/chantiers-grok-bot.md, chantier 9. Ajoute une bibliothèque de skills de bot :
> de courtes consignes réutilisables (« ton pour répondre à RMA », « format d'un brief »), créées
> et modifiées dans Réglages, et cochées dans la fiche de chaque bot. Le serveur les ajoute au
> prompt du bot (`bots.prompt`). Ce n'est que du texte : aucune skill ne donne un outil.

### 10. Chaque bot sur Telegram — fait (outil `marcel_bot`, skill `marcel-bots`)

> /code Lis docs/chantiers-grok-bot.md, chantier 10. Sur Telegram, « /planning », « /offres »… ouvrent
> la conversation du bot correspondant, avec les mêmes lectures et les mêmes règles que dans l'app
> (modèle seul, sans outil). Le bot Mails reste dans l'app seulement. La conversation se retrouve
> dans l'app, sous le bot.

## Sources

- [ChatGPT dots (Zapier)](https://zapier.com/blog/chatgpt-dots.md)
- [ChatGPT dots (Lindy)](https://www.lindy.ai/blog/chatgpt-dots)
- [OpenAI Dots Review](https://aiprofitboardroom.com/blog/openai-dots/)
- [Grok AI Reddit: What Users Think](https://www.aitooldiscovery.com/guides/grok-reddit)
- [Grok reviews (G2)](https://www.g2.com/products/grok-4/reviews)

- [What Is Grok Bot? A Paying User's Week-One Review](https://christopheralarcon.com/blog/what-is-grok-bot)
- [Grok Bot Review (2026): Strengths, Limits & Who It's For](https://grok-bots.com/grok-bot-review)
- [7 levels of Grok Bot](https://wrightmode.substack.com/p/7-levels-of-grok-bot-from-your-first)
- [Grok Bot Problems and Limitations: What Users Are Reporting](https://cellcog.ai/blog/grok-bot-problems/)
- [Grok Bot Routines don't wake up at the beginning of a new day](https://forum.cursor.com/t/grok-bot-routines-dont-wake-up-at-the-beginning-of-a-new-day/172545)
- [Grok Bot can now add events, set reminders… (Digital Trends)](https://www.digitaltrends.com/phones/grok-bot-can-now-manage-your-calendar-reminders-and-more/)
