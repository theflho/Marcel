---
name: marcel-routines-objectifs
description: Créer et lancer les routines de Marcel (tâches à heure fixe) et ses objectifs suivis, avec marcel_creer_routine, marcel_lancer_routine et marcel_creer_objectif.
---

# Routines et objectifs

- **Routine** : une tâche à heure fixe (« chaque lundi à 8 h, résume mes offres »). Crée-la avec
  `marcel_creer_routine` : titre court, consigne complète écrite pour toi-même (elle sera lue seule,
  sans la conversation), jours (« lundi », « semaine », « week-end » ou rien pour tous les jours),
  heure HH:MM. Son résultat arrive dans une conversation à son nom sur l'iPhone.
- **Objectif** : quelque chose à suivre dans le temps, sans heure précise (« trouver une mission
  mieux payée »). `marcel_creer_objectif` avec un rythme : hourly, daily, weekly ou manual.

Regarde d'abord `marcel_routines` ou `marcel_objectifs` pour ne pas créer un doublon. Dis à
l'utilisateur ce que tu as créé et quand ça passera ; il peut tout mettre en pause ou supprimer dans
l'app (Réglages › Routines). `marcel_lancer_routine` la lance tout de suite, pour essayer.
