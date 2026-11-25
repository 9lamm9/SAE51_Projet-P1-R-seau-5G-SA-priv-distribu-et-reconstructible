#!/usr/bin/env bash
# =============================================================================
# deploy/srv-ue.sh - Déploiement de la machine de périphérie srv-ue (gNB + UE UERANSIM 3.2.6)
# Idempotent. À lancer APRÈS srv-core (le gNB doit joindre l'AMF sur N2).
#
#   sudo bash deploy/srv-ue.sh                 # déploiement
#   sudo bash deploy/srv-ue.sh --save-cache    # + sauvegarde des images pour le mode hors ligne
# Les clés UE_K/UE_OPC sont lues dans /etc/sae51/secrets.env (copié depuis srv-core
# ou poussé par deploy-all.sh), sinon demandées au clavier.
# Variables utiles : IF_MGMT IF_N2N3 VLAN_TRUNK SINGLE_NIC UE_MTU IMSI
# =============================================================================
source "$(dirname "$(readlink -f "$0")")/commun.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,11p' "$0"; exit 0; }
SAVE_CACHE=0; [[ ${1:-} == --save-cache ]] && SAVE_CACHE=1
DIR=$SAE51_DIR/ue-gnb
IMAGES=("$IMG_UERANSIM")

require_root
log "srv-ue : gNB + UE (UERANSIM)"
check_os
set_hostname srv-ue
apt_install iproute2 iptables curl ca-certificates openssh-server tcpdump iperf3 iputils-ping
grant_sudo

log "Réseau : VLAN 10 (admin), VLAN 20 (N2/N3)"
choose_ifaces mgmt n2n3
install_net_service "$(
  net_lines_addr "$IF_MGMT" "$MGMT_UE/24" "$VLAN_MGMT"
  net_lines_addr "$IF_N2N3" "$UE_N2N3/24" "$VLAN_RAN"
)"
load_sctp

log "Docker et images"
install_docker
ensure_images "${IMAGES[@]}"
(( SAVE_CACHE )) && save_cache "${IMAGES[@]}"
load_secrets 0

log "Configurations UERANSIM ($DIR/config)"
CFG=0
cfg() { if write_if_changed "$DIR/config/$1" 644; then CFG=1; fi; }
cfg gnb.yaml <<EOF
mcc: '$MCC'
mnc: '$MNC'
nci: '0x000000010'
idLength: 32
tac: $TAC
linkIp: 127.0.0.1
ngapIp: $UE_N2N3
gtpIp: $UE_N2N3
amfConfigs:
  - address: $CORE_N2N3
    port: 38412
slices:
  - sst: $SST
    sd: 0x$SD
ignoreStreamIds: true
EOF
cfg ue.yaml <<EOF
supi: 'imsi-$IMSI'
mcc: '$MCC'
mnc: '$MNC'
key: '${UE_K,,}'
op: '${UE_OPC,,}'
opType: 'OPC'
amf: '8000'
imei: '356938035643803'
imeiSv: '4370816125816151'
gnbSearchList:
  - 127.0.0.1
uacAic:
  mps: false
  mcs: false
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false
sessions:
  - type: 'IPv4'
    apn: '$DNN'
    slice:
      sst: $SST
      sd: 0x$SD
configured-nssai:
  - sst: $SST
    sd: 0x$SD
default-nssai:
  - sst: $SST
    sd: 0x$SD
integrity:
  IA1: true
  IA2: true
  IA3: true
ciphering:
  EA1: true
  EA2: true
  EA3: true
integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
EOF
chmod 600 "$DIR/config/ue.yaml"   # contient les secrets
(( CFG )) || ok "configurations UERANSIM inchangées"

COMPOSE=$(cat <<EOF
# Généré par deploy/srv-ue.sh - ne pas modifier à la main
name: sae51-ue-gnb
services:
  gnb:
    image: $IMG_UERANSIM
    container_name: ueransim-gnb
    network_mode: host
    restart: unless-stopped
    entrypoint: ["nr-gnb"]
    command: ["-c", "/etc/sae51/gnb.yaml"]
    volumes: ["./config:/etc/sae51:ro"]
  ue:
    image: $IMG_UERANSIM
    container_name: ueransim-ue
    network_mode: host
    restart: unless-stopped
    entrypoint: ["nr-ue"]
    command: ["-c", "/etc/sae51/ue.yaml"]
    volumes: ["./config:/etc/sae51:ro"]
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    depends_on: [gnb]
EOF
)
if write_if_changed "$DIR/docker-compose.yml" 644 <<<"$COMPOSE"; then CFG=1; fi

log "Démarrage des conteneurs"
compose_up "$DIR" "$CFG"

log "Attente du tunnel de l'UE (uesimtun0)"
for i in $(seq 1 30); do ip link show uesimtun0 >/dev/null 2>&1 && break; sleep 2; done
if ip link show uesimtun0 >/dev/null 2>&1; then
  ok "uesimtun0 : $(ip -4 -o addr show dev uesimtun0 | awk '{print $4}')"
  if [[ -n $UE_MTU && $(cat /sys/class/net/uesimtun0/mtu) != "$UE_MTU" ]]; then
    ip link set dev uesimtun0 mtu "$UE_MTU"; change "MTU de uesimtun0 -> $UE_MTU"
  fi
  if ping -I uesimtun0 -c 3 -W 2 "$DEST_N6" >/dev/null 2>&1; then ok "ping UE -> serveur DN $DEST_N6 : OK (bout en bout)"
  else warn "ping UE -> $DEST_N6 en échec : lancer architecture/diag/diag-chemin.sh"; fi
else
  warn "uesimtun0 absent après 60 s : docker logs ueransim-gnb / ueransim-ue, puis diag-chemin.sh"
fi
finish
