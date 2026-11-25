# Déploiement automatisé – un script par VM

Chaque VM se monte **depuis un système vierge** avec un seul script, et chaque script est **idempotent** : le relancer ne change rien si tout est déjà en place (compteur de changements = 0, indicateur E2).

Adressage et choix d'architecture : [`../architecture/`](../architecture/README.md). Les valeurs utilisées par les scripts sont dans [`commun.sh`](commun.sh) et reprennent [`../architecture/parametres.yml`](../architecture/parametres.yml).

| Script | VM | Ce qu'il installe |
|--------|----|-------------------|
| [`srv-ctrl.sh`](srv-ctrl.sh) | srv-ctrl | Adresse admin, outils, clé SSH, clés K/OPc de l'abonné (hors Git) |
| [`srv-core.sh`](srv-core.sh) | srv-core | Réseau (VLAN 10/20/30, `ogstun`), `ip_forward`, SCTP, Docker, cœur Open5GS 2.7.7 (**un conteneur par fonction**), MongoDB, WebUI, abonné |
| [`srv-ue.sh`](srv-ue.sh) | srv-ue | Réseau (VLAN 10/20), SCTP, Docker, gNB + UE UERANSIM 3.2.6, MTU `uesimtun0` |
| [`srv-dest.sh`](srv-dest.sh) | srv-dest | Réseau (VLAN 10/30), route retour vers les UE, Docker, nginx + iperf3 |
| [`deploy-all.sh`](deploy-all.sh) | lancé depuis srv-ctrl | Reconstruction complète en une commande, puis recette, avec mesures dans `resultats/` |
| [`commun.sh`](commun.sh) | — | Fonctions communes (réseau persistant, Docker, cache d'images, secrets, compteur) |

## 1. Créer les 4 VM

Système : **Debian 12** (netinst, avec « serveur SSH » et « utilitaires usuels », sans environnement graphique). Ubuntu 22.04/24.04 fonctionne aussi. Créer un utilisateur avec `sudo`.

| VM | vCPU | RAM | Disque | Carte 1 | Carte 2 | Carte 3 | Carte 4 |
|----|:----:|:---:|:------:|---------|---------|---------|---------|
| srv-ctrl | 1 | 1 Go | 10 Go | NAT (Internet) | `sae51-vlan10` | — | — |
| srv-core | 2 | 4 Go | 20 Go | NAT (Internet) | `sae51-vlan10` | `sae51-vlan20` | `sae51-vlan30` |
| srv-ue | 1 | 2 Go | 10 Go | NAT (Internet) | `sae51-vlan10` | `sae51-vlan20` | — |
| srv-dest | 1 | 1 Go | 10 Go | NAT (Internet) | `sae51-vlan10` | `sae51-vlan30` | — |

- **VirtualBox** : carte 1 en « NAT », cartes suivantes en « Réseau interne » avec les noms `sae51-vlan10`, `sae51-vlan20`, `sae51-vlan30`.
- **VMware** : carte 1 en NAT, cartes suivantes sur des « LAN Segments » portant ces noms.
- **Proxmox** : carte 1 sur le pont qui donne Internet, cartes suivantes sur un pont dédié avec le tag VLAN 10, 20 ou 30.

### Comment le script choisit les cartes

La carte qui porte la route par défaut (Internet) **n'est jamais modifiée**. Les autres cartes sont prises dans l'ordre (tri naturel : `enp0s8`, `enp0s9`, `enp0s10`…) pour l'administration, puis N2/N3, puis N6. Le choix est mémorisé dans `/etc/sae51/interfaces.env`.

Cas particuliers (variables à passer devant le script) :

| Situation | Variable |
|-----------|----------|
| Imposer les cartes | `sudo IF_MGMT=ens19 IF_N2N3=ens20 IF_N6=ens21 bash deploy/srv-core.sh` |
| Une seule carte en trunk 802.1Q (VLAN taggés) | `sudo VLAN_TRUNK=ens19 bash deploy/srv-core.sh` |
| Une seule carte pour tout (réseau à plat, maquette) | `sudo SINGLE_NIC=1 bash deploy/srv-core.sh` |
| Refaire le choix des cartes | `sudo IF_REDETECT=1 bash deploy/…` |

## 2. Lancer les scripts

### Option A : à la main sur chaque VM (le plus simple pour commencer)

Sur **chaque** VM :

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/9lamm9/SAE51_Projet-P1-R-seau-5G-SA-priv-distribu-et-reconstructible.git sae51
cd sae51
```

Puis, **dans cet ordre** :

```bash
sudo bash deploy/srv-dest.sh     # sur srv-dest
sudo bash deploy/srv-core.sh     # sur srv-core : génère les clés de l'abonné dans /etc/sae51/secrets.env
sudo cat /etc/sae51/secrets.env  # sur srv-core : afficher UE_K et UE_OPC
sudo bash deploy/srv-ue.sh       # sur srv-ue : le script demande UE_K puis UE_OPC, à recopier
```

Le script de srv-ue se termine par un ping de l'UE vers le serveur DN à travers le tunnel. Pour un diagnostic complet, lancer depuis srv-ctrl : `bash architecture/diag/diag-chemin.sh`.

### Option B : tout depuis srv-ctrl (c'est la méthode exigée pour la démonstration)

```bash
sudo bash deploy/srv-ctrl.sh           # une fois : outils, clé SSH, clés K/OPc dans ~/.sae51/secrets.env
bash deploy/deploy-all.sh --keys       # une fois : copie de la clé SSH sur les 3 VM
bash deploy/deploy-all.sh              # reconstruction complète + recette, en une seule commande
```

`deploy-all.sh` pousse le code et les clés sur chaque VM, lance les scripts dans l'ordre srv-dest → srv-core → srv-ue, puis exécute la recette de chemin. Il ajoute une ligne à `resultats/reconstructions.csv` : durée par VM, nombre de changements, durée totale, code de la recette et succès. Ce sont les données des expériences E1 (reconstruction) et E2 (second passage). Au tout premier passage, `sudo` peut demander le mot de passe une fois par VM. Le script configure ensuite `sudo` sans mot de passe pour cet utilisateur, afin que les passages suivants se fassent sans intervention (désactivable avec `NO_SUDOERS=1`).

## 3. Mode hors ligne (soutenance : aucun téléchargement)

Quand Internet est disponible, lancer une fois `bash deploy/deploy-all.sh --save-cache`, ou `sudo bash deploy/srv-XXX.sh --save-cache` sur chaque VM. Les images Docker sont sauvegardées dans `/var/cache/sae51/images/*.tar`. Lors d'une reconstruction, les scripts chargent les images depuis ce cache avant d'essayer Internet. Pour des VM réinstallées à neuf, il faut aussi préparer un cache des paquets Docker (`.deb`) ; c'est un point à compléter pour l'état initial du J3.

## 4. Ce que les scripts garantissent

- **Rien d'écrit en double** : un fichier n'est réécrit que si son contenu change, et les conteneurs ne sont recréés que si leur configuration a changé.
- **Réseau persistant** : l'adressage est appliqué par le service `sae51-net` au démarrage, avant Docker. Le fichier `/usr/local/sbin/sae51-net` montre exactement ce qui est appliqué.
- **Aucun secret dans Git** : les clés K/OPc sont dans `/etc/sae51/secrets.env` (mode 600) et `~/.sae51/secrets.env`.
- **Versions tracées** : `/var/log/sae51/versions.txt` contient le digest exact de chaque image utilisée (à reporter dans `manifest.yml` pour iperf3), et `/var/log/sae51/executions.csv` l'historique des passages.
- Docker est configuré avec `"iptables": false` : tous les conteneurs sont en `network_mode: host`. Sinon Docker passe la chaîne FORWARD en DROP, et l'UE s'attache mais aucun paquet ne traverse l'UPF.

## 5. En cas de problème

Commencer par `bash architecture/diag/diag-chemin.sh` depuis srv-ctrl. Le script indique la première étape et la fonction en échec, et `architecture/chemin-et-diagnostic.md` donne les causes et les corrections. Journaux d'une fonction : `sudo docker logs open5gs-amf` (ou `-smf`, `-upf`…, `ueransim-gnb`, `ueransim-ue`).
