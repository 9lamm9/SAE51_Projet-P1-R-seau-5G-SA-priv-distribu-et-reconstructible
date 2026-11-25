#!/usr/bin/env bash
# =============================================================================
# diag-chemin.sh - Diagnostic du réseau 5G SA, étape par étape, fonction par fonction
# SAE 5.01 P1 - lot L1 (Lounes) - à intégrer / compléter par la recette (lot L4)
# -----------------------------------------------------------------------------
# Suit le chemin d'un accès 5G dans l'ordre où il se construit :
#   liens IP -> conteneurs du cœur -> base -> SBI -> N2 -> UPF/N4 -> gNB (NG Setup)
#   -> UE (enregistrement) -> session PDU -> DN -> paquet de bout en bout (N3+N6)
# Chaque fonction réseau étant dans SON conteneur, le script indique QUELLE
# fonction échoue et à QUELLE étape. Toutes les étapes sont exécutées (pour
# donner le maximum d'indices) ; le code de sortie = numéro de la PREMIÈRE
# étape en échec (0 = tout est bon). Correspondance étape -> causes probables :
# architecture/chemin-et-diagnostic.md, § 4.
#
# Exécution : depuis srv-ctrl (accès SSH par clé aux 3 hôtes), ou sur un seul
# hôte en mettant CORE_HOST/UE_HOST/DN_HOST=local.
#   bash diag-chemin.sh         # diagnostic complet
#   bash diag-chemin.sh | tee diag-$(date +%Y%m%d-%H%M%S).log
#
# Variables (valeurs par défaut = architecture/parametres.yml) :
#   CORE_HOST UE_HOST DN_HOST   adresses d'administration (VLAN 10) ou "local"
#   SSH_USER                    utilisateur SSH (défaut : utilisateur courant)
#   DOCKER                      commande docker distante (défaut : "sudo -n docker")
# =============================================================================
set -u

CORE_HOST=${CORE_HOST:-192.168.10.20}
UE_HOST=${UE_HOST:-192.168.10.30}
DN_HOST=${DN_HOST:-192.168.10.40}
SSH_USER=${SSH_USER:-$(id -un)}
DOCKER=${DOCKER:-sudo -n docker}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# Adressage (architecture/parametres.yml)
AMF_N2=10.20.0.10        # AMF NGAP + UPF GTP-U (srv-core eth1)
GNB_N2=10.20.0.20        # gNB (srv-ue eth1)
UPF_N6=10.30.0.10        # srv-core eth2
DN_IP=10.30.0.20         # srv-dest eth1
UPF_GW=10.45.0.1         # ogstun
UE_TEST_IP=10.45.0.2     # adresse UE typique, pour tester la route retour

declare -A SBI=( [nrf]=127.0.0.10 [scp]=127.0.0.200 [amf]=127.0.0.5 [smf]=127.0.0.4
                 [ausf]=127.0.0.11 [udm]=127.0.0.12 [pcf]=127.0.0.13 [nssf]=127.0.0.14
                 [bsf]=127.0.0.15 [udr]=127.0.0.20 )
CORE_NF=(mongo nrf scp udr udm ausf pcf bsf nssf amf smf upf)

if [[ ${1:-} == -h || ${1:-} == --help ]]; then sed -n '2,27p' "$0"; exit 0; fi

# --- outils ------------------------------------------------------------------
rsh() {  # rsh <hôte|local> <commande>
  local h=$1; shift
  if [[ $h == local ]]; then bash -c "$*"
  else ssh "${SSH_OPTS[@]}" "$SSH_USER@$h" "$*"; fi
}
STEP=0; FIRST_FAIL=0; FIRST_FAIL_FN=""; NB_OK=0; NB_KO=0
step() { STEP=$1; printf '\nÉtape %-2s %s\n' "$1" "$2"; }
ok()   { NB_OK=$((NB_OK+1)); printf '  [OK]    %-9s %s\n' "$1" "$2"; }
ko()   { NB_KO=$((NB_KO+1)); printf '  [ECHEC] %-9s %s\n' "$1" "$2"
         if (( FIRST_FAIL == 0 )); then FIRST_FAIL=$STEP; FIRST_FAIL_FN=$1; fi; }
running() {  # running <hôte> <conteneur>
  [[ $(rsh "$1" "$DOCKER inspect -f '{{.State.Running}}' $2 2>/dev/null") == true ]]
}
restarts() { rsh "$1" "$DOCKER inspect -f '{{.RestartCount}}' $2 2>/dev/null" || echo "?"; }
log_has() {  # log_has <hôte> <conteneur> <motif> : cherche dans les journaux depuis le dernier démarrage
  rsh "$1" "s=\$($DOCKER inspect -f '{{.State.StartedAt}}' $2 2>/dev/null) && $DOCKER logs --since \"\$s\" $2 2>&1 | grep -q -- '$3'"
}

echo "=== Diagnostic du chemin 5G - $(date '+%F %T') ==="
echo "srv-core=$CORE_HOST  srv-ue=$UE_HOST  srv-dest=$DN_HOST"

# --- 1. accès d'administration -------------------------------------------------
step 1 "Accès d'administration aux hôtes (VLAN 10)"
for pair in "srv-core:$CORE_HOST" "srv-ue:$UE_HOST" "srv-dest:$DN_HOST"; do
  n=${pair%%:*}; h=${pair#*:}
  if rsh "$h" true 2>/dev/null; then ok "$n" "SSH joignable ($h)"
  else ko "$n" "SSH injoignable ($h) : hôte éteint, VLAN 10 ou clé SSH"; fi
done

# --- 2. liens IP des interfaces 5G -------------------------------------------
step 2 "Liens IP traversant le réseau (VLAN 20 pour N2/N3, VLAN 30 pour N6)"
if rsh "$UE_HOST" "ping -c 2 -W 2 -I $GNB_N2 $AMF_N2 >/dev/null 2>&1"; then
  ok "vlan20" "srv-ue $GNB_N2 -> srv-core $AMF_N2"
else ko "vlan20" "srv-ue $GNB_N2 ne joint pas $AMF_N2 (câblage/VLAN 20/adresse eth1)"; fi
if rsh "$CORE_HOST" "ping -c 2 -W 2 -I $UPF_N6 $DN_IP >/dev/null 2>&1"; then
  ok "vlan30" "srv-core $UPF_N6 -> srv-dest $DN_IP"
else ko "vlan30" "srv-core $UPF_N6 ne joint pas $DN_IP (VLAN 30/adresse eth2)"; fi

# --- 3. un conteneur par fonction du cœur -------------------------------------
step 3 "Conteneurs du cœur (une fonction = un conteneur)"
for nf in "${CORE_NF[@]}"; do
  c=open5gs-$nf
  if running "$CORE_HOST" "$c"; then
    r=$(restarts "$CORE_HOST" "$c")
    if [[ $r =~ ^[0-9]+$ ]] && (( r > 0 )); then ok "$nf" "$c démarré (ATTENTION : $r redémarrage(s), voir docker logs $c)"
    else ok "$nf" "$c démarré"; fi
  else ko "$nf" "$c arrêté ou absent -> docker logs $c (erreur de configuration YAML ?)"; fi
done

# --- 4. base des abonnés ------------------------------------------------------
step 4 "Base d'abonnés (MongoDB, utilisée par UDR)"
n=$(rsh "$CORE_HOST" "$DOCKER exec open5gs-mongo mongosh --quiet open5gs --eval 'db.subscribers.countDocuments()' 2>/dev/null" | tr -dc '0-9')
if [[ -n $n ]] && (( n > 0 )); then ok "mongo" "$n abonné(s) provisionné(s)"
elif [[ -n $n ]]; then ko "mongo" "base joignable mais AUCUN abonné : l'UE sera rejetée à l'enregistrement"
else ko "mongo" "MongoDB ne répond pas"; fi

# --- 5. interfaces de service (SBI) ------------------------------------------
step 5 "Fonctions du plan de contrôle à l'écoute sur leur SBI (TCP 7777)"
listen_tcp=$(rsh "$CORE_HOST" "ss -Hltn 2>/dev/null" | awk '{print $4}')
for nf in nrf scp amf smf ausf udm udr pcf nssf bsf; do
  if grep -qx "${SBI[$nf]}:7777" <<<"$listen_tcp"; then ok "$nf" "SBI ${SBI[$nf]}:7777"
  else ko "$nf" "n'écoute pas sur ${SBI[$nf]}:7777 (NF arrêtée ou adresse SBI modifiée)"; fi
done
if log_has "$CORE_HOST" open5gs-nrf "NF registered"; then ok "nrf" "des NF se sont enregistrées auprès du NRF"
else ko "nrf" "aucun enregistrement de NF vu dans les journaux du NRF"; fi

# --- 6. N2 côté cœur ----------------------------------------------------------
step 6 "N2 : AMF à l'écoute NGAP/SCTP"
if rsh "$CORE_HOST" "ss -HSln 2>/dev/null | grep -q '$AMF_N2:38412'"; then
  ok "amf" "NGAP SCTP $AMF_N2:38412"
elif ! rsh "$CORE_HOST" "grep -qw sctp /proc/modules 2>/dev/null || test -d /sys/module/sctp"; then
  ko "amf" "module noyau SCTP non chargé sur srv-core (modprobe sctp)"
else ko "amf" "pas d'écoute SCTP sur $AMF_N2:38412 (ngap.server dans amf.yaml ?)"; fi

# --- 7. UPF et N4 -------------------------------------------------------------
step 7 "UPF : N3 (GTP-U), N4 (PFCP), interface ogstun, transfert IP"
if rsh "$CORE_HOST" "ss -Hlun 2>/dev/null | awk '{print \$4}' | grep -qx '$AMF_N2:2152'"; then
  ok "upf" "GTP-U UDP $AMF_N2:2152"
else ko "upf" "pas d'écoute GTP-U sur $AMF_N2:2152 (gtpu.server dans upf.yaml ?)"; fi
if log_has "$CORE_HOST" open5gs-smf "PFCP associated"; then ok "smf" "association PFCP SMF<->UPF (N4) établie"
else ko "smf" "pas d'association PFCP : SMF ou UPF arrêté, ou adresses pfcp incohérentes"; fi
if rsh "$CORE_HOST" "ip -4 -o addr show dev ogstun 2>/dev/null | grep -q '$UPF_GW/'"; then
  ok "upf" "ogstun porte $UPF_GW"
else ko "upf" "interface ogstun absente ou sans $UPF_GW (/dev/net/tun, NET_ADMIN)"; fi
if [[ $(rsh "$CORE_HOST" "sysctl -n net.ipv4.ip_forward") == 1 ]]; then ok "srv-core" "ip_forward=1"
else ko "srv-core" "ip_forward=0 : l'UE s'attachera mais aucun paquet ne passera vers N6"; fi

# --- 8. gNB -------------------------------------------------------------------
step 8 "gNB : association SCTP et NG Setup (N2 sur le réseau)"
if ! running "$UE_HOST" ueransim-gnb; then ko "gnb" "conteneur ueransim-gnb arrêté"
elif log_has "$UE_HOST" ueransim-gnb "NG Setup procedure is successful"; then ok "gnb" "NG Setup réussi avec l'AMF"
elif log_has "$UE_HOST" ueransim-gnb "SCTP connection established"; then
  ko "gnb" "SCTP établi mais NG Setup refusé : PLMN/TAC/slice différents entre gnb.yaml et amf.yaml"
else ko "gnb" "pas d'association SCTP vers $AMF_N2:38412 (pare-feu, module sctp, amfConfigs)"; fi

# --- 9. UE : enregistrement ---------------------------------------------------
step 9 "UE : enregistrement (NAS via AMF, AUSF, UDM, UDR)"
if ! running "$UE_HOST" ueransim-ue; then ko "ue" "conteneur ueransim-ue arrêté"
elif log_has "$UE_HOST" ueransim-ue "Initial Registration is successful"; then ok "ue" "enregistrement réussi"
else ko "ue" "enregistrement non abouti : IMSI absent de la base, K/OPc faux, ou AUSF/UDM/UDR en panne"; fi

# --- 10. session PDU ----------------------------------------------------------
step 10 "Session PDU (SMF + UPF via N4, tunnel N3)"
ue_ip=$(rsh "$UE_HOST" "ip -4 -o addr show dev uesimtun0 2>/dev/null" | awk '{print $4}' | cut -d/ -f1)
if log_has "$UE_HOST" ueransim-ue "PDU Session establishment is successful" && [[ -n $ue_ip ]]; then
  ok "smf" "session PDU établie, uesimtun0 = $ue_ip"
else ue_ip=""; ko "smf" "pas de session PDU / pas de uesimtun0 (DNN ou slice inconnus, SMF ou PFCP en panne)"; fi

# --- 11. réseau de données ----------------------------------------------------
step 11 "Réseau de données (srv-dest) : services et route retour vers les UE"
for c in dn-nginx dn-iperf3; do
  if running "$DN_HOST" "$c"; then ok "dn" "$c démarré"; else ko "dn" "$c arrêté"; fi
done
if rsh "$DN_HOST" "ip route get ${ue_ip:-$UE_TEST_IP} 2>/dev/null | grep -q 'via $UPF_N6'"; then
  ok "dn" "route retour vers ${ue_ip:-$UE_TEST_IP} via $UPF_N6"
else ko "dn" "pas de route 10.45.0.0/16 via $UPF_N6 : les réponses du DN n'atteignent pas l'UE"; fi

# --- 12. paquet de bout en bout ----------------------------------------------
step 12 "Plan utilisateur de bout en bout : UE -> gNB -> N3 -> UPF -> N6 -> DN"
if [[ -z $ue_ip ]]; then ko "plan-util" "test impossible : pas d'adresse UE (voir étape 10)"
else
  if rsh "$UE_HOST" "ping -I uesimtun0 -c 3 -W 2 $DN_IP >/dev/null 2>&1"; then ok "plan-util" "ping $ue_ip -> $DN_IP via le tunnel"
  else ko "plan-util" "ping via uesimtun0 échoue (GTP-U filtré, ip_forward, route retour, MTU)"; fi
  code=$(rsh "$UE_HOST" "curl -s -o /dev/null -w '%{http_code}' --interface uesimtun0 --max-time 5 http://$DN_IP/" 2>/dev/null)
  if [[ $code == 200 ]]; then ok "plan-util" "HTTP 200 depuis le serveur DN"
  else ko "plan-util" "HTTP vers $DN_IP en échec (code '${code:-aucun}')"; fi
fi

# --- synthèse -----------------------------------------------------------------
echo
echo "=== Synthèse : $NB_OK contrôle(s) OK, $NB_KO en échec ==="
if (( FIRST_FAIL == 0 )); then
  echo "Réseau fonctionnel de bout en bout."
else
  echo "Première étape en échec : $FIRST_FAIL (fonction : $FIRST_FAIL_FN)"
  echo "-> causes probables et preuves à relever : architecture/chemin-et-diagnostic.md, § 4"
fi
exit "$FIRST_FAIL"
