# Journal de travail – Lounes (lot L1 : architecture, adressage, justification)

> À compléter à chaque séance : date, ce qui a été fait, fichiers et commits concernés, décisions, points ouverts.
> Ce journal sert à remplir la **fiche de contributions** (3 contributions principales avec un renvoi vers un fichier ou un commit).

---

## 2026-11-25 – Mise en place du lot L1

### Point de départ (état du dépôt)
- Présents : `README.md` (membres, répartition des lots), `P1_cahier_des_charges.pdf`, `schéma.txt` (3 hôtes de service + contrôleur, 3 VLAN, pool UE 10.45.0.0/16), `schéma-explicatif.png`, `manifest.yml` (versions), `core/`, `ue-gnb/` et `dn/docker-compose.yml`.
- Absents : les configurations Open5GS (`core/config/`), UERANSIM (`ue-gnb/config/`) et la page du DN (`dn/html/`).

### Ce qui a été fait
1. **Analyse du cahier des charges** pour le lot L1 : O1 (architecture distribuée justifiée face à au moins une alternative), invariants (N2/N3 sur un réseau réel, DN distinct au-delà de l'UPF), versions figées et justifiées, aucun secret dans le dépôt.
2. **`architecture/architecture.md`** :
   - placement des fonctions par hôte (option A : cœur centralisé sur srv-core, gNB+UE sur srv-ue, DN sur srv-dest, srv-ctrl pour l'automatisation) et diagramme Mermaid ;
   - 6 justifications du découpage, dont « un conteneur par NF » pour isoler la fonction en panne ;
   - **comparaison avec 3 alternatives** (B : UPF déporté en périphérie avec N4 sur le réseau ; C : mono-hôte ; D : 2 hôtes) sur 8 critères pondérés. Décision : A, avec B conservée comme extension facultative ;
   - tableau des choix techniques justifiés : Docker, `network_mode: host` (SCTP/GTP-U sans NAT Docker), versions, 3 VLAN, routage sans NAT vers le DN, secrets hors dépôt, MTU 1400 ;
   - registre de 6 risques d'architecture avec leurs parades.
3. **`architecture/plan-adressage.md`** : VLAN, adresses des hôtes, adresses SBI du cœur (valeurs par défaut d'Open5GS conservées), matrice des 9 flux (F1 à F9), pare-feu minimal, routage et sysctl, réserve d'adresses pour l'option B, **tableau des paramètres qui doivent concorder** entre gnb.yaml, ue.yaml, amf.yaml, smf/upf.yaml, nrf.yaml et la base, gestion des secrets.
4. **`architecture/parametres.yml`** : source unique de vérité pour l'automatisation (L2/L3) : adresses, VLAN, SBI, interfaces N2/N3/N4/N6, PLMN 001/01, TAC 1, slice 1/000001, DNN internet, MTU, liste des conteneurs. Validé avec un parseur YAML.
5. **`architecture/chemin-et-diagnostic.md`** (demande : « chemin d'accès, séparer les conteneurs pour le diagnostic, pour tester quelle fonction rate ») :
   - diagramme de séquence de l'accès complet (PFCP, NG Setup, enregistrement, session PDU) ;
   - chemin d'un paquet en 11 étapes, avec les adresses, l'encapsulation GTP-U (+44 octets) et les points de capture ;
   - tableau de diagnostic en 12 étapes : fonction/conteneur, preuve, causes, correction (méthode R5.03) ;
   - catalogue de 11 incidents provoqués possibles pour E4, avec l'étape en échec attendue.
6. **`architecture/diag/diag-chemin.sh`** : script de diagnostic en 12 étapes, lancé depuis srv-ctrl par SSH. Il teste chaque conteneur et chaque interface dans l'ordre du chemin et affiche la fonction en échec. Code de sortie = première étape en échec.
   - Tests réalisés hors maquette avec des commandes simulées (docker, ss, ip, ping, curl) : cas nominal → code 0 (42 contrôles OK) ; AMF arrêtée → code 3, fonction `amf`.
   - Corrigé pendant les tests : le contrôle SCTP vérifie d'abord l'écoute sur 38412 et ne regarde le module noyau qu'en cas d'échec.
7. **README principal** : ajout d'une section « Architecture » qui renvoie vers ce dossier.
8. **Relecture avant publication** : correction des numéros d'étapes cités dans le registre des risques (étapes 6, 7 et 11 du script), et récupération du code de sortie du script via `${PIPESTATUS[0]}` dans l'exemple avec `tee`.
9. **Publication sur `main`**, un commit par fichier, préfixés « L1 (Lounes) : » pour la fiche de contributions. Chaque fichier publié a été comparé octet par octet à la version de travail.

### Décisions prises
- Architecture A retenue. B (UPF déporté) devient une extension facultative ; ses adresses sont réservées (srv-upf .50, VLAN 40 pour N4).
- Pas de NAT sur N6 : le DN voit les vraies adresses UE (mesures attribuables).
- Adresses SBI par défaut d'Open5GS conservées : on ne modifie que `ngap.server`, `gtpu.server` et le pool de sessions.
- MTU de l'UE à 1400 recommandé (lien avec O5).

### Points signalés aux autres lots
- L3 (Ethan) : `ue-gnb/docker-compose.yml`, le service `ue` a `volumes:` vide (il manque `- ./config:/etc/ueransim`) ; `ue-gnb/config/` et `dn/html/` sont manquants.
- L2 (Alexis) : `core/config/` manquant ; utiliser les adresses de `parametres.yml`.
- Manifeste : `networkstatic/iperf3:latest` n'est pas figé, il faut le remplacer par un digest.
- L4 (Mohamed) : `diag-chemin.sh` peut être réutilisé ou intégré à la recette.

### Reste à faire (lot L1)
- [ ] Valider `diag-chemin.sh` sur la vraie maquette (formulation exacte des journaux des images gradiant) avant le J2.
- [ ] Faire valider par l'équipe les critères et poids de la comparaison, et l'intégrer à la note de faisabilité J1.
- [ ] Relever une capture N2/N3 de référence (numéros de trame) pour les « trois preuves clés » du J2.
- [ ] Rédiger la partie « Architecture et justification » du rapport à partir de ces fichiers.
