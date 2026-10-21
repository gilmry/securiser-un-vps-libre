# Sécuriser un petit serveur sans budget

Une stratégie de sécurisation en couches pour un VPS Linux qui héberge des
applications en conteneurs, avec uniquement des outils libres et gratuits.
Elle est tirée de l'exploitation réelle d'un serveur en 2026.

L'idée en une phrase : plusieurs capteurs, un seul moteur de décision, deux
points de blocage, et une supervision qui surveille la chaîne plutôt que le
bruit.

## Contenu

| Fichier | Pour quoi faire |
|---|---|
| `article.txt` | Lire la stratégie et les pièges, avec un rappel de CyFun |
| `RECETTE.txt` | La mettre en place pas à pas, avec vérification et retour arrière |
| `METHODE-EXCLUSIONS-AIDE.txt` | Rendre AIDE lisible sans se créer d'angle mort |
| `scripts/` | Métriques AIDE et Suricata, test d'écart Suricata / CrowdSec |
| `deploiement/` | Déployer une configuration versionnée par copie, détecter la dérive |
| `config/` | Exemples : règles d'alerte Prometheus, CrowdSec, cron des scans |

Commencez par `article.txt`, puis l'étape 0 de `RECETTE.txt` : elle dit en
dix minutes si vous avez le même trou que nous.

## Avertissements

- Ces fichiers sont des **exemples à adapter**, pas un produit. Lisez chaque
  script avant de le lancer, testez sur une machine qui n'est pas en
  production, et gardez un accès de secours (console de l'hébergeur) avant de
  toucher au pare-feu ou à SSH.
- Testé sur Ubuntu avec Docker. Les chemins peuvent différer ailleurs.
- Aucune exclusion de périmètre réelle n'est publiée ici, volontairement :
  elles diraient à un attaquant où ne pas regarder. Le dépôt donne la méthode.

## Licence

MIT, voir `LICENSE`. Auteur : Gilles Maury, dans le cadre de la Méthode Maury
(logiciel sobre, durable et transmissible).
