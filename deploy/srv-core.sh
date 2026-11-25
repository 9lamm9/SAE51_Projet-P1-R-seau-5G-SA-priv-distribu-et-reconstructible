#!/usr/bin/env bash
# =============================================================================
# deploy/srv-core.sh - Déploiement du serveur central srv-core depuis une VM vierge
# Cœur 5G Open5GS 2.7.7 : un conteneur par fonction (NRF, SCP, AMF, SMF, UPF,
# AUSF, UDM, UDR, PCF, NSSF, BSF) + MongoDB + WebUI, en network_mode: host.
# Idempotent : un second passage ne change rien (compteur de changements = 0).
#
#   sudo bash deploy/srv-core.sh                 # déploiement
#   sudo bash deploy/srv-core.sh --save-cache    # + sauvegarde des images pour le mode hors ligne
# Variables utiles : IF_MGMT IF_N2N3 IF_N6 VLAN_TRUNK SINGLE_NIC UE_K UE_OPC IMSI
# =============================================================================
source "$(dirname "$(readlink -f "$0")")/commun.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,12p' "$0"; exit 0; }
SAVE_CACHE=0; [[ ${1:-} == --save-cache ]] && SAVE_CACHE=1
DIR=$SAE51_DIR/core
IMAGES=("$IMG_OPEN5GS" "$IMG_WEBUI" "$IMG_MONGO")

require_root
log "srv-core : cœur 5G Open5GS"
check_os
set_hostname srv-core
apt_install iproute2 iptables curl ca-certificates openssh-server tcpdump
grant_sudo

log "Réseau : VLAN 10 (admin), VLAN 20 (N2/N3), VLAN 30 (N6), ogstun"
choose_ifaces mgmt n2n3 n6
install_net_service "$(
  net_lines_addr "$IF_MGMT" "$MGMT_CORE/24" "$VLAN_MGMT"
  net_lines_addr "$IF_N2N3" "$CORE_N2N3/24" "$VLAN_RAN"
  net_lines_addr "$IF_N6"   "$CORE_N6/24"   "$VLAN_N6"
  echo "# interface du plan utilisateur (passerelle des UE), ouverte ensuite par l'UPF"
  echo "ip link show ogstun >/dev/null 2>&1 || ip tuntap add name ogstun mode tun"
  echo "ip addr replace $UE_GW/${UE_POOL#*/} dev ogstun"
  echo "ip link set ogstun up"
)"
set_sysctl net.ipv4.ip_forward 1
load_sctp

log "Docker et images"
install_docker
ensure_images "${IMAGES[@]}"
(( SAVE_CACHE )) && save_cache "${IMAGES[@]}"
load_secrets 1

log "Configurations Open5GS ($DIR/config)"
CFG=0
cfg() { if write_if_changed "$DIR/config/$1" 644; then CFG=1; fi; }
SCP_CLIENT="    client:
      scp:
        - uri: http://127.0.0.200:7777"
PLMN="mcc: $MCC
        mnc: $MNC"

cfg nrf.yaml <<EOF
nrf:
  serving:
    - plmn_id:
        $PLMN
  sbi:
    server:
      - address: 127.0.0.10
        port: 7777
EOF
cfg scp.yaml <<EOF
scp:
  sbi:
    server:
      - address: 127.0.0.200
        port: 7777
    client:
      nrf:
        - uri: http://127.0.0.10:7777
EOF
cfg amf.yaml <<EOF
amf:
  sbi:
    server:
      - address: 127.0.0.5
        port: 7777
$SCP_CLIENT
  ngap:
    server:
      - address: $CORE_N2N3
  guami:
    - plmn_id:
        $PLMN
      amf_id:
        region: 2
        set: 1
  tai:
    - plmn_id:
        $PLMN
      tac: $TAC
  plmn_support:
    - plmn_id:
        $PLMN
      s_nssai:
        - sst: $SST
          sd: $SD
  security:
    integrity_order: [ NIA2, NIA1, NIA0 ]
    ciphering_order: [ NEA0, NEA1, NEA2 ]
  network_name:
    full: SAE51
    short: SAE51
  amf_name: sae51-amf0
  time:
    t3512:
      value: 540
EOF
cfg smf.yaml <<EOF
smf:
  sbi:
    server:
      - address: 127.0.0.4
        port: 7777
$SCP_CLIENT
  pfcp:
    server:
      - address: 127.0.0.4
    client:
      upf:
        - address: 127.0.0.7
  gtpc:
    server:
      - address: 127.0.0.4
  gtpu:
    server:
      - address: 127.0.0.4
  session:
    - subnet: $UE_POOL
      gateway: $UE_GW
      dnn: $DNN
  dns:
    - 8.8.8.8
    - 8.8.4.4
  mtu: ${UE_MTU:-1400}
EOF
cfg upf.yaml <<EOF
upf:
  pfcp:
    server:
      - address: 127.0.0.7
  gtpu:
    server:
      - address: $CORE_N2N3
  session:
    - subnet: $UE_POOL
      gateway: $UE_GW
      dnn: $DNN
      dev: ogstun
EOF
for nf in ausf:127.0.0.11 udm:127.0.0.12 bsf:127.0.0.15; do
cfg "${nf%%:*}.yaml" <<EOF
${nf%%:*}:
  sbi:
    server:
      - address: ${nf#*:}
        port: 7777
$SCP_CLIENT
EOF
done
for nf in udr:127.0.0.20 pcf:127.0.0.13; do
cfg "${nf%%:*}.yaml" <<EOF
db_uri: mongodb://127.0.0.1/open5gs
${nf%%:*}:
  sbi:
    server:
      - address: ${nf#*:}
        port: 7777
$SCP_CLIENT
EOF
done
cfg nssf.yaml <<EOF
nssf:
  sbi:
    server:
      - address: 127.0.0.14
        port: 7777
$SCP_CLIENT
      nsi:
        - uri: http://127.0.0.10:7777
          s_nssai:
            sst: $SST
            sd: $SD
EOF
(( CFG )) || ok "configurations Open5GS inchangées"

# --- docker-compose : un service par fonction réseau --------------------------
nf_service() {  # nf_service <nf> [options supplémentaires]
  cat <<EOF
  $1:
    image: $IMG_OPEN5GS
    container_name: open5gs-$1
    network_mode: host
    restart: unless-stopped
    entrypoint: ["open5gs-$1d"]
    command: ["-c", "/etc/open5gs/$1.yaml"]
    volumes: ["./config:/etc/open5gs:ro"]
EOF
}
COMPOSE=$( cat <<EOF
# Généré par deploy/srv-core.sh - ne pas modifier à la main
name: sae51-core
services:
  mongo:
    image: $IMG_MONGO
    container_name: open5gs-mongo
    network_mode: host
    restart: unless-stopped
    command: ["--bind_ip", "127.0.0.1", "--port", "27017"]
    volumes: ["mongo_data:/data/db"]
  webui:
    image: $IMG_WEBUI
    container_name: open5gs-webui
    network_mode: host
    restart: unless-stopped
    environment: { DB_URI: "mongodb://127.0.0.1/open5gs", HOSTNAME: "$MGMT_CORE", PORT: "9999" }
    depends_on: [mongo]
EOF
  nf_service nrf
  nf_service scp;  echo "    depends_on: [nrf]"
  for nf in udr pcf; do nf_service $nf; echo "    environment: { DB_URI: \"mongodb://127.0.0.1/open5gs\" }"; echo "    depends_on: [mongo, scp]"; done
  for nf in udm ausf bsf nssf amf smf; do nf_service $nf; echo "    depends_on: [scp]"; done
  nf_service upf
  cat <<'EOF'
    user: root
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
volumes:
  mongo_data:
EOF
)
if write_if_changed "$DIR/docker-compose.yml" 644 <<<"$COMPOSE"; then CFG=1; fi

log "Démarrage des conteneurs"
compose_up "$DIR" "$CFG"

log "Abonné $IMSI dans MongoDB (clés lues dans $SAE51_ETC/secrets.env)"
for i in $(seq 1 30); do
  docker exec open5gs-mongo mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 2; [[ $i == 30 ]] && die "MongoDB ne répond pas : docker logs open5gs-mongo"
done
JS=$(cat <<EOF
const imsi="$IMSI", k="${UE_K,,}", opc="${UE_OPC,,}";
const cur=db.subscribers.findOne({imsi:imsi});
const ok = cur && cur.security && cur.security.k===k && cur.security.opc===opc
  && cur.slice && cur.slice.length===1 && cur.slice[0].sd==="$SD" && cur.slice[0].session[0].name==="$DNN";
if (ok) { print("INCHANGE"); } else {
  const ambr={downlink:{value:NumberInt(1),unit:NumberInt(3)},uplink:{value:NumberInt(1),unit:NumberInt(3)}};
  db.subscribers.replaceOne({imsi:imsi},{
    schema_version:NumberInt(1), imsi:imsi, msisdn:[], imeisv:[], mme_host:[], mme_realm:[], purge_flag:[],
    security:{k:k, op:null, opc:opc, amf:"8000"},
    ambr:ambr,
    slice:[{ sst:NumberInt($SST), sd:"$SD", default_indicator:true,
      session:[{ name:"$DNN", type:NumberInt(3),
        qos:{index:NumberInt(9), arp:{priority_level:NumberInt(8), pre_emption_capability:NumberInt(1), pre_emption_vulnerability:NumberInt(1)}},
        ambr:ambr, pcc_rule:[], _id:new ObjectId() }],
      _id:new ObjectId() }],
    access_restriction_data:NumberInt(32), subscriber_status:NumberInt(0), network_access_mode:NumberInt(0),
    operator_determined_barring:NumberInt(0), subscribed_rau_tau_timer:NumberInt(12), __v:0
  },{upsert:true});
  print("MAJ");
}
EOF
)
res=$(docker exec open5gs-mongo mongosh --quiet open5gs --eval "$JS" 2>&1) || true
case "$res" in *INCHANGE*) ok "abonné $IMSI déjà provisionné";; *MAJ*) change "abonné $IMSI provisionné";; *) die "provisionnement de l'abonné en échec : $res";; esac

log "Vérifications locales"
sleep 5
ss -HSln 2>/dev/null | grep -q "$CORE_N2N3:38412" && ok "AMF écoute N2 (SCTP $CORE_N2N3:38412)" || warn "AMF pas encore à l'écoute sur N2 : docker logs open5gs-amf"
ss -Hlun 2>/dev/null | grep -q "$CORE_N2N3:2152"  && ok "UPF écoute N3 (GTP-U $CORE_N2N3:2152)" || warn "UPF pas encore à l'écoute sur N3 : docker logs open5gs-upf"
finish
