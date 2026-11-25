#!/usr/bin/env bash
# =============================================================================
# deploy/srv-ctrl.sh - Préparation du poste de contrôle srv-ctrl
# Adresse d'administration (VLAN 10), outils (git, ssh, tcpdump, iperf3), clé SSH,
# fichier de secrets local. Ensuite, tout se pilote depuis ici avec deploy-all.sh.
#
#   sudo bash deploy/srv-ctrl.sh
# Variables utiles : IF_MGMT VLAN_TRUNK SINGLE_NIC
# =============================================================================
source "$(dirname "$(readlink -f "$0")")/commun.sh"
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,8p' "$0"; exit 0; }

require_root
log "srv-ctrl : poste de contrôle (automatisation, recette, mesures)"
check_os
set_hostname srv-ctrl
apt_install iproute2 git openssh-client curl ca-certificates tcpdump iperf3 iputils-ping

log "Réseau : VLAN 10 (admin)"
choose_ifaces mgmt
install_net_service "$(net_lines_addr "$IF_MGMT" "$MGMT_CTRL/24" "$VLAN_MGMT")"

U=${SUDO_USER:-root}; H=$(getent passwd "$U" | cut -d: -f6)
log "Clé SSH et secrets pour l'utilisateur $U"
if [[ -f $H/.ssh/id_ed25519 ]]; then ok "clé SSH $H/.ssh/id_ed25519 présente"
else sudo -u "$U" mkdir -p "$H/.ssh"; sudo -u "$U" ssh-keygen -q -t ed25519 -N '' -f "$H/.ssh/id_ed25519"; change "clé SSH générée"; fi
if [[ -f $H/.sae51/secrets.env ]]; then ok "secrets présents ($H/.sae51/secrets.env)"
else
  sudo -u "$U" mkdir -p "$H/.sae51"; chmod 700 "$H/.sae51"
  { echo "# Secrets SAE 51 - NE PAS COMMITER"
    echo "UE_K=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    echo "UE_OPC=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"; } >"$H/.sae51/secrets.env"
  chown "$U:" "$H/.sae51/secrets.env"; chmod 600 "$H/.sae51/secrets.env"
  change "clés K/OPc de l'abonné générées dans $H/.sae51/secrets.env"
fi
finish
cat <<EOF

Étapes suivantes (en tant que $U, sans sudo) :
  1. bash deploy/deploy-all.sh --keys    # une seule fois : copie la clé SSH sur les 3 VM (mots de passe demandés)
  2. bash deploy/deploy-all.sh           # reconstruction complète + recette, une seule commande
EOF
