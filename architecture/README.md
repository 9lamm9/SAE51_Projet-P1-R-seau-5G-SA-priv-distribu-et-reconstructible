# Lot L1 – Architecture, adressage et justification des choix

Référent : **Lounes**

| Fichier | Contenu | Objectif du cahier des charges |
|---------|---------|-------------------------------|
| [`architecture.md`](architecture.md) | Répartition des fonctions sur les hôtes, comparaison avec 3 alternatives sur des critères explicites, justification des choix techniques, risques | O1, J1 |
| [`plan-adressage.md`](plan-adressage.md) | VLAN, adresses, SBI, matrice des flux, pare-feu, routage, paramètres qui doivent concorder entre UE, gNB et cœur, gestion des secrets | O1, O2 |
| [`parametres.yml`](parametres.yml) | Source unique de vérité (lisible par l'automatisation des lots L2/L3) | O2 |
| [`chemin-et-diagnostic.md`](chemin-et-diagnostic.md) | Chemin complet d'une procédure et d'un paquet, diagnostic étape par étape (une fonction = un conteneur), incidents possibles pour E4 | O3, O6, défense individuelle |
| [`diag/diag-chemin.sh`](diag/diag-chemin.sh) | Script qui teste le chemin dans l'ordre et indique quelle fonction échoue (code de sortie = étape) | O3, O6, E4 |
| [`journal-lounes.md`](journal-lounes.md) | Journal détaillé du travail réalisé sur le lot L1 | Traçabilité, fiche de contributions |

Schéma d'ensemble : [`../schéma.txt`](../schéma.txt) et [`../schéma-explicatif.png`](../schéma-explicatif.png).
