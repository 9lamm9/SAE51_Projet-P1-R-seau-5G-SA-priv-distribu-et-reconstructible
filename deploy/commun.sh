#!/usr/bin/env bash
# =============================================================================
# deploy/commun.sh - Fonctions et paramètres communs aux scripts de chaque VM
# SAE 5.01 P1 - à sourcer, ne pas exécuter directement.
# Les valeurs ci-dessous reprennent architecture/parametres.yml (source de vérité) :
# toute modification doit être faite dans les deux fichiers.
# =============================================================================
set -euo pipefail

# --- Paramètres d'architecture (architecture/parametres.yml) ------------------
MGMT_CTRL=192.168.10.10; MGMT_CORE=192.168.10.20; MGMT_UE=192.168.10.30; MGMT_DEST=192.168.10.40
CORE_N2N3=10.20.0.10;    UE_N2N3=10.20.0.20
CORE_N6=10.30.0.10;      DEST_N6=10.30.0.20
UE_POOL=10.45.0.0/16;    UE_GW=10.45.0.1
VLAN_MGMT=10; VLAN_RAN=20; VLAN_N6=30
MCC=001; MNC=01; TAC=1; SST=1; SD=000001; DNN=internet
IMSI=${IMSI:-001010000000001}
UE_MTU=${UE_MTU:-1400}          # vide = ne pas modifier le MTU de uesimtun0

# --- Versions figées (manifest.yml) -------------------------------------------
IMG_OPEN5GS=gradiant/open5gs:2.7.7
IMG_WEBUI=gradiant/open5gs-webui:2.7.7
IMG_UERANSIM=gradiant/ueransim:3.2.6
IMG_MONGO=mongo:6.0.15
IMG_NGINX=nginx:1.27.3-alpine
IMG_IPERF3=${IMG_IPERF3:-networkstatic/iperf3:latest}   # digest relevé dans versions.txt

# --- Emplacements -------------------------------------------------------------
SAE51_DIR=/opt/sae51                 # fichiers générés (compose, configurations)
SAE51_ETC=/etc/sae51                 # état local (interfaces choisies, secrets)
SAE51_LOG=/var/log/sae51
SAE51_CACHE=${SAE51_CACHE:-/var/cache/sae51/images}   # images .tar pour le mode hors ligne

# --- Affichage et compteur de changements (indicateur E2 : idempotence) ------
CHANGES=0
T0=$(date +%s)
log()    { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
ok()     { printf '  \033[32m✔\033[0m %s\n' "$*"; }
change() { CHANGES=$((CHANGES+1)); printf '  \033[33m↻\033[0m %s\n' "$*"; }
warn()   { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()    { printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "lancer avec sudo : sudo bash $0"; }

check_os() {
  . /etc/os-release
  case "$ID" in debian|ubuntu) ok "système $PRETTY_NAME" ;;
    *) die "système $ID non pris en charge (Debian 12 ou Ubuntu 22.04/24.04 attendus)";; esac
  OS_ID=$ID; OS_CODENAME=$VERSION_CODENAME
}

# write_if_changed <fichier> <mode> : écrit stdin dans le fichier seulement si le contenu diffère
write_if_changed() {
  local f=$1 mode=${2:-644} tmp; tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 1; fi
  install -D -m "$mode" "$tmp" "$f"; rm -f "$tmp"; change "fichier $f écrit"; return 0
}

set_hostname() {
  local h=$1
  if [[ $(hostname) != "$h" ]]; then hostnamectl set-hostname "$h" 2>/dev/null || hostname "$h"; change "nom d'hôte -> $h"
  else ok "nom d'hôte $h"; fi
  write_if_changed /etc/hosts.sae51 644 <<EOF || true
$MGMT_CTRL srv-ctrl
$MGMT_CORE srv-core
$MGMT_UE srv-ue
$MGMT_DEST srv-dest
EOF
  if ! grep -q '# sae51-debut' /etc/hosts; then
    { echo '# sae51-debut'; cat /etc/hosts.sae51; echo '# sae51-fin'; } >>/etc/hosts; change "/etc/hosts complété"
  fi
}

apt_install() {  # apt_install paquet... (n'installe que ce qui manque)
  local missing=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    change "paquets installés : ${missing[*]}"
  else ok "paquets présents : $*"; fi
}

# --- Réseau ------------------------------------------------------------------
# Choix des interfaces (mémorisé dans /etc/sae51/interfaces.env pour rester stable) :
#  - IF_MGMT / IF_N2N3 / IF_N6 forcées par variable d'environnement, sinon
#  - VLAN_TRUNK=<if> : une seule carte en trunk 802.1Q -> <if>.10, <if>.20, <if>.30
#  - sinon automatique : l'interface qui porte la route par défaut (accès Internet)
#    n'est pas touchée ; les autres cartes sont prises dans l'ordre mgmt, N2/N3, N6.
#    S'il n'y a pas de carte dédiée à l'administration, l'adresse VLAN 10 est ajoutée
#    sur la carte Internet. SINGLE_NIC=1 autorise tout sur une seule carte (maquette).
phys_ifaces() {
  local i; for i in $(ls /sys/class/net); do
    [[ -e /sys/class/net/$i/device ]] && echo "$i"; done | sort -V
}
choose_ifaces() {  # choose_ifaces <besoins...> parmi mgmt n2n3 n6
  local need=("$@") state=$SAE51_ETC/interfaces.env
  if [[ -f $state && -z ${IF_REDETECT:-} ]]; then . "$state"; ok "interfaces mémorisées ($state)"; return; fi
  local uplink; uplink=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  if [[ -n ${VLAN_TRUNK:-} ]]; then
    IF_MGMT=${IF_MGMT:-$VLAN_TRUNK.$VLAN_MGMT}; IF_N2N3=${IF_N2N3:-$VLAN_TRUNK.$VLAN_RAN}; IF_N6=${IF_N6:-$VLAN_TRUNK.$VLAN_N6}
  else
    local free=() i n
    for i in $(phys_ifaces); do
      [[ $i == "$uplink" || $i == "${IF_MGMT:-}" || $i == "${IF_N2N3:-}" || $i == "${IF_N6:-}" ]] && continue; free+=("$i"); done
    local todo=0; for n in "${need[@]}"; do local v=IF_${n^^}; [[ -z ${!v:-} ]] && todo=$((todo+1)); done
    for n in "${need[@]}"; do
      local var=IF_${n^^}
      [[ -n ${!var:-} ]] && continue
      # cartes en nombre insuffisant : l'administration passe en priorité sur la carte Internet
      if [[ $n == mgmt && -n $uplink ]] && (( ${#free[@]} < todo )); then
        printf -v "$var" '%s' "$uplink"; warn "pas de carte dédiée à l'administration : VLAN 10 ajouté sur $uplink"
      elif ((${#free[@]})); then printf -v "$var" '%s' "${free[0]}"; free=("${free[@]:1}")
      elif [[ ${SINGLE_NIC:-0} == 1 && -n $uplink ]]; then printf -v "$var" '%s' "$uplink"; warn "SINGLE_NIC=1 : $n sur $uplink"
      else die "pas assez de cartes réseau pour '$n' (voir deploy/README.md, ou IF_${n^^}=<interface>, VLAN_TRUNK=<if>, SINGLE_NIC=1)"; fi
    done
  fi
  mkdir -p "$SAE51_ETC"
  { echo "# interfaces retenues le $(date '+%F %T') (supprimer ce fichier ou IF_REDETECT=1 pour refaire le choix)"
    echo "IF_MGMT=${IF_MGMT:-}"; echo "IF_N2N3=${IF_N2N3:-}"; echo "IF_N6=${IF_N6:-}"; echo "VLAN_TRUNK=${VLAN_TRUNK:-}"; } >"$state"
  change "interfaces choisies : mgmt=${IF_MGMT:-–} n2n3=${IF_N2N3:-–} n6=${IF_N6:-–} (Internet : ${uplink:-aucun})"
}

# net_lines_addr <interface> <adresse/préfixe> <vlan> : lignes du script réseau persistant
net_lines_addr() {
  local ifc=$1 addr=$2 vlan=$3
  if [[ $ifc == *.* ]]; then
    local parent=${ifc%.*}
    echo "ip link set dev $parent up"
    echo "ip link show $ifc >/dev/null 2>&1 || ip link add link $parent name $ifc type vlan id $vlan"
  fi
  echo "ip link set dev $ifc up"
  echo "ip addr replace $addr dev $ifc"
}

# install_net_service <contenu> : script /usr/local/sbin/sae51-net + service systemd (au démarrage, avant Docker)
install_net_service() {
  local body=$1
  write_if_changed /usr/local/sbin/sae51-net 755 <<EOF || true
#!/bin/sh
# Généré par deploy/$(basename "$0") - réseau SAE 51 (idempotent, rejoué à chaque démarrage)
set -e
$body
EOF
  if write_if_changed /etc/systemd/system/sae51-net.service 644 <<'EOF'; then systemctl daemon-reload; fi
[Unit]
Description=SAE51 - adressage des VLAN et interfaces 5G
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/sae51-net

[Install]
WantedBy=multi-user.target
EOF
  systemctl is-enabled -q sae51-net.service 2>/dev/null || { systemctl enable -q sae51-net.service; change "service sae51-net activé"; }
  /usr/local/sbin/sae51-net && ok "adressage appliqué"
}

set_sysctl() {  # set_sysctl <clé> <valeur>
  write_if_changed "/etc/sysctl.d/99-sae51-${1//./-}.conf" 644 <<<"$1 = $2" || true
  [[ $(sysctl -n "$1") == "$2" ]] || { sysctl -qw "$1=$2"; change "sysctl $1=$2"; }
}

load_sctp() {
  write_if_changed /etc/modules-load.d/sae51-sctp.conf 644 <<<"sctp" || true
  if grep -qw sctp /proc/modules 2>/dev/null || [[ -d /sys/module/sctp ]]; then ok "module sctp chargé"; return; fi
  if ! modprobe sctp 2>/dev/null; then
    # Ubuntu : le module est dans linux-modules-extra (Debian l'a dans le noyau standard)
    apt_install "linux-modules-extra-$(uname -r)" || true
    modprobe sctp || die "module SCTP indisponible : N2 impossible"
  fi
  change "module sctp chargé"
}

# --- Docker ------------------------------------------------------------------
# Tous les conteneurs sont en network_mode: host : Docker n'a pas besoin de gérer
# iptables. Sinon il passe la chaîne FORWARD en DROP, ce qui bloque le transfert
# ogstun -> N6 sur srv-core (l'UE s'attache mais aucun paquet ne passe).
configure_docker_daemon() {
  if write_if_changed /etc/docker/daemon.json 644 <<'EOF2'; then systemctl restart docker; fi
{
  "iptables": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" }
}
EOF2
  if command -v iptables >/dev/null && iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then
    iptables -P FORWARD ACCEPT; change "politique FORWARD remise à ACCEPT (laissée en DROP par Docker)"
  fi
}

# grant_sudo : sudo sans mot de passe pour l'utilisateur qui lance le script, afin que
# srv-ctrl puisse redéployer sans intervention (indicateur E1). NO_SUDOERS=1 pour l'éviter.
grant_sudo() {
  local u=${SUDO_USER:-}
  [[ -z $u || $u == root || ${NO_SUDOERS:-0} == 1 ]] && return 0
  write_if_changed "/etc/sudoers.d/sae51-$u" 440 <<<"$u ALL=(ALL) NOPASSWD: ALL" || true
  visudo -cqf "/etc/sudoers.d/sae51-$u" || { rm -f "/etc/sudoers.d/sae51-$u"; die "fichier sudoers invalide"; }
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker présent ($(docker --version | cut -d, -f1))"
  else
    apt_install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" \
      >/etc/apt/sources.list.d/docker.list
    apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  systemctl is-active -q docker || { systemctl enable -q --now docker; change "Docker démarré"; }
  configure_docker_daemon
}

# ensure_images <image...> : charge depuis le cache local si présent, sinon télécharge
ensure_images() {
  local img tar
  for img in "$@"; do
    if docker image inspect "$img" >/dev/null 2>&1; then ok "image $img présente"; continue; fi
    tar="$SAE51_CACHE/$(echo "$img" | tr '/:' '__').tar"
    if [[ -f $tar ]]; then docker load -qi "$tar" >/dev/null; change "image $img chargée depuis le cache"
    else docker pull -q "$img" >/dev/null || die "téléchargement de $img impossible (pas d'Internet ? préparer le cache : deploy/README.md)"
      change "image $img téléchargée"; fi
  done
  mkdir -p "$SAE51_LOG"
  for img in "$@"; do
    printf '%s %s\n' "$img" "$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$img")"
  done >"$SAE51_LOG/versions.txt"
}

# save_cache <image...> : prépare le cache hors ligne (option --save-cache des scripts)
save_cache() {
  mkdir -p "$SAE51_CACHE"; local img
  for img in "$@"; do docker save -o "$SAE51_CACHE/$(echo "$img" | tr '/:' '__').tar" "$img"; ok "cache : $img"; done
}

# compose_up <dossier> <configs_modifiées:0|1>
compose_up() {
  local dir=$1 changed=$2 before after
  before=$(docker compose --project-directory "$dir" ps -q --status running 2>/dev/null | sort || true)
  if [[ $changed == 1 ]]; then docker compose --project-directory "$dir" up -d --force-recreate --remove-orphans >/dev/null 2>&1
  else docker compose --project-directory "$dir" up -d --remove-orphans >/dev/null 2>&1; fi
  after=$(docker compose --project-directory "$dir" ps -q --status running 2>/dev/null | sort || true)
  if [[ $before != "$after" ]]; then change "conteneurs (re)démarrés dans $dir"; else ok "conteneurs déjà en place"; fi
  docker compose --project-directory "$dir" ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
}

# --- Secrets des abonnés (jamais dans Git) ----------------------------------
load_secrets() {  # load_secrets <generer:0|1>
  local f=$SAE51_ETC/secrets.env
  if [[ -z ${UE_K:-} || -z ${UE_OPC:-} ]] && [[ -f $f ]]; then . "$f"; fi
  if [[ -z ${UE_K:-} || -z ${UE_OPC:-} ]]; then
    if [[ $1 == 1 ]]; then
      UE_K=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); UE_OPC=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      warn "clés K/OPc générées : copier $f sur srv-ue (même chemin) avant de lancer srv-ue.sh"
    elif [[ -t 0 ]]; then
      read -rp "  Clé K de l'abonné (32 hex, voir $f sur srv-core) : " UE_K
      read -rp "  OPc de l'abonné (32 hex) : " UE_OPC
    else die "UE_K/UE_OPC absents : copier $f depuis srv-core"; fi
  fi
  [[ $UE_K =~ ^[0-9a-fA-F]{32}$ && $UE_OPC =~ ^[0-9a-fA-F]{32}$ ]] || die "UE_K et UE_OPC doivent faire 32 caractères hexadécimaux"
  mkdir -p "$SAE51_ETC"; chmod 700 "$SAE51_ETC"
  write_if_changed "$f" 600 <<EOF || true
# Secrets SAE 51 - NE PAS COMMITER
UE_K=$UE_K
UE_OPC=$UE_OPC
EOF
}

finish() {
  local dt=$(( $(date +%s) - T0 ))
  mkdir -p "$SAE51_LOG"
  printf '%s;%s;%ss;%s\n' "$(date '+%F %T')" "$(basename "$0")" "$dt" "$CHANGES" >>"$SAE51_LOG/executions.csv"
  log "Terminé en ${dt}s - changements appliqués : $CHANGES (0 = déjà conforme, indicateur E2)"
  log "Historique : $SAE51_LOG/executions.csv"
}
