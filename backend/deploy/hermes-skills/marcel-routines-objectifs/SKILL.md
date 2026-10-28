---
name: marcel-routines-objectifs
description: Les tâches récurrentes (cron de Hermes à heure fixe, routines de Marcel sur un e-mail ou un événement) et les objectifs suivis, avec cronjob, marcel_creer_routine, marcel_lancer_routine et marcel_creer_objectif, en suivant les règles de l'utilisateur.
---

# Tâches récurrentes et objectifs

- **Tâche à heure fixe** (« chaque lundi à 8 h, résume mes offres », « dans deux heures,
  rappelle-moi ») : une tâche cron de Hermes (outil `cronjob`), comme sur Telegram. Sa consigne
  est complète, écrite pour toi-même : elle sera lue seule, sans la conversation. Son résultat arrive
  tout seul dans l'app, dans la conversation « Hermes » du bot dont c'est le profil, avec une
  notification (plateforme `marcel`) : laisse la livraison par défaut (`origin`) ou mets
  `deliver: marcel`, jamais `local` (rien n'arriverait). Vérifie d'abord ta règle « routine »
  (`marcel_regles`) : la même que pour une routine (voir plus bas).
- **Routine Marcel** : sur un événement, pas à heure fixe. `marcel_creer_routine` avec `quand`, qui la lance sur un événement : « offre » (nouvelle offre RMA),
  « planning » (planning modifié), « email » (nouvel e-mail) ou « email:expéditeur »
  (« email:rh@exemple.fr »), ou « boite » / « boite:expéditeur » pour un e-mail reçu dans ta
  propre boîte (regardée chaque minute) : c'est le bon déclencheur pour une alerte d'un site dont le
  compte est à ton adresse (« boite:ticketmaster »). La consigne répond « Rien à signaler. » quand
  l'e-mail ne compte pas ; sinon elle donne l'essentiel et le lien. Elle ne fait que prévenir :
  acheter se fait ensuite dans la conversation, après son « Vas-y ».
- **Objectif** : quelque chose à suivre dans le temps, sans heure précise (« trouver une mission
  mieux payée »). `marcel_creer_objectif` avec un rythme : hourly, daily, weekly ou manual.

Regarde d'abord les tâches cron (`cronjob` list), `marcel_routines` ou `marcel_objectifs` pour ne
pas créer un doublon. Dis à
l'utilisateur ce que tu as créé et quand ça passera ; il peut tout mettre en pause ou supprimer dans
l'app (Réglages › Routines), et une tâche cron en te le demandant. `marcel_lancer_routine` lance une
routine tout de suite, pour essayer ; une tâche cron, `cronjob` run.

## Les règles de l'utilisateur

Réglages › Règles décide, type par type : « Tout seul » (tu crées), « Demander » ou « Bloqué ».
La règle « routine » vaut aussi pour une tâche cron : sous « Demander », décris-la et attends son
« oui » dans la conversation avant de la créer ; sous « Bloqué », ne la crée pas.
Sous « Demander », l'outil refuse et te dit de proposer : termine ta réponse par le bloc
`routine` ou `objectif` qu'il décrit, l'utilisateur le validera. Sous « Bloqué », ne crée rien et ne
propose rien : dis-lui qu'il peut changer la règle. N'essaie jamais de contourner une règle (autre
outil, terminal, fichier).
