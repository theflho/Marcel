---
name: marcel-code
description: Modifier le code de Marcel lui-même (l'app iPhone en Swift et son serveur FastAPI) et la config de Hermes avec les outils marcel_code_*, ouvrir la pull request, attendre la CI, fusionner, suivre le déploiement automatique et annuler si besoin.
---

# Modifier le code de Marcel

Le dépôt contient l'app iPhone (`Marcel/Marcel/`, Swift 6 / SwiftUI, iOS 18) et le serveur
(`backend/app/`, FastAPI, Python 3.13). Tu travailles dans ta propre copie, jamais directement sur main.

## Étapes

1. `marcel_code_etat` : une pull request de toi est-elle déjà ouverte sur le sujet ? Si oui,
   `marcel_code_reprendre` avec son numéro ; sinon `marcel_code_commencer` avec quelques mots du sujet.
2. Comprends avant de toucher : `marcel_code_chercher` (le nom d'une fonction, d'un texte de l'app),
   puis `marcel_code_lire` sur les passages trouvés. Lis assez autour pour suivre les conventions.
3. Modifie avec `marcel_code_remplacer` (passage exact et unique, recopié sans les numéros de ligne).
   `marcel_code_ecrire` seulement pour un nouveau fichier. Écris comme le code autour : mêmes noms,
   même densité de commentaires, textes de l'app en français.
4. `marcel_code_verifier`, puis `marcel_code_diff` : relis tout le diff comme un relecteur exigeant.
   Corrige et revérifie tant que quelque chose cloche.
5. `marcel_code_proposer` : titre court, description qui dit ce qui change, comment le vérifier et ce
   que tu n'as pas pu vérifier.
6. La CI de GitHub tourne seule sur la pull request : tests du serveur et compilation de l'app iPhone
   (environ 10 minutes pour l'app). `marcel_code_ci` donne le résultat et la fin du journal de ce qui
   a échoué : corrige, repropose, jusqu'au vert.
7. Présente la PR et attends l’accord explicite de l’utilisateur pour cette PR, puis fusionne
   (`marcel_code_fusionner`) quand tout est vert et que le diff est compris ; l’outil refuse
   tant que ce n'est pas vert. Un changement d'app compilé n'arrive sur l'iPhone qu'une fois
   réinstallé depuis Xcode : dis-le à l'utilisateur.
8. Après une fusion, le VPS se met à jour seul en quelques minutes et revient en arrière si le serveur
   ne répond plus. Regarde `marcel_code_etat` un peu plus tard et dis le résultat ; en cas de retour
   arrière, `marcel_journaux` montre la fin du journal du build et du serveur.
9. Une fusion qui pose problème même déployée : `marcel_code_annuler` avec son numéro.

## Config de Hermes

Pour changer comment Hermes tourne (un serveur MCP, un réglage d'agent…), modifie
`backend/deploy/hermes-overrides.yaml` comme le reste du code. Après la fusion, il est fusionné dans
`~/.hermes/config.yaml`, Hermes redémarre, et l'ancienne config revient s'il ne répond plus. Le modèle,
les fournisseurs, la passerelle et les secrets restent à l'utilisateur (refusés).

## Journaux

`marcel_journaux` (niveau, recherche) : les dernières lignes du serveur, secrets masqués. À lire avant
de deviner la cause d'une panne.

## Limites

- Fichiers protégés (secrets, `.github/`, `deploy/auto-update.sh`, `app/code_tools.py`,
  `app/llm_guard.py`, `app/mcp.py`, `app/server_log.py`, `app/hermes_config.py`,
  `tests/test_server.py`) : refusés, seul l'utilisateur les modifie.
- Dans `app/main.py`, les passages entre `# garde-fou : …` et `# fin garde-fou : …` restent tels
  quels, et ce qu'ils définissent ne se redéfinit pas ailleurs : l'outil refuse.
- Ne retire jamais un garde-fou : le mode protégé des e-mails et fichiers, l'arrêt d'urgence, le
  blocage de `browser_vault`, le refus de supprimer ou d'épingler, les budgets de llm-guard.
- Jamais de clé, de mot de passe ou de jeton dans le code.
- Ne touche pas à la mascotte de Marcel.
- Un gros chantier se fait quand même, par toi : découpe-le en étapes et en plusieurs pull requests
  (chacune vérifiée, approuvée explicitement puis fusionnée au vert), et dis à chaque fois où tu en es. Tes consignes disent si
  l'utilisateur préfère Claude Code ou Codex (Réglages › Code de l’app) ; sinon, ne les propose que
  s'il les demande lui-même (bloc ```demande-code dans ta réponse).
