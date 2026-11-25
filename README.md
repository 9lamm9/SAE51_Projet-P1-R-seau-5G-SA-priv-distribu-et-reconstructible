# SAE 51 P1 – Réseau 5G SA privé distribué et reconstructible


### Membres


- Lounes
- Ethan
- Alexis
- Mohamed
- Chaima

### Répartition des rôles


| Lot     | Responsabilité                                         |
| ------- | ------------------------------------------------------ |
| Lounes  | Architecture, adressage et justification des choix     |
| Alexis  | Automatisation du déploiement du cœur                  |
| Ethan   | Automatisation du gNB, des UE et du réseau de données  |
| Mohamed | Recette automatisée et tests                           |
| Chaima  | Phénomène lié à la distribution, métrologie et analyse |

### Présentation et contraintes du projet


Ce projet à pour but de réaliser une architecture 5G distribuée avec déploiement et recette automatisés. Il sera entièrement logiciel car toute émission d'onde radio est interdite.
Pour la présentation complète avec les objectifs les invariants et les jalons voir le [cahier des charges](P1_cahier_des_charges.pdf).

---

### Architecture (lot L1)

| Hôte | Rôle | Administration (VLAN 10) | Interfaces 5G |
| ---- | ---- | ------------------------ | ------------- |
| srv-ctrl | Automatisation, recette, mesures | 192.168.10.10 | — |
| srv-core | Cœur Open5GS complet (AMF, SMF, UPF, NRF, SCP, AUSF, UDM, UDR, PCF, NSSF, BSF) + MongoDB | 192.168.10.20 | N2/N3 10.20.0.10 (VLAN 20), N6 10.30.0.10 (VLAN 30) |
| srv-ue | gNB + UE UERANSIM | 192.168.10.30 | N2/N3 10.20.0.20 (VLAN 20) |
| srv-dest | Réseau de données (nginx, iperf3) | 192.168.10.40 | N6 10.30.0.20 (VLAN 30) |

Pool d'adresses UE : 10.45.0.0/16 (passerelle `ogstun` 10.45.0.1). Une fonction réseau = un conteneur, pour pouvoir localiser la fonction en panne.

- Architecture, alternatives comparées et justification : [architecture/architecture.md](architecture/architecture.md)
- Plan d'adressage, flux et paramètres à faire concorder : [architecture/plan-adressage.md](architecture/plan-adressage.md)
- Paramètres pour l'automatisation : [architecture/parametres.yml](architecture/parametres.yml)
- Chemin d'un accès et d'un paquet, diagnostic par fonction : [architecture/chemin-et-diagnostic.md](architecture/chemin-et-diagnostic.md) et [architecture/diag/diag-chemin.sh](architecture/diag/diag-chemin.sh)

### Déploiement (un script par VM)

Monter les VM depuis zéro : voir [deploy/README.md](deploy/README.md). En résumé, sur chaque VM : `git clone` de ce dépôt puis `sudo bash deploy/srv-<nom>.sh` (ordre : srv-dest, srv-core, srv-ue). Depuis srv-ctrl, une seule commande reconstruit tout et lance la recette : `bash deploy/deploy-all.sh`.
