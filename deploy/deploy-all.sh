#!/usr/bin/env bash
# =============================================================================
# deploy/deploy-all.sh - Reconstruction complète en UNE commande, depuis srv-ctrl
# Copie le code sur chaque VM par SSH, lance le script de la VM (ordre : srv-dest,
# srv-core, srv-ue), puis la recette de chemin (architecture/diag/diag-chemin.sh).
# Mesures enregistrées dans resultats/reconstructions.csv (E1 durée/succès, E2 changements).
#
#   bash deploy/deploy-all.sh --keys            # une fois : copie la clé SSH sur les VM
#   bash deploy/deploy-all.sh                   # reconstruction complète + recette
#   bash deploy/deploy-all.sh --only srv-core   # une seule VM
#   bash deploy/deploy-all.sh --save-cache      # + cache d'images sur chaque VM (mode hors ligne)
# À lancer en utilisateur normal (pas sudo). Secrets lus dans ~/.sae51/secrets.env.
# =============================================================================
set -uo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SSH_USER=${SSH_USER:-$(id -un)}
SECRETS=${SECRETS:-$HOME/.sae51/secrets.env}
SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
HOSTS=(srv-dest:192.168.10.40 srv-core:192.168.10.20 srv-ue:192.168.10.30)
RES=$REPO/resultats; mkdir -p "$RES/diag"

ONLY=""; EXTRA=""; KEYS=0
while (($#)); do case $1 in
  --keys) KEYS=1;; --save-cache) EXTRA=--save-cache;; --only) ONLY=$2; shift;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;; *) echo "option inconnue : $1"; exit 2;; esac; shift; done

if (( KEYS )); then
  for hp in "${HOSTS[@]}"; do ssh-copy-id "${SSH_OPTS[@]}" "$SSH_USER@${hp#*:}"; done; exit 0
fi
[[ -f $SECRETS ]] || { echo "Secrets absents ($SECRETS) : lancer d'abord sudo bash deploy/srv-ctrl.sh"; exit 1; }

T0=$(date +%s); LINE="$(date '+%F %T')"; FAIL=0
for hp in "${HOSTS[@]}"; do
  h=${hp%%:*}; ip=${hp#*:}
  [[ -n $ONLY && $ONLY != "$h" ]] && continue
  echo; echo "==================== $h ($ip) ===================="
  t=$(date +%s)
  # 1. copie du code (et des secrets, supprimés après usage) dans ~/sae51 sur la VM
  tmp=$(mktemp -d); cp -r "$REPO/deploy" "$REPO/architecture" "$tmp/"; install -m 600 "$SECRETS" "$tmp/secrets.env"
  if ! tar -C "$tmp" -czf - . | ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" 'rm -rf ~/sae51 && mkdir -p ~/sae51 && tar -xzf - -C ~/sae51'; then
    rm -rf "$tmp"; echo "!! $h injoignable en SSH"; FAIL=1; LINE+=";$h:injoignable"; continue; fi
  rm -rf "$tmp"
  # 2. exécution du script de la VM (sudo peut demander le mot de passe au tout premier passage)
  ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$ip" \
    "cd ~/sae51 && set -a && . ./secrets.env && set +a && rm -f secrets.env && sudo --preserve-env=UE_K,UE_OPC bash deploy/$h.sh $EXTRA"
  rc=$?
  ch=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "tail -1 /var/log/sae51/executions.csv 2>/dev/null | cut -d';' -f4")
  dt=$(( $(date +%s) - t ))
  echo "-> $h : code $rc, ${dt}s, ${ch:-?} changement(s)"
  LINE+=";$h:rc=$rc:${dt}s:chg=${ch:-?}"
  (( rc == 0 )) || FAIL=1
done

echo; echo "==================== Recette du chemin ===================="
DIAG_LOG="$RES/diag/diag-$(date +%Y%m%d-%H%M%S).log"
SSH_USER=$SSH_USER bash "$REPO/architecture/diag/diag-chemin.sh" | tee "$DIAG_LOG"
DIAG=${PIPESTATUS[0]}
TOTAL=$(( $(date +%s) - T0 ))
SUCCES=$([[ $FAIL == 0 && $DIAG == 0 ]] && echo oui || echo non)

[[ -f $RES/reconstructions.csv ]] || echo "date;details_par_hote...;duree_totale;code_recette;succes" >"$RES/reconstructions.csv"
echo "$LINE;total=${TOTAL}s;diag=$DIAG;$SUCCES" >>"$RES/reconstructions.csv"
echo
echo "Reconstruction : ${TOTAL}s - recette : code $DIAG - succès : $SUCCES"
echo "Mesure ajoutée à resultats/reconstructions.csv, journal de recette : ${DIAG_LOG#$REPO/}"
[[ $SUCCES == oui ]]
