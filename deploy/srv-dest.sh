#!/usr/bin/env bash
# =============================================================================
# deploy/srv-dest.sh - Déploiement du serveur du réseau de données srv-dest (au-delà de l'UPF)
# nginx (HTTP :80) + iperf3 (:5201) sur 10.30.0.20, route retour vers les UE via srv-core.
# Idempotent.
#
#   sudo bash deploy/srv-dest.sh                 # déploiement
#   sudo bash deploy/srv-dest.sh --save-cache    # + sauvegarde des images pour le mode hors ligne
# Variables utiles : IF_MGMT IF_N6 VLAN_TRUNK SINGLE_NIC
# =============================================================================
source "$(dirname "$(readlink -f "$0")")/commun.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,10p' "$0"; exit 0; }
SAVE_CACHE=0; [[ ${1:-} == --save-cache ]] && SAVE_CACHE=1
DIR=$SAE51_DIR/dn
IMAGES=("$IMG_NGINX" "$IMG_IPERF3")

require_root
log "srv-dest : réseau de données"
check_os
set_hostname srv-dest
apt_install iproute2 iptables curl ca-certificates openssh-server tcpdump
grant_sudo

log "Réseau : VLAN 10 (admin), VLAN 30 (N6), route retour vers le pool UE"
choose_ifaces mgmt n6
install_net_service "$(
  net_lines_addr "$IF_MGMT" "$MGMT_DEST/24" "$VLAN_MGMT"
  net_lines_addr "$IF_N6"   "$DEST_N6/24"   "$VLAN_N6"
  echo "# route retour vers les UE : sans NAT, les réponses doivent repasser par l'UPF"
  echo "ip route replace $UE_POOL via $CORE_N6 dev $IF_N6"
)"

log "Docker et images"
install_docker
ensure_images "${IMAGES[@]}"
(( SAVE_CACHE )) && save_cache "${IMAGES[@]}"

CFG=0
if write_if_changed "$DIR/html/index.html" 644 <<'EOF'; then CFG=1; fi
<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><title>SAE51 - serveur DN</title></head>
<body><h1>SAE 51 P1 - serveur du réseau de données (srv-dest)</h1>
<p>Si vous lisez cette page depuis l'UE, le chemin UE &rarr; gNB &rarr; N3 &rarr; UPF &rarr; N6 &rarr; DN fonctionne.</p></body></html>
EOF

COMPOSE=$(cat <<EOF
# Généré par deploy/srv-dest.sh - ne pas modifier à la main
name: sae51-dn
services:
  web:
    image: $IMG_NGINX
    container_name: dn-nginx
    network_mode: host
    restart: unless-stopped
    volumes: ["./html:/usr/share/nginx/html:ro"]
  iperf3:
    image: $IMG_IPERF3
    container_name: dn-iperf3
    network_mode: host
    restart: unless-stopped
    command: ["-s", "-B", "$DEST_N6", "-p", "5201"]
EOF
)
if write_if_changed "$DIR/docker-compose.yml" 644 <<<"$COMPOSE"; then CFG=1; fi

log "Démarrage des conteneurs"
compose_up "$DIR" "$CFG"

log "Vérifications locales"
sleep 2
curl -fs --max-time 3 "http://$DEST_N6/" >/dev/null && ok "HTTP $DEST_N6:80" || warn "nginx ne répond pas : docker logs dn-nginx"
ss -Hltn | grep -q "$DEST_N6:5201" && ok "iperf3 $DEST_N6:5201" || warn "iperf3 n'écoute pas : docker logs dn-iperf3"
ip route get "$UE_GW" | grep -q "via $CORE_N6" && ok "route retour $UE_POOL via $CORE_N6" || warn "route retour absente"
finish
