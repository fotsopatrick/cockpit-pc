# Cockpit PC

Un cockpit local de surveillance pour **n'importe quel poste Windows**.
Lancez-le, il lit la machine où il tourne et affiche un tableau de bord
style cockpit : services, connexions réseau, ports, processus, erreurs,
journal en direct avec recherche.

> Conçu pour répondre à une question simple : « est-ce que quelque chose
> cloche sur cette machine ? » — un terminal qui s'ouvre et se ferme tout
> seul, une connexion qui part souvent, un service qui change.

## Lancer

Double-clic sur `lanceur.cmd` (ou `lanceur.cmd` depuis un terminal).
Ouvre ensuite le navigateur sur `http://127.0.0.1:8219/`.

## Ce qu'il montre

- **Vue d'ensemble** : CPU, RAM, disques, nouveaux services depuis une date,
  logiciels installés récemment, erreurs système 24 h, processus les plus
  actifs, connexions sortantes et entrantes fréquentes.
- **Réseau** : connexions établies vers l'extérieur, connexions entrantes
  vers la machine, ports en écoute.
- **Services & tâches** : services Windows (état, démarrage, date
  d'installation, chemin), tâches planifiées avec leur commande.
- **Système** : démarrage automatique, identité de la machine, disques.
- **Journal** : chaque nouvelle connexion (entrante ou sortante) et chaque
  nouvelle fenêtre de terminal est consignée avec l'heure, et on peut
  rechercher dedans.

## Architecture

- `serveur.ps1` : collecte les données de la machine et les sert en JSON
  sur `http://127.0.0.1:8219/`. Rien n'est envoyé à l'extérieur.
- `interface/` : page web (HTML/CSS/JS) style cockpit, rafraîchie toutes
  les 6 secondes.
- `logs/` : historique local (connexions, fenêtres, changements de
  services). **Ignoré par git** — contient des données de la machine.
- `lanceur.cmd` / `arreter.cmd` : démarrage et arrêt du serveur.

## Portabilité

Tout est en PowerShell + HTML/JS natifs : aucune installation requise,
fonctionne sur n'importe quel Windows avec PowerShell 5.1+. Copiez le
dossier sur une autre machine et relancez : il lit la machine où il tourne.

## Prérequis

Windows (PowerShell 5.1+), navigateur web. Aucun autre logiciel.
