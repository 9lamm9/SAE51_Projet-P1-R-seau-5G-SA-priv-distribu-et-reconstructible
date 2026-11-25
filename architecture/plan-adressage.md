# Plan d'adressage, matrice des flux et paramètres de concordance (lot L1)

> Référent : **Lounes**. Les valeurs machine sont dans [`parametres.yml`](parametres.yml) : ce document les explique. En cas de divergence, c'est `parametres.yml` qui fait foi.

## 1. VLAN et sous-réseaux

| VLAN | Nom | Préfixe | Passerelle | Usage | Trafic 5G ? |
|:----:|-----|---------|------------|-------|:-----------:|
| 10 | `mgmt` | 192.168.10.0/24 | — (L2 seul, ou routeur du département) | SSH de l'automatisation, recette, collecte des mesures | Non |
| 20 | `ran-core` | 10.20.0.0/24 | — (lien direct) | N2 (NGAP/SCTP) + N3 (GTP-U) | Oui |
| 30 | `n6` | 10.30.0.0/24 | — (lien direct) | N6 (IP utilisateur décapsulée) | Oui |
| — | Pool UE | 10.45.0.0/16 | 10.45.0.1 (`ogstun`, srv-core) | Adresses attribuées aux UE (DNN `internet`) | Oui (dans le tunnel) |
| — | SBI | 127.0.0.0/8 | — | Interfaces de service internes au cœur (HTTP/2) | Signalisation interne |

Les plages 10.20/10.30/10.45 ne recouvrent ni le réseau de l'IUT ni les réseaux Docker par défaut (172.17.0.0/16).

## 2. Adresses des hôtes

| Hôte | eth0 (VLAN 10) | eth1 | eth2 | Rôle |
|------|----------------|------|------|------|
| `srv-ctrl` | 192.168.10.10 | — | — | Automatisation, recette |
| `srv-core` | 192.168.10.20 | 10.20.0.10 (VLAN 20) | 10.30.0.10 (VLAN 30) | Cœur Open5GS |
| `srv-ue` | 192.168.10.30 | 10.20.0.20 (VLAN 20) | — | gNB + UE |
| `srv-dest` | 192.168.10.40 | 10.30.0.20 (VLAN 30) | — | Serveur DN |

Convention : le dernier octet de l'adresse d'administration (`.10/.20/.30/.40`) identifie l'hôte. Sur les VLAN de service, `.10` = côté cœur, `.20` = côté extrémité.

## 3. Adresses internes du cœur (SBI, sur srv-core)

Tous les NF sont en `network_mode: host` sur srv-core. On conserve donc les adresses de boucle locale **par défaut d'Open5GS**, ce qui évite de modifier les fichiers de configuration fournis par le projet amont.

| NF | Adresse SBI (port 7777) | Autres écoutes |
|----|-------------------------|----------------|
| NRF | 127.0.0.10 | — |
| SCP | 127.0.0.200 | — |
| AMF | 127.0.0.5 | **NGAP 10.20.0.10:38412/SCTP** |
| SMF | 127.0.0.4 | PFCP 127.0.0.4:8805/UDP |
| UPF | — (pas de SBI) | **GTP-U 10.20.0.10:2152/UDP**, PFCP 127.0.0.7:8805/UDP |
| AUSF | 127.0.0.11 | — |
| UDM | 127.0.0.12 | — |
| PCF | 127.0.0.13 | — |
| NSSF | 127.0.0.14 | — |
| BSF | 127.0.0.15 | — |
| UDR | 127.0.0.20 | — |
| MongoDB | 127.0.0.1:27017 | — |
| WebUI | 0.0.0.0:9999 (n'exposer que sur le VLAN 10) | — |

Les **seules modifications d'adresses** par rapport aux fichiers par défaut d'Open5GS sont :

- `amf.yaml` → `amf.ngap.server[0].address: 10.20.0.10`
- `upf.yaml` → `upf.gtpu.server[0].address: 10.20.0.10`
- `smf.yaml` → `smf.session[0].subnet: 10.45.0.0/16`, `gateway: 10.45.0.1` (et DNN `internet`)
- `upf.yaml` → `upf.session[0].subnet: 10.45.0.0/16`, `gateway: 10.45.0.1`

## 4. Matrice des flux

| # | Interface | Source → Destination | Protocole / port | VLAN | Doit traverser le réseau ? |
|---|-----------|----------------------|------------------|:----:|:--------------------------:|
| F1 | N2 | gNB 10.20.0.20 → AMF 10.20.0.10 | SCTP 38412 (PPID 60, NGAP) | 20 | **Oui** (invariant) |
| F2 | N3 | gNB 10.20.0.20 ↔ UPF 10.20.0.10 | UDP 2152 (GTP-U) | 20 | **Oui** (invariant) |
| F3 | N4 | SMF 127.0.0.4 ↔ UPF 127.0.0.7 | UDP 8805 (PFCP) | local | Non (option A) |
| F4 | SBI | NF ↔ NRF/SCP 127.0.0.x | TCP 7777 (HTTP/2 h2c) | local | Non |
| F5 | N6 | UPF/ogstun 10.30.0.10 ↔ DN 10.30.0.20 | IP (paquets UE 10.45.x.x) | 30 | **Oui** (DN distinct) |
| F6 | Radio simulée | UE ↔ gNB 127.0.0.1 | UDP 4997 | local | Non (simulation) |
| F7 | Service DN | UE 10.45.x.x → 10.30.0.20 | TCP 80 (HTTP), TCP/UDP 5201 (iperf3) | dans N3 puis N6 | — |
| F8 | Admin | srv-ctrl → tous | TCP 22 (SSH) | 10 | — |
| F9 | Base | NF → MongoDB 127.0.0.1 | TCP 27017 | local | Non |

### Pare-feu minimal à ouvrir (si `nftables` est actif)

| Hôte | Entrant à autoriser |
|------|---------------------|
| srv-core | SCTP 38412 et UDP 2152 depuis 10.20.0.20 ; transfert IP 10.45.0.0/16 ↔ 10.30.0.0/24 ; TCP 22 et 9999 depuis 192.168.10.10 |
| srv-ue | UDP 2152 depuis 10.20.0.10 ; TCP 22 depuis 192.168.10.10 |
| srv-dest | TCP 80, TCP/UDP 5201 depuis 10.45.0.0/16 ; TCP 22 depuis 192.168.10.10 |

## 5. Routage et réglages système

| Hôte | Réglage | Pourquoi |
|------|---------|----------|
| srv-core | `net.ipv4.ip_forward=1` | L'UPF transfère entre `ogstun` (10.45.0.1) et `eth2` (N6) |
| srv-core | `modprobe sctp` | N2 utilise SCTP |
| srv-core | Pas de NAT sur `eth2` | Le DN doit voir l'adresse réelle de l'UE |
| srv-dest | `ip route add 10.45.0.0/16 via 10.30.0.10` | Route retour vers les UE (sinon les réponses partent vers la passerelle par défaut) |
| srv-ue | `modprobe sctp` | Le gNB ouvre l'association SCTP |
| srv-ue | Le trafic de test sort par `uesimtun0` (`ping -I uesimtun0`, `curl --interface uesimtun0`, `iperf3 -B <ip UE>`) | Sans cela, le trafic utiliserait la route par défaut et contournerait le réseau 5G |

## 6. Réserve pour l'option B (UPF déporté, extension facultative)

| Élément | Valeur réservée |
|---------|-----------------|
| Hôte `srv-upf` | admin 192.168.10.50, N3 10.20.0.30 (VLAN 20), N6 10.30.0.30 (VLAN 30) |
| N4 sur le réseau | nouveau VLAN 40 `n4` 10.40.0.0/24 : SMF 10.40.0.10 ↔ UPF 10.40.0.30, UDP 8805 |

## 7. Paramètres qui doivent concorder (UE ↔ gNB ↔ cœur)

| Paramètre | Valeur | gnb.yaml | ue.yaml | amf.yaml | smf.yaml / upf.yaml | nrf.yaml | Base d'abonnés |
|-----------|--------|:--------:|:-------:|:--------:|:-------------------:|:--------:|:--------------:|
| MCC / MNC | 001 / 01 | `mcc`, `mnc` | `mcc`, `mnc`, IMSI | `guami`, `tai`, `plmn_support` | — | `serving.plmn_id` | IMSI |
| TAC | 1 | `tac` | — | `tai.tac` | — | — | — |
| Slice S-NSSAI | SST 1, SD 000001 | `slices` | `sessions`, `configured-nssai` | `plmn_support.s_nssai` | `smf.info.s_nssai` | — | slice de l'abonné |
| DNN | internet | — | `sessions.apn` | — | `session.dnn` | — | DNN de l'abonné |
| Adresse N2 | 10.20.0.10:38412 | `amfConfigs.address` | — | `ngap.server` | — | — | — |
| Adresse N3 côté gNB | 10.20.0.20 | `gtpIp`, `ngapIp` | — | — | — | — | — |
| Adresse N3 côté UPF | 10.20.0.10 | — | — | — | `upf.gtpu.server` | — | — |
| Lien radio | 127.0.0.1 | `linkIp` | `gnbSearchList` | — | — | — | — |
| Pool UE | 10.45.0.0/16 | — | — | — | `session.subnet` | — | — |
| K / OPc | **secret** | — | `key`, `op` (opType OPC) | — | — | — | `security.k`, `security.opc` |

**Règle** : une erreur sur l'une de ces lignes provoque une panne à une étape précise du chemin. La correspondance « paramètre faux → étape qui échoue → message attendu » est donnée dans [`chemin-et-diagnostic.md`](chemin-et-diagnostic.md), § 4.

## 8. Gestion des secrets

- Les clés `K` et `OPc` des abonnés ne sont jamais commitées. L'automatisation les lit depuis les variables `UE_K` et `UE_OPC` (ou un fichier `ansible-vault`). Un fichier `.env.example` sans valeur réelle peut documenter les noms attendus.
- Le mot de passe de la WebUI est changé au déploiement, et la WebUI n'est accessible que depuis le VLAN 10.
