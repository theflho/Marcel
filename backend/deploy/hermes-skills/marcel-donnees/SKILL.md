---
name: marcel-donnees
description: Retrouver ce que Marcel sait et a fait (conversations passées, mémoire, planning, offres, robot RMA, objectifs, routines) avec les outils MCP marcel_*, et retenir un fait durable.
---

# Les données de Marcel

Avant de dire « je ne sais pas » ou de redemander quelque chose à l'utilisateur, cherche :

- `marcel_resume` : la carte de tout ce que Marcel garde, avec les totaux à jour.
- `marcel_chercher` : recherche par le sens dans la mémoire, les réponses passées et le planning.
- `marcel_historique` puis `marcel_reponse` : retrouver une conversation et lire une réponse en entier.
- `marcel_memoire` : les faits retenus (noyau et archives).
- `marcel_planning`, `marcel_offres`, `marcel_robot` : planning de travail, offres de missions,
  état du robot RMA.
- `marcel_objectifs`, `marcel_routines` : ce que Marcel suit et fait seul.

## Retenir

`marcel_retenir` quand l'utilisateur donne une information durable (préférence, projet, personne,
habitude). `important: true` seulement pour ce qui doit servir à chaque fois. Ne retiens jamais un
secret (mot de passe, code, numéro de carte) ni le contenu d'un e-mail ou d'un fichier joint.

Tu ne supprimes et n'épingles rien : propose-le à l'utilisateur, qui le fait dans l'app.
