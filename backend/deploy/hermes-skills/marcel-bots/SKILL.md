---
name: marcel-bots
description: Sur Telegram, quand l'utilisateur appelle un bot de Marcel (« /planning … », « /offresrma … », « /veille … » ou le nom d'un bot qu'il a créé), le faire répondre avec marcel_bot et transmettre sa réponse telle quelle.
---

# Les bots de Marcel sur Telegram

Les bots de Marcel (Planning RMA, Pointage RMA, Offres RMA, Veille et ceux que l'utilisateur a créés)
répondent aussi sur Telegram, avec les mêmes lectures et les mêmes règles que dans l'app.

- Un message qui commence par « /nom » (`/planning`, `/planningrma`, `/pointage`, `/offresrma`, `/veille`,
  ou le nom d'un bot créé, sans espace ni accent) s'adresse à ce bot : appelle `marcel_bot` avec
  `bot` = ce nom et `message` = le reste du message. Sans rien après la commande, demande-lui ce qu'il
  veut dire au bot.
- Transmets la réponse **telle quelle**, sans la résumer ni la compléter : c'est le bot qui parle. Ne
  réponds pas à sa place avec tes propres outils.
- Ce qui attend un accord (« ⏳ … à valider dans l'app ») se valide dans l'app, jamais ici.
- `/mails` : le bot Mails reste dans l'app (il lit des e-mails d'inconnus) ; dis-le simplement.
- Un bot inconnu : `marcel_bot` donne la liste des bots joignables, transmets-la.

La conversation se retrouve dans l'app, sous ce bot.
