#!/usr/bin/env bash
# =============================================================================
#  ks5-setup.sh — Mise en place d'un serveur OVH Kimsufi KS-5 sous Proxmox VE
#
#  Hôte     dépôts sans abonnement, mises à jour, SSH par clé uniquement,
#           fail2ban, pare-feu Proxmox, interface 8006 fermée côté Internet,
#           correctifs de sécurité automatiques, alertes par mail (disques,
#           sauvegardes, espace), plafond du cache ZFS, stockage ZFS des VM
#  Réseau   pont privé NAT (vmbr1) ; seuls 80/443 entrent, vers le routeur web
#  Web      conteneur HAProxy : aiguillage des domaines vers les VM sans déchiffrer
#           (chaque VM garde ses certificats Let's Encrypt, IP réelle par protocole PROXY)
#  Admin    tunnels SSH vers l'interface Proxmox, Coolify et les VM (rien d'autre exposé)
#  Invités  modèle Ubuntu cloud-init, VM Coolify / Kobo / serveurs gérés,
#           pare-feu par invité (isolation entre VM), sauvegarde quotidienne
#
#  En une ligne, en root sur le serveur (session SSH interactive) :
#    curl -fsSL https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh | bash
#  Options après « bash -s -- » (ex. … | bash -s -- -p), ou bash ks5-setup.sh [options] :
#    -c  fichier de paramètres (défaut : ks5.conf du dossier courant ou du script)
#    -y  aucune question : valeurs du fichier, contrôles automatiques
#    -p  plan seulement : détection, questions et récapitulatif, rien n'est modifié
#  Relançable : ce qui existe déjà est conservé.
# =============================================================================
# Tout le script est dans un bloc : bash le lit en entier avant de l'exécuter, ce qui protège
# l'usage « curl … | bash » contre un téléchargement interrompu.
{
set -Eeuo pipefail
umask 077

KS5_URL="https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh"
SELF="${BASH_SOURCE[0]:-}"
if [[ -n $SELF && -f $SELF ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"; SELF="${SCRIPT_DIR}/$(basename "$SELF")"
else
  SCRIPT_DIR="$PWD"; SELF=""   # lu depuis un tuyau (curl … | bash)
fi
CONF_FILE="${SCRIPT_DIR}/ks5.conf"
ASSUME_YES=0
PLAN_ONLY=0

usage() {
  cat <<EOF
Usage : curl -fsSL ${KS5_URL} | bash -s -- [options]
   ou : bash ks5-setup.sh [options]
  -c  fichier de paramètres (défaut : ks5.conf du dossier courant ou du script)
  -y  aucune question : valeurs du fichier, contrôles automatiques
  -p  plan seulement : détection, questions et récapitulatif, rien n'est modifié
EOF
}

# Commande pour relancer avec les réponses enregistrées
rerun_cmd() {
  if [[ -n $SELF ]]; then echo "bash ${SELF} $*"; else echo "curl -fsSL ${KS5_URL} | bash -s -- $*"; fi
}

while getopts ":c:yph" opt; do
  case "$opt" in
    c) CONF_FILE="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    p) PLAN_ONLY=1 ;;
    h) usage; exit 0 ;;
    :) echo "L'option -$OPTARG attend une valeur." >&2; exit 1 ;;
    *) echo "Option inconnue : -$OPTARG" >&2; usage >&2; exit 1 ;;
  esac
done
# Les questions lisent le terminal (/dev/tty) ; aucune commande ne doit lire l'entrée standard,
# qui est le script lui-même avec « curl … | bash ».
exec </dev/null

info() { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[ATTN]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[ERR ]\e[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
trap 'die "Échec à la ligne $LINENO : $BASH_COMMAND"' ERR

[[ $EUID -eq 0 ]] || die "Lancer le script en root."

LOG_FILE="/var/log/ks5-setup.log"
[[ -e "$LOG_FILE" ]] || install -m 600 /dev/null "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== ks5-setup.sh — %s =====\n' "$(date '+%F %T')"

if (( ASSUME_YES == 0 )) && ! { : </dev/tty; } 2>/dev/null; then
  die "Aucun terminal interactif : se connecter avec « ssh root@serveur » (ou ssh -t) puis relancer, ou utiliser -y."
fi

# -----------------------------------------------------------------------------
# Questions
# -----------------------------------------------------------------------------
# ask VAR "Question" "défaut" : Entrée garde la valeur proposée, « - » vide le champ
ask() {
  local __v=$1 __q=$2 __d=${3-} __a=""
  if (( ASSUME_YES )); then printf -v "$__v" '%s' "$__d"; return 0; fi
  read -r -p "  ${__q} [${__d}] : " __a </dev/tty || true
  if [[ $__a == "-" ]]; then __a=""; elif [[ -z $__a ]]; then __a=$__d; fi
  printf -v "$__v" '%s' "$__a"
}

ask_int() {  # ask_int VAR "Question" défaut min max
  local __v=$1 __q=$2 __d=$3 __min=$4 __max=$5 __x
  while :; do
    ask __x "$__q" "$__d"
    if [[ $__x =~ ^[0-9]+$ ]] && (( 10#$__x >= __min && 10#$__x <= __max )); then
      printf -v "$__v" '%d' "$((10#$__x))"; return 0
    fi
    if (( ASSUME_YES )); then die "Valeur invalide pour « ${__q} » : « ${__x} » (attendu ${__min} à ${__max})."; fi
    warn "Nombre entier entre ${__min} et ${__max} attendu."
  done
}

ask_choice() {  # ask_choice VAR "Question" défaut "choix1 choix2 …"
  local __v=$1 __q=$2 __d=$3 __c=$4 __x
  while :; do
    ask __x "${__q} (${__c// /, })" "$__d"
    if [[ " $__c " == *" $__x "* ]]; then printf -v "$__v" '%s' "$__x"; return 0; fi
    if (( ASSUME_YES )); then die "Valeur invalide pour « ${__q} » : « ${__x} »."; fi
    warn "Choisir parmi : ${__c}"
  done
}

ask_match() {  # ask_match VAR "Question" défaut regex "message d'erreur"
  local __v=$1 __q=$2 __d=$3 __re=$4 __msg=$5 __x
  while :; do
    ask __x "$__q" "$__d"
    if [[ $__x =~ $__re ]]; then printf -v "$__v" '%s' "$__x"; return 0; fi
    if (( ASSUME_YES )); then die "Valeur invalide pour « ${__q} » : « ${__x} »."; fi
    warn "$__msg"
  done
}

ask_yn() {  # ask_yn "Question" o|n → code 0 si oui
  local __d=$2 __x
  if (( ASSUME_YES )); then [[ $__d == o ]]; return; fi
  while :; do
    read -r -p "  $1 [$([[ $__d == o ]] && echo O/n || echo o/N)] : " __x </dev/tty || true
    __x=${__x:-$__d}
    case "${__x,,}" in
      o|oui|y|yes) return 0 ;;
      n|non|no) return 1 ;;
    esac
  done
}

ask_secret() {  # ask_secret VAR "Question" : saisie masquée, jamais journalisée
  local __v=$1 __x=""
  if [[ -n ${!__v} ]]; then info "$2 : fourni par le fichier de paramètres."; return 0; fi
  if (( ASSUME_YES )); then return 0; fi
  read -r -s -p "  $2 (Entrée = plus tard) : " __x </dev/tty || true
  echo
  printf -v "$__v" '%s' "$__x"
}

# put MODE CHEMIN < contenu : écrit un fichier système avec des droits explicites
put() {
  local mode=$1 dest=$2 tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install -D -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

# Contenu (champ « content ») d'un stockage dans /etc/pve/storage.cfg
storage_content() {
  awk -v s="$1" '/^[a-z]+:/ {cur=$2} cur==s && $1=="content" {print $2}' /etc/pve/storage.cfg
}

ensure_content() {  # ensure_content STOCKAGE type…
  local st=$1 cur new c
  shift
  cur="$(storage_content "$st")"
  new=$cur
  for c in "$@"; do
    if [[ ",${new}," != *",${c},"* ]]; then new="${new:+${new},}${c}"; fi
  done
  if [[ $new != "$cur" ]]; then pvesm set "$st" --content "$new"; fi
}

# -----------------------------------------------------------------------------
# Référence KS-5 (catalogue public OVH, offre 24sk50 « KS-5 ») : valeurs proposées
# quand la détection ne donne rien. Options de commande :
#   RAM    32 ou 64 Go DDR4 ECC 2400
#   disques 2×2 To HDD soft RAID (défaut) · 3×4 To HDD soft RAID · 2×450 Go NVMe
#           soft RAID · 2×1,2 To NVMe soft RAID · 3×960 Go SSD RAID matériel
#   réseau 500 Mbit/s, 1 IPv4 + IPv6, anti-DDoS standard, pas de KVM/IPMI
# -----------------------------------------------------------------------------
KS5_CPU="Xeon E3-1270 v6, 4 cœurs / 8 threads"
KS5_THREADS=8
KS5_RAM_GB=64
KS5_DISK_TYPE="hdd"
KS5_RAID="raid1"
KS5_USABLE_GB=1950

# -----------------------------------------------------------------------------
# Paramètres par défaut (surchargés par le fichier de paramètres)
# -----------------------------------------------------------------------------
TIMEZONE="Africa/Bamako"
ADMIN_EMAIL=""
SMTP_HOST=""; SMTP_PORT=587; SMTP_MODE="starttls"; SMTP_USER=""; SMTP_PASSWORD=""; SMTP_FROM=""
SSH_PORT=22
SSH_ALLOW_FROM=""
ENABLE_FIREWALL=1
VM_ISOLATION=1
GUI_LAN_ONLY=1
ROLLBACK_DELAY=300
HW_THREADS=""; HW_RAM_GB=""; HW_DISK_TYPE=""; HW_RAID=""; HW_USABLE_GB=""
ZFS_ARC_MAX_GB=""
HOST_RESERVE_GB=3
DISK_BUDGET_PCT=75
LAN_BRIDGE="vmbr1"
LAN_PREFIX="10.10.10"
DNS_SERVERS="1.1.1.1 9.9.9.9"
STORAGE=""
VMDATA_DATASET="vmdata"
TEMPLATE_ID=9000
UBUNTU_RELEASE="noble"
CI_USER="ubuntu"
WEB_DOMAIN="uninef.org"
WEB_DEFAULT_VM=""
WEB_ROUTES=()
BACKUP_STORAGE="local"
BACKUP_SCHEDULE="02:00"
BACKUP_KEEP_DAILY=3
BACKUP_KEEP_WEEKLY=2
DISK_ALERT_PCT=80
CT_ID=100; CT_NAME="entree"; CT_IP_SUFFIX=10; CT_CORES=1; CT_MEM_MB=512; CT_DISK_GB=8
VMS=(
  "101|coolify|2|4|50|11|coolify|2"
  "102|kobo|4|12|300|12|kobo|3"
  "103|uninef-prod|6|18|500|13|managed|3"
  "105|perso-tests|4|10|250|15|managed|5"
)
VM_FW_EXTRA=()

if [[ -f "$CONF_FILE" ]]; then
  read -r conf_uid conf_mode < <(stat -c '%u %a' "$CONF_FILE")
  [[ $conf_uid == 0 ]] || die "${CONF_FILE} doit appartenir à root (il est exécuté par le script)."
  if (( 8#$conf_mode & 8#022 )); then die "${CONF_FILE} est modifiable par d'autres comptes : chmod 600 ${CONF_FILE}"; fi
  # shellcheck source=ks5.conf
  source "$CONF_FILE"
  if [[ -n $SMTP_PASSWORD ]]; then chmod 600 "$CONF_FILE"; fi
  info "Paramètres lus dans ${CONF_FILE}"
else
  info "Pas de fichier de paramètres : valeurs du KS-5, modifiables pendant les questions."
fi

ROLLBACK_DELAY=$(( ROLLBACK_DELAY < 120 ? 120 : ROLLBACK_DELAY ))
KEYS_DIR="/root/ks5-keys"
BACKUP_DIR="/root/ks5-backups"
SNIPPETS_DIR="/var/lib/vz/snippets"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-ks5-hardening.conf"
ROLLBACK_SCRIPT="/root/ks5-rollback.sh"
ANSWERS_FILE="/root/ks5-reponses.conf"
SUMMARY_FILE="/root/ks5-resume.txt"
export DEBIAN_FRONTEND=noninteractive
CURL=(curl -fsSL --proto '=https' --tlsv1.2 --retry 3)

# -----------------------------------------------------------------------------
# 0. Vérifications préalables
# -----------------------------------------------------------------------------
step "Vérifications préalables"
command -v pveversion >/dev/null \
  || die "Proxmox VE n'est pas installé (espace client OVH › Réinstaller › modèle « Proxmox VE »)."
PVE_VER="$(pveversion | awk -F/ '{print $2}')"
PVE_MAJOR="${PVE_VER%%.*}"
if ! [[ $PVE_MAJOR =~ ^[0-9]+$ ]] || (( PVE_MAJOR < 8 )); then
  die "Proxmox VE 8 ou plus requis (trouvé : ${PVE_VER})."
fi
# shellcheck source=/dev/null
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
NODE="$(hostname)"

WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n "$WAN_IF" ]] || die "Interface réseau publique introuvable (pas de route par défaut)."
PUBLIC_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
[[ -n "$PUBLIC_IP" ]] || die "Adresse IPv4 publique introuvable sur ${WAN_IF}."

KEY_REGEX='(ssh-(rsa|ed25519)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+'
grep -Eq "$KEY_REGEX" /root/.ssh/authorized_keys 2>/dev/null \
  || die "Aucune clé SSH dans /root/.ssh/authorized_keys : l'ajouter avant (les mots de passe SSH vont être refusés)."

"${CURL[@]}" --max-time 20 -o /dev/null https://download.proxmox.com/ \
  || die "Pas d'accès HTTPS sortant (download.proxmox.com)."
ok "Proxmox VE ${PVE_VER} (Debian ${CODENAME}), nœud ${NODE}, IP publique ${PUBLIC_IP} sur ${WAN_IF}."

# -----------------------------------------------------------------------------
# 1. Détection du matériel et du stockage
# -----------------------------------------------------------------------------
DET_CPU="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
DET_THREADS="$(nproc --all)"
DET_RAM_GB="$(awk '/^MemTotal/ {printf "%d", $2/1048576 + 0.5}' /proc/meminfo)"

DISKS_TXT=""; n_hdd=0; n_ssd=0; n_nvme=0
while read -r dtype dname drota dsize dtran; do
  [[ $dtype == disk ]] || continue
  if [[ $dname == nvme* || $dtran == nvme ]]; then kind="NVMe"; n_nvme=$((n_nvme + 1))
  elif [[ $drota == 1 ]]; then kind="HDD"; n_hdd=$((n_hdd + 1))
  else kind="SSD"; n_ssd=$((n_ssd + 1))
  fi
  DISKS_TXT+="${dname} ${dsize} ${kind}, "
done < <(lsblk -dn -o TYPE,NAME,ROTA,SIZE,TRAN 2>/dev/null || true)
DISKS_TXT="${DISKS_TXT%, }"
if (( n_hdd > 0 )); then DET_DISK_TYPE="hdd"
elif (( n_ssd > 0 )); then DET_DISK_TYPE="ssd"
elif (( n_nvme > 0 )); then DET_DISK_TYPE="nvme"
else DET_DISK_TYPE=""
fi

ZPOOLS="$(zpool list -H -o name 2>/dev/null || true)"
DET_RAID=""
if [[ -n $ZPOOLS ]]; then
  first_pool="$(head -1 <<<"$ZPOOLS")"
  pool_status="$(zpool status "$first_pool" 2>/dev/null || true)"
  n_mirror="$(grep -c 'mirror-' <<<"$pool_status" || true)"
  if (( n_mirror > 1 )); then DET_RAID="raid10"
  elif (( n_mirror == 1 )); then DET_RAID="raid1"
  elif grep -q 'raidz2' <<<"$pool_status"; then DET_RAID="raid6"
  elif grep -q 'raidz' <<<"$pool_status"; then DET_RAID="raid5"
  else DET_RAID="aucun"
  fi
elif grep -q '^md' /proc/mdstat 2>/dev/null; then
  DET_RAID="$(awk '/^md/ {print $4; exit}' /proc/mdstat)"
elif lspci 2>/dev/null | grep -qiE 'raid|megaraid|smart array'; then
  DET_RAID="hw"
fi
case "$DET_RAID" in raid1|raid10|raid5|raid6|hw|aucun|"") ;; *) DET_RAID="" ;; esac

# Stockages possibles pour les disques de VM : existants (actifs) ou à créer sur un pool ZFS
CAND_NAMES=(); CAND_TYPES=(); CAND_GB=(); CAND_POOLS=()
while read -r sname stype sstatus stotal _; do
  [[ $sstatus == active ]] || continue
  CAND_NAMES+=("$sname"); CAND_TYPES+=("$stype"); CAND_GB+=("$(( stotal * 1024 / 1000000000 ))")
  if [[ $stype == zfspool ]]; then
    CAND_POOLS+=("$(awk -v s="$sname" '/^[a-z]+:/ {cur=$2} cur==s && $1=="pool" {print $2}' /etc/pve/storage.cfg)")
  else
    CAND_POOLS+=("")
  fi
done < <(pvesm status --content images 2>/dev/null | awk 'NR>1')
for pool in $ZPOOLS; do
  used=0
  for p in "${CAND_POOLS[@]}"; do
    if [[ ${p%%/*} == "$pool" ]]; then used=1; fi
  done
  if (( used == 0 )) && [[ " ${CAND_NAMES[*]} " != *" ${VMDATA_DATASET} "* ]]; then
    CAND_NAMES+=("$VMDATA_DATASET"); CAND_TYPES+=("zfs-nouveau"); CAND_POOLS+=("${pool}/${VMDATA_DATASET}")
    CAND_GB+=("$(zfs get -Hp -o value used,available "$pool" | awk '{s+=$1} END {printf "%d", s/1e9}')")
    break
  fi
done
(( ${#CAND_NAMES[@]} > 0 )) || die "Aucun stockage utilisable pour les disques de VM (voir « pvesm status »)."

# Choix par défaut : ZFS existant > nouveau dataset ZFS > LVM-thin > premier trouvé
best_storage() {
  local want i
  for want in zfspool zfs-nouveau lvmthin; do
    for i in "${!CAND_NAMES[@]}"; do
      if [[ ${CAND_TYPES[$i]} == "$want" ]]; then echo "${CAND_NAMES[$i]}"; return 0; fi
    done
  done
  echo "${CAND_NAMES[0]}"
}

# -----------------------------------------------------------------------------
# 2. Matériel : référence KS-5, détection, confirmation
# -----------------------------------------------------------------------------
step "Matériel"
printf '  %-11s %-40s %s\n' "" "Référence KS-5 (OVH)" "Détecté sur ce serveur"
printf '  %-11s %-40s %s\n' "Processeur" "$KS5_CPU" "${DET_CPU:-?} (${DET_THREADS} threads)"
printf '  %-11s %-40s %s\n' "Mémoire" "32 ou 64 Go DDR4 ECC" "${DET_RAM_GB} Go utilisables"
printf '  %-11s %-40s %s\n' "Disques" "2 × 2 To HDD (défaut de l'offre)" "${DISKS_TXT:-?}"
printf '  %-11s %-40s %s\n' "Redondance" "soft RAID 1 / ZFS miroir" "${DET_RAID:-inconnue}"
echo
info "Entrée garde la valeur proposée (détectée, sinon référence KS-5)."
ask_int HW_THREADS "Threads processeur" "${HW_THREADS:-${DET_THREADS:-$KS5_THREADS}}" 1 1024
ask_int HW_RAM_GB "Mémoire vive (Go)" "${HW_RAM_GB:-${DET_RAM_GB:-$KS5_RAM_GB}}" 8 4096
ask_choice HW_DISK_TYPE "Type de disques des VM" "${HW_DISK_TYPE:-${DET_DISK_TYPE:-$KS5_DISK_TYPE}}" "hdd ssd nvme"
ask_choice HW_RAID "Redondance" "${HW_RAID:-${DET_RAID:-$KS5_RAID}}" "raid1 raid10 raid5 raid6 hw aucun"
if [[ $HW_RAID == aucun ]]; then
  warn "Sans redondance, la panne d'un disque perd toutes les VM. Réinstaller avec RAID 1 est fortement conseillé."
  ask_yn "Continuer sans redondance ?" n || die "Arrêt : réinstaller Proxmox en RAID 1 depuis l'espace client OVH."
fi

step "Stockage des disques de VM"
for i in "${!CAND_NAMES[@]}"; do
  case "${CAND_TYPES[$i]}" in
    zfs-nouveau) desc="à créer : dataset ${CAND_POOLS[$i]} (ZFS, allocation à la demande, lz4)" ;;
    zfspool)     desc="ZFS existant (${CAND_POOLS[$i]})" ;;
    lvmthin)     desc="LVM-thin" ;;
    dir)         desc="répertoire (fichiers qcow2)" ;;
    *)           desc="${CAND_TYPES[$i]}" ;;
  esac
  printf '  %-12s %-6s Go  %s\n' "${CAND_NAMES[$i]}" "${CAND_GB[$i]}" "$desc"
done
ask_choice STORAGE "Stockage des VM" "${STORAGE:-$(best_storage)}" "${CAND_NAMES[*]}"
for i in "${!CAND_NAMES[@]}"; do
  if [[ ${CAND_NAMES[$i]} == "$STORAGE" ]]; then
    STORAGE_TYPE="${CAND_TYPES[$i]}"; STORAGE_POOL="${CAND_POOLS[$i]}"; STORAGE_GB="${CAND_GB[$i]}"
  fi
done
(( STORAGE_GB > 0 )) || STORAGE_GB=$KS5_USABLE_GB
case "$STORAGE_TYPE" in dir|nfs|cifs|glusterfs) DISK_FORMAT="qcow2" ;; *) DISK_FORMAT="raw" ;; esac
if [[ $DISK_FORMAT == qcow2 ]]; then
  warn "Stockage de type fichier : les VM seront des fichiers qcow2 (moins performant qu'un volume ZFS ou LVM-thin)."
fi
ask_int HW_USABLE_GB "Capacité utile du stockage (Go)" "${HW_USABLE_GB:-${STORAGE_GB:-$KS5_USABLE_GB}}" 50 1000000

USES_ZFS=0
[[ -n $ZPOOLS ]] && USES_ZFS=1
if (( USES_ZFS )); then
  if [[ -z $ZFS_ARC_MAX_GB ]]; then
    # Disques lents : plus de cache. Bornes 2–16 Go, comme l'installateur Proxmox.
    if [[ $HW_DISK_TYPE == hdd ]]; then ZFS_ARC_MAX_GB=$(( HW_RAM_GB / 8 )); else ZFS_ARC_MAX_GB=$(( HW_RAM_GB / 16 )); fi
    ZFS_ARC_MAX_GB=$(( ZFS_ARC_MAX_GB < 2 ? 2 : (ZFS_ARC_MAX_GB > 16 ? 16 : ZFS_ARC_MAX_GB) ))
  fi
  ask_int ZFS_ARC_MAX_GB "Plafond du cache ZFS (Go)" "$ZFS_ARC_MAX_GB" 1 $(( HW_RAM_GB / 2 ))
else
  ZFS_ARC_MAX_GB=0
fi

# -----------------------------------------------------------------------------
# 3. Paramètres
# -----------------------------------------------------------------------------
step "Paramètres"
info "Champs facultatifs : « - » pour laisser vide."
while :; do
  ask TIMEZONE "Fuseau horaire" "$TIMEZONE"
  [[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] && break
  (( ASSUME_YES )) && die "Fuseau horaire inconnu : ${TIMEZONE}"
  warn "Fuseau inconnu (exemples : Africa/Bamako, Europe/Paris)."
done
ask_match ADMIN_EMAIL "Mail de l'administrateur (pannes disque, sauvegardes, espace)" "$ADMIN_EMAIL" \
  '^([^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+)?$' "Adresse mail invalide."
[[ -n $ADMIN_EMAIL ]] || warn "Sans adresse mail, une panne de disque passera inaperçue."
if [[ -n $ADMIN_EMAIL ]] && ask_yn "Envoyer les alertes par un relais SMTP authentifié (Brevo, etc.) ?" "$([[ -n $SMTP_HOST ]] && echo o || echo n)"; then
  ask_match SMTP_HOST "Serveur SMTP" "${SMTP_HOST:-smtp-relay.brevo.com}" '^[A-Za-z0-9.-]+$' "Nom d'hôte invalide."
  ask_int SMTP_PORT "Port SMTP" "$SMTP_PORT" 1 65535
  ask_choice SMTP_MODE "Chiffrement" "$SMTP_MODE" "starttls tls"
  ask SMTP_USER "Identifiant SMTP" "$SMTP_USER"
  ask_secret SMTP_PASSWORD "Mot de passe ou clé SMTP"
  ask_match SMTP_FROM "Adresse d'expédition (domaine validé chez le relais)" "${SMTP_FROM:-$ADMIN_EMAIL}" \
    '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' "Adresse mail invalide."
else
  SMTP_HOST=""
fi

ask_int SSH_PORT "Port SSH de l'hôte" "$SSH_PORT" 1 65535
ask_match SSH_ALLOW_FROM "Sources autorisées en SSH public (CIDR séparés par des espaces, vide = toutes)" "$SSH_ALLOW_FROM" \
  '^([0-9a-fA-F:.]+(/[0-9]{1,3})?( +[0-9a-fA-F:.]+(/[0-9]{1,3})?)*)?$' "Liste d'adresses ou de réseaux CIDR attendue."
ask_match LAN_PREFIX "Réseau privé des VM (3 premiers octets, en /24)" "$LAN_PREFIX" \
  '^(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}$' "Réseau privé attendu (10.x.y, 172.16-31.y, 192.168.y)."
ask_match UBUNTU_RELEASE "Ubuntu des VM (noble = 24.04 LTS, resolute = 26.04 LTS)" "$UBUNTU_RELEASE" \
  '^[a-z]+$' "Nom de version Ubuntu attendu (ex. noble)."
ask_match BACKUP_SCHEDULE "Heure de la sauvegarde quotidienne" "$BACKUP_SCHEDULE" \
  '^([01][0-9]|2[0-3]):[0-5][0-9]$' "Format HH:MM attendu."
ask_int BACKUP_KEEP_DAILY "Sauvegardes locales quotidiennes conservées" "$BACKUP_KEEP_DAILY" 1 14
ask_int BACKUP_KEEP_WEEKLY "Sauvegardes locales hebdomadaires conservées" "$BACKUP_KEEP_WEEKLY" 0 8
ask_match WEB_DOMAIN "Domaine des sites publics (routes par défaut du routeur web)" "$WEB_DOMAIN" \
  '^[a-z0-9.-]+\.[a-z]{2,}$' "Nom de domaine attendu (ex. uninef.org)."

LAN_GW="${LAN_PREFIX}.1"
LAN_CIDR="${LAN_PREFIX}.0/24"
CT_IP="${LAN_PREFIX}.${CT_IP_SUFFIX}"

# -----------------------------------------------------------------------------
# 4. Plan des VM et budget de ressources
#    Format : "ID|nom|vCPU|RAM_Go|Disque_Go|IP(dernier octet)|profil|ordre_démarrage"
# -----------------------------------------------------------------------------
PROFILES="coolify kobo managed base"

validate_plan() {
  local spec id name cores ram disk oct profile order ids=" " octs=" ${CT_IP_SUFFIX} 1 " names=" "
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
    [[ $id =~ ^[0-9]+$ && $cores =~ ^[0-9]+$ && $ram =~ ^[0-9]+$ && $disk =~ ^[0-9]+$ && $oct =~ ^[0-9]+$ && $order =~ ^[0-9]+$ ]] \
      || die "Entrée VMS invalide : « ${spec} »."
    [[ $name =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "Nom de VM invalide : « ${name} » (minuscules, chiffres, tirets)."
    [[ " $PROFILES " == *" $profile "* ]] || die "Profil inconnu pour ${name} : ${profile} (${PROFILES})."
    (( id >= 100 && id != CT_ID && id != TEMPLATE_ID )) || die "Identifiant de VM invalide ou déjà pris : ${id}."
    (( oct >= 2 && oct <= 254 )) || die "Adresse invalide pour ${name} : ${LAN_PREFIX}.${oct}."
    [[ $ids != *" $id "* ]] || die "Identifiant ${id} utilisé deux fois."
    [[ $octs != *" $oct "* ]] || die "Adresse ${LAN_PREFIX}.${oct} utilisée deux fois (ou réservée)."
    [[ $names != *" $name "* ]] || die "Nom ${name} utilisé deux fois."
    ids+="$id "; octs+="$oct "; names+="$name "
  done
}

show_plan() {
  local spec id name cores ram disk oct profile order
  printf '\n  %-6s %-18s %5s %7s %10s  %-15s %s\n' "ID" "Nom" "vCPU" "RAM Go" "Disque Go" "Adresse" "Profil"
  printf '  %-6s %-18s %5s %7s %10s  %-15s %s\n' "$CT_ID" "${CT_NAME} (LXC)" "$CT_CORES" "$(( (CT_MEM_MB + 1023) / 1024 ))" "$CT_DISK_GB" "$CT_IP" "routeur web"
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
    printf '  %-6s %-18s %5s %7s %10s  %-15s %s\n' "$id" "$name" "$cores" "$ram" "$disk" "${LAN_PREFIX}.${oct}" "$profile"
  done
  echo
}

compute_budget() {
  local spec id name cores ram disk oct profile order
  T_CORES=0; T_RAM=0; T_DISK=0; MAX_CORES=0
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
    T_CORES=$((T_CORES + cores)); T_RAM=$((T_RAM + ram)); T_DISK=$((T_DISK + disk))
    MAX_CORES=$(( cores > MAX_CORES ? cores : MAX_CORES ))
  done
  CT_RAM_GB=$(( (CT_MEM_MB + 1023) / 1024 ))
  RAM_AVAIL=$(( HW_RAM_GB - HOST_RESERVE_GB - ZFS_ARC_MAX_GB - CT_RAM_GB ))
  DISK_AVAIL=$(( HW_USABLE_GB * DISK_BUDGET_PCT / 100 - CT_DISK_GB - 10 ))
}

check_budget() {
  local over=0
  compute_budget
  printf '  Mémoire  %4d Go demandés / %4d Go disponibles (%d − hôte %d − cache ZFS %d − conteneur %d)\n' \
    "$T_RAM" "$RAM_AVAIL" "$HW_RAM_GB" "$HOST_RESERVE_GB" "$ZFS_ARC_MAX_GB" "$CT_RAM_GB"
  printf '  Disque   %4d Go alloués  / %4d Go disponibles (%d %% de %d Go : marge pour sauvegardes locales et ZFS)\n' \
    "$T_DISK" "$DISK_AVAIL" "$DISK_BUDGET_PCT" "$HW_USABLE_GB"
  printf '  vCPU     %4d pour %d threads\n' "$T_CORES" "$HW_THREADS"
  if (( T_RAM > RAM_AVAIL )); then warn "Mémoire insuffisante : risque d'arrêt brutal de VM (OOM)."; over=1; fi
  if (( T_DISK > DISK_AVAIL )); then warn "Disques de VM trop grands pour le stockage."; over=1; fi
  if (( MAX_CORES > HW_THREADS )); then warn "Une VM demande plus de vCPU que de threads disponibles."; over=1; fi
  if (( T_CORES > HW_THREADS * 4 )); then warn "Plus de 4 vCPU par thread : performances dégradées sous charge."; fi
  return "$over"
}

autoscale_plan() {
  local spec id name cores ram disk oct profile order new=()
  compute_budget
  (( RAM_AVAIL >= ${#VMS[@]} )) || die "Pas assez de mémoire pour ${#VMS[@]} VM : en retirer."
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
    if (( T_RAM > RAM_AVAIL )); then ram=$(( ram * RAM_AVAIL / T_RAM )); ram=$(( ram < 1 ? 1 : ram )); fi
    if (( T_DISK > DISK_AVAIL )); then disk=$(( disk * DISK_AVAIL / T_DISK / 10 * 10 )); disk=$(( disk < 10 ? 10 : disk )); fi
    cores=$(( cores > HW_THREADS ? HW_THREADS : cores ))
    new+=("${id}|${name}|${cores}|${ram}|${disk}|${oct}|${profile}|${order}")
  done
  VMS=("${new[@]}")
}

next_free() {  # next_free id|oct
  local spec id oct n used
  if [[ $1 == id ]]; then n=101; else n=11; fi
  while :; do
    used=0
    for spec in "${VMS[@]}"; do
      IFS='|' read -r id _ _ _ _ oct _ _ <<<"$spec"
      if [[ $1 == id && $n == "$id" ]] || [[ $1 == oct && $n == "$oct" ]]; then used=1; fi
    done
    if [[ $1 == id ]] && { (( n == CT_ID || n == TEMPLATE_ID )) || qm status "$n" >/dev/null 2>&1 || pct status "$n" >/dev/null 2>&1; }; then used=1; fi
    if [[ $1 == oct ]] && (( n == CT_IP_SUFFIX )); then used=1; fi
    if (( used == 0 )); then echo "$n"; return 0; fi
    n=$((n + 1))
  done
}

ask_vm_fields() {  # agit sur les variables id name cores ram disk oct profile order de l'appelant
  ask_match name "  Nom" "$name" '^[a-z0-9][a-z0-9-]{0,62}$' "Minuscules, chiffres et tirets."
  ask_int cores "  vCPU" "$cores" 1 "$HW_THREADS"
  ask_int ram "  RAM (Go)" "$ram" 1 "$HW_RAM_GB"
  ask_int disk "  Disque (Go)" "$disk" 10 "$HW_USABLE_GB"
  ask_int oct "  Adresse ${LAN_PREFIX}.?" "$oct" 2 254
  ask_choice profile "  Profil" "$profile" "$PROFILES"
  ask_int order "  Ordre de démarrage" "$order" 1 99
}

edit_plan() {
  local spec id name cores ram disk oct profile order new=()
  info "Profils : coolify = panneau Coolify ; managed = serveur piloté par Coolify ; kobo = Docker + kobo-install ; base = Ubuntu seul."
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
    if qm status "$id" >/dev/null 2>&1; then
      info "VM ${id} (${name}) déjà créée : inchangée."; new+=("$spec"); continue
    fi
    echo; info "VM ${id} — ${name}"
    if ! ask_yn "Garder cette VM ?" o; then continue; fi
    ask_vm_fields
    new+=("${id}|${name}|${cores}|${ram}|${disk}|${oct}|${profile}|${order}")
  done
  VMS=("${new[@]}")
  while ask_yn "Ajouter une VM ?" n; do
    id="$(next_free id)"; name="vm${id}"; cores=2; ram=4; disk=50; oct="$(next_free oct)"; profile="managed"; order=5
    ask_int id "  Identifiant" "$id" 101 999999
    ask_vm_fields
    VMS+=("${id}|${name}|${cores}|${ram}|${disk}|${oct}|${profile}|${order}")
  done
}

edit_until_valid() {
  edit_plan
  while ! ( validate_plan ); do
    warn "Plan incohérent : reprendre la saisie."
    edit_plan
  done
}

step "Plan des machines"
plan_action=""
validate_plan
while :; do
  show_plan
  if check_budget; then
    if ! ask_yn "Modifier le plan ?" n; then break; fi
    edit_until_valid
  else
    (( ASSUME_YES )) && die "Le plan dépasse les ressources : corriger VMS dans ${CONF_FILE}."
    ask_choice plan_action "Réduire automatiquement (a), modifier (m), forcer (f) ou quitter (q)" "a" "a m f q"
    case "$plan_action" in
      a) autoscale_plan ;;
      m) edit_until_valid ;;
      f) warn "Plan forcé au-delà des ressources."; break ;;
      q) info "Arrêt sans modification."; exit 0 ;;
    esac
  fi
done

COOLIFY_IP=""; KOBO_ID=""; TEST_ID=""; PROD_ID=""; FIRST_MANAGED=""
declare -A VM_IP=() VM_NAME=()
for spec in "${VMS[@]}"; do
  IFS='|' read -r id name _ _ _ oct profile _ <<<"$spec"
  VM_IP[$id]="${LAN_PREFIX}.${oct}"; VM_NAME[$id]="$name"
  if [[ $profile == coolify && -z $COOLIFY_IP ]]; then COOLIFY_IP="${LAN_PREFIX}.${oct}"; fi
  if [[ $profile == kobo && -z $KOBO_ID ]]; then KOBO_ID="$id"; fi
  if [[ $profile == managed && -z $FIRST_MANAGED ]]; then FIRST_MANAGED="$id"; fi
  if [[ $name == perso-tests ]]; then TEST_ID="$id"; fi
  if [[ $name == uninef-prod ]]; then PROD_ID="$id"; fi
done

# Routeur web : domaine (et ses sous-domaines) → VM ; tout le reste va à WEB_DEFAULT_VM
WEB_DEFAULT_VM="${WEB_DEFAULT_VM:-${PROD_ID:-$FIRST_MANAGED}}"
[[ -n $WEB_DEFAULT_VM && -n ${VM_IP[$WEB_DEFAULT_VM]-} ]] \
  || die "WEB_DEFAULT_VM (« ${WEB_DEFAULT_VM} ») doit être l'identifiant d'une VM du plan."
if (( ${#WEB_ROUTES[@]} == 0 )); then
  if [[ -n $KOBO_ID ]]; then
    WEB_ROUTES+=(".kobo.${WEB_DOMAIN}|${KOBO_ID}" ".ee.${WEB_DOMAIN}|${KOBO_ID}" ".kc.${WEB_DOMAIN}|${KOBO_ID}")
  fi
  if [[ -n $TEST_ID ]]; then WEB_ROUTES+=(".test.${WEB_DOMAIN}|${TEST_ID}"); fi
fi
for route in "${WEB_ROUTES[@]}"; do
  [[ ${route%%|*} =~ ^\.[a-z0-9.-]+\.[a-z]{2,}$ && -n ${VM_IP[${route#*|}]-} ]] \
    || die "Route web invalide : « ${route} » (format « .domaine|ID », la VM doit être dans le plan)."
done

show_routes() {
  local route
  printf '  Routeur web     80/443 de %s → %s ; par défaut : %s\n' "$PUBLIC_IP" "$CT_IP" "${VM_NAME[$WEB_DEFAULT_VM]}"
  for route in "${WEB_ROUTES[@]}"; do
    printf '                    %-28s → %s\n' "${route%%|*} (et sous-domaines)" "${VM_NAME[${route#*|}]}"
  done
}

# -----------------------------------------------------------------------------
# 5. Récapitulatif et confirmation
# -----------------------------------------------------------------------------
step "Récapitulatif"
cat <<EOF
  Matériel        ${HW_THREADS} threads, ${HW_RAM_GB} Go, disques ${HW_DISK_TYPE^^}, redondance ${HW_RAID}
  Stockage VM     ${STORAGE} (${STORAGE_TYPE}, ${HW_USABLE_GB} Go)$( (( USES_ZFS )) && echo ", cache ZFS ${ZFS_ARC_MAX_GB} Go")
  Réseau privé    ${LAN_CIDR} sur ${LAN_BRIDGE}, passerelle ${LAN_GW}, NAT vers ${WAN_IF}
  SSH hôte        port ${SSH_PORT}, clé uniquement, depuis ${SSH_ALLOW_FROM:-tout Internet}
  Pare-feu        $( (( ENABLE_FIREWALL )) && echo "actif : seuls SSH, ping et 80/443 (vers le routeur web) entrent" || echo "DÉSACTIVÉ")
  Administration  tunnels SSH (Proxmox 8006, Coolify 8000) ; interface Proxmox absente de l'IP publique
  Isolation VM    $( (( VM_ISOLATION )) && echo "active (entrées : routeur web en 80/443, Coolify et hôte en SSH)" || echo "désactivée")
  Alertes         ${ADMIN_EMAIL:-aucune adresse}$([[ -n $SMTP_HOST ]] && echo " via ${SMTP_HOST}")
  Sauvegardes     ${BACKUP_SCHEDULE} sur ${BACKUP_STORAGE} : ${BACKUP_KEEP_DAILY} quotidiennes, ${BACKUP_KEEP_WEEKLY} hebdomadaires
  Ubuntu des VM   ${UBUNTU_RELEASE} (modèle ${TEMPLATE_ID})
EOF
show_routes
show_plan

save_answers() {
  local header
  header="# Réponses de ks5-setup.sh du $(date '+%F %T'). Relancer : $(rerun_cmd -c /root/ks5-reponses.conf)"
  {
    echo "$header"
    echo "# Le mot de passe SMTP n'est jamais enregistré ici."
    declare -p TIMEZONE ADMIN_EMAIL SMTP_HOST SMTP_PORT SMTP_MODE SMTP_USER SMTP_FROM SSH_PORT SSH_ALLOW_FROM \
      ENABLE_FIREWALL VM_ISOLATION GUI_LAN_ONLY ROLLBACK_DELAY HW_THREADS HW_RAM_GB HW_DISK_TYPE HW_RAID \
      HW_USABLE_GB ZFS_ARC_MAX_GB HOST_RESERVE_GB DISK_BUDGET_PCT LAN_BRIDGE LAN_PREFIX DNS_SERVERS STORAGE \
      VMDATA_DATASET TEMPLATE_ID UBUNTU_RELEASE CI_USER WEB_DOMAIN WEB_DEFAULT_VM WEB_ROUTES BACKUP_STORAGE \
      BACKUP_SCHEDULE BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY DISK_ALERT_PCT CT_ID CT_NAME CT_IP_SUFFIX CT_CORES \
      CT_MEM_MB CT_DISK_GB VMS VM_FW_EXTRA
  } >"$ANSWERS_FILE"
  chmod 600 "$ANSWERS_FILE"
}

if (( PLAN_ONLY )); then
  info "Mode plan : aucune modification. Relancer sans -p pour appliquer."
  exit 0
fi
if (( ASSUME_YES == 0 )); then
  ask_yn "Lancer la configuration ?" n || { info "Opération annulée."; exit 0; }
fi
save_answers
install -d -m 700 "$BACKUP_DIR"
info "Réponses enregistrées dans ${ANSWERS_FILE} (sans mot de passe)."

if (( ASSUME_YES == 0 )) && ask_yn "Changer le mot de passe root (connexion à l'interface Proxmox) ?" o; then
  passwd root </dev/tty >/dev/tty 2>&1 || warn "Mot de passe inchangé."
fi

# =============================================================================
# Application
# =============================================================================

# -----------------------------------------------------------------------------
# A. Dépôts et mises à jour
# -----------------------------------------------------------------------------
step "Dépôts Proxmox sans abonnement et mises à jour"
for f in /etc/apt/sources.list.d/*.sources; do
  [[ -e $f ]] || continue
  grep -q 'enterprise\.proxmox\.com' "$f" || continue
  if grep -qiE '^Enabled:[[:space:]]*(no|false)' "$f"; then continue; fi
  sed -i -E '/^Enabled:/Id' "$f"
  sed -i '/^Types:/a Enabled: no' "$f"
  info "Dépôt entreprise désactivé : $f"
done
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [[ -e $f ]] || continue
  sed -i -E '/enterprise\.proxmox\.com/ s/^[[:space:]]*deb /# deb /' "$f"
done
if ! grep -rqsE '^[^#]*pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  if [[ "$CODENAME" == "bookworm" ]]; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
      | put 644 /etc/apt/sources.list.d/pve-no-subscription.list
  else
    put 644 /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  fi
  info "Dépôt pve-no-subscription ajouté."
fi
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y -q install curl fail2ban python3-systemd nftables unattended-upgrades
# nftables sert uniquement aux bannissements fail2ban ; son service vide toutes les règles
# (pare-feu Proxmox, NAT) au démarrage : ne jamais l'activer sur cet hôte.
systemctl disable nftables.service >/dev/null 2>&1 || true
ok "Système à jour."

# -----------------------------------------------------------------------------
# B. Système : fuseau, noyau, services inutiles, mises à jour de sécurité, alertes
# -----------------------------------------------------------------------------
step "Système, mises à jour de sécurité et alertes"
timedatectl set-timezone "$TIMEZONE"

put 644 /etc/sysctl.d/99-ks5.conf <<'EOF'
# ks5-setup : routage pour le réseau privé NAT et durcissement réseau de base
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
vm.swappiness = 10
EOF
rm -f /etc/sysctl.d/99-ks5-forward.conf
sysctl -q -p /etc/sysctl.d/99-ks5.conf

# Portmapper (port 111) : inutile sans stockage NFS, utilisé pour l'amplification DDoS
systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1 || true
systemctl mask rpcbind.socket rpcbind.service >/dev/null 2>&1 || true

put 644 /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
put 644 /etc/apt/apt.conf.d/52ks5-unattended <<'EOF'
// ks5-setup : correctifs de sécurité Debian uniquement, sans redémarrage.
// Proxmox (noyau, QEMU, LXC) se met à jour à la main : apt update && apt full-upgrade
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "only-on-error";
EOF

# Le courrier de root (ZFS, smartd, mdadm, cron, vzdump) part vers le mail de root@pam
if [[ -n $ADMIN_EMAIL ]]; then
  pveum user modify root@pam --email "$ADMIN_EMAIL"
  ok "Alertes envoyées à ${ADMIN_EMAIL}."
fi
# Relais SMTP facultatif : un échec ici ne doit pas interrompre l'installation
setup_smtp() {
  local smtp_args=(--server "$SMTP_HOST" --port "$SMTP_PORT" --mode "$SMTP_MODE" --from-address "$SMTP_FROM"
                   --mailto-user root@pam --author "Proxmox ${NODE}")
  local fix="à corriger dans Datacenter › Notifications"
  if [[ -n $SMTP_USER ]]; then smtp_args+=(--username "$SMTP_USER"); fi
  if [[ -n $SMTP_PASSWORD ]]; then smtp_args+=(--password "$SMTP_PASSWORD"); fi
  if pvesh get /cluster/notifications/endpoints/smtp/ks5-smtp >/dev/null 2>&1; then
    pvesh set /cluster/notifications/endpoints/smtp/ks5-smtp "${smtp_args[@]}" \
      || { warn "Relais SMTP non mis à jour (${fix})."; return 0; }
  else
    pvesh create /cluster/notifications/endpoints/smtp --name ks5-smtp "${smtp_args[@]}" \
      || { warn "Relais SMTP non créé (${fix}) ; les alertes partent directement."; return 0; }
  fi
  if pvesh get /cluster/notifications/matchers/default-matcher >/dev/null 2>&1; then
    pvesh set /cluster/notifications/matchers/default-matcher --target ks5-smtp \
      || { warn "Alertes non routées vers le relais (${fix})."; return 0; }
  elif ! pvesh get /cluster/notifications/matchers/ks5-tout >/dev/null 2>&1; then
    pvesh create /cluster/notifications/matchers --name ks5-tout --target ks5-smtp --mode all \
      || { warn "Alertes non routées vers le relais (${fix})."; return 0; }
  fi
  if pvesh create /cluster/notifications/targets/ks5-smtp/test >/dev/null 2>&1; then
    ok "Relais SMTP configuré : mail de test envoyé à ${ADMIN_EMAIL}."
  else
    warn "Relais SMTP configuré mais le mail de test a échoué (${fix})."
  fi
}
if [[ -n $SMTP_HOST ]]; then setup_smtp; fi

# Alerte quotidienne : pool ZFS dégradé ou rempli, racine pleine
sed "s/__SEUIL__/${DISK_ALERT_PCT}/" <<'EOF' | put 755 /etc/cron.daily/ks5-espace-disque
#!/bin/sh
# ks5-setup : alerte quand un pool ZFS n'est pas ONLINE ou dépasse le seuil, ou que / se remplit
seuil=__SEUIL__
msg=""
if command -v zpool >/dev/null 2>&1; then
  msg=$(zpool list -H -o name,capacity,health 2>/dev/null | awk -v s="$seuil" \
    '{c=$2; sub("%","",c); if (c+0 >= s || $3 != "ONLINE") print "Pool " $1 " : " $2 " utilisés, état " $3}')
fi
racine=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${racine:-0}" -ge "$seuil" ]; then msg="$msg
Système (/) : ${racine} % utilisés"; fi
[ -n "$msg" ] || exit 0
printf 'Subject: [%s] Disques à surveiller\n\n%s\n\nDétail : zpool status -x ; df -h\n' "$(hostname)" "$msg" \
  | /usr/sbin/sendmail root
EOF
if (( USES_ZFS )); then systemctl enable --now zfs-zed >/dev/null 2>&1 || true; fi
ok "Correctifs de sécurité automatiques, rpcbind arrêté, alerte d'espace disque quotidienne."

# -----------------------------------------------------------------------------
# C. Stockage des VM et cache ZFS
# -----------------------------------------------------------------------------
step "Stockage des VM et cache ZFS"
if [[ $STORAGE_TYPE == zfs-nouveau ]]; then
  # Le modèle OVH monte le pool ZFS sur /var/lib/vz (stockage « local » de type répertoire) :
  # un dataset dédié donne de vrais volumes ZFS (zvol) aux VM au lieu de fichiers.
  zfs list -H "$STORAGE_POOL" >/dev/null 2>&1 || zfs create -o compression=lz4 -o atime=off "$STORAGE_POOL"
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
    || pvesm add zfspool "$STORAGE" --pool "$STORAGE_POOL" --content images,rootdir --sparse 1
  STORAGE_TYPE="zfspool"
  ok "Stockage ${STORAGE} créé sur ${STORAGE_POOL} (allocation à la demande, compression lz4)."
fi
ensure_content local iso vztmpl backup snippets
install -d -m 755 "$SNIPPETS_DIR"

if (( USES_ZFS && ZFS_ARC_MAX_GB > 0 )); then
  ARC_BYTES=$(( ZFS_ARC_MAX_GB * 1024 * 1024 * 1024 ))
  touch /etc/modprobe.d/zfs.conf
  if grep -q 'zfs_arc_max=' /etc/modprobe.d/zfs.conf; then
    sed -i -E "s/zfs_arc_max=[0-9]+/zfs_arc_max=${ARC_BYTES}/" /etc/modprobe.d/zfs.conf
  else
    echo "options zfs zfs_arc_max=${ARC_BYTES}" >>/etc/modprobe.d/zfs.conf
  fi
  chmod 644 /etc/modprobe.d/zfs.conf
  echo "$ARC_BYTES" 2>/dev/null >/sys/module/zfs/parameters/zfs_arc_max \
    || warn "Plafond ZFS appliqué au prochain redémarrage seulement."
  update-initramfs -u -k all >/dev/null 2>&1 || true
  ok "Cache ZFS limité à ${ZFS_ARC_MAX_GB} Go."
fi

# -----------------------------------------------------------------------------
# D. Réseau privé NAT
# -----------------------------------------------------------------------------
step "Réseau privé ${LAN_CIDR} (${LAN_BRIDGE})"
if ! grep -qE "^[[:space:]]*iface[[:space:]]+${LAN_BRIDGE}[[:space:]]" /etc/network/interfaces; then
  IF_BACKUP="${BACKUP_DIR}/interfaces.$(date +%F-%H%M%S)"
  cp -a /etc/network/interfaces "$IF_BACKUP"
  cat >>/etc/network/interfaces <<EOF

# ks5-setup : réseau privé des VM, sortie vers Internet par NAT,
# 80/443 de l'IP publique redirigés vers le routeur web (sans masquer l'adresse du visiteur)
auto ${LAN_BRIDGE}
iface ${LAN_BRIDGE} inet static
	address ${LAN_GW}/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up   iptables -t nat -A POSTROUTING -s '${LAN_CIDR}' -o ${WAN_IF} -j MASQUERADE
	post-down iptables -t nat -D POSTROUTING -s '${LAN_CIDR}' -o ${WAN_IF} -j MASQUERADE
	post-up   iptables -t nat -A PREROUTING -d ${PUBLIC_IP}/32 -p tcp -m multiport --dports 80,443 -j DNAT --to-destination ${CT_IP}
	post-down iptables -t nat -D PREROUTING -d ${PUBLIC_IP}/32 -p tcp -m multiport --dports 80,443 -j DNAT --to-destination ${CT_IP}
	post-up   iptables -t nat -A POSTROUTING -s '${LAN_CIDR}' -d ${CT_IP}/32 -p tcp -m multiport --dports 80,443 -m conntrack --ctstate DNAT -j MASQUERADE
	post-down iptables -t nat -D POSTROUTING -s '${LAN_CIDR}' -d ${CT_IP}/32 -p tcp -m multiport --dports 80,443 -m conntrack --ctstate DNAT -j MASQUERADE
	post-up   iptables -A FORWARD ! -i ${LAN_BRIDGE} -o ${LAN_BRIDGE} -m conntrack --ctstate NEW -m conntrack ! --ctstate DNAT -j DROP
	post-down iptables -D FORWARD ! -i ${LAN_BRIDGE} -o ${LAN_BRIDGE} -m conntrack --ctstate NEW -m conntrack ! --ctstate DNAT -j DROP
	post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
	post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF
  if ! ifreload -a; then
    cp -a "$IF_BACKUP" /etc/network/interfaces
    ifreload -a || true
    die "Échec de l'application du réseau : configuration précédente restaurée."
  fi
fi
ip -4 addr show dev "$LAN_BRIDGE" 2>/dev/null | grep -q "inet ${LAN_GW}/" \
  || die "Le pont ${LAN_BRIDGE} n'a pas l'adresse ${LAN_GW} (voir /etc/network/interfaces)."
iptables -t nat -C POSTROUTING -s "$LAN_CIDR" -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
  || warn "Règle NAT absente : le pont ${LAN_BRIDGE} existait déjà sans la configuration du script."
iptables -t nat -C PREROUTING -d "${PUBLIC_IP}/32" -p tcp -m multiport --dports 80,443 -j DNAT --to-destination "$CT_IP" 2>/dev/null \
  || warn "Redirection 80/443 absente : ajouter les règles DNAT de la section ${LAN_BRIDGE} (voir le script) dans /etc/network/interfaces."
ok "Pont ${LAN_BRIDGE} actif, NAT vers ${WAN_IF}, 80/443 redirigés vers ${CT_IP}, aucune autre entrée vers le réseau privé."

# -----------------------------------------------------------------------------
# E. Accès : SSH, fail2ban, pare-feu Proxmox (avec retour arrière automatique)
# -----------------------------------------------------------------------------
step "Accès : SSH, fail2ban, pare-feu"

gen_sshd() {
  cat <<EOF
# ks5-setup : lu avant sshd_config, la première valeur rencontrée l'emporte
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

gen_cluster_fw() {
  local c
  echo "# ks5-setup — version précédente dans ${BACKUP_DIR}"
  cat <<EOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[ALIASES]
local_network ${LAN_GW}/32 # remplace la détection automatique, qui ouvrirait la gestion au sous-réseau public OVH

[IPSET management] # interface 8006 et consoles : l'hôte lui-même, donc uniquement par tunnel SSH
${LAN_GW}
EOF
  if [[ -n $SSH_ALLOW_FROM ]]; then
    printf '\n[IPSET ssh_public] # sources autorisées en SSH public\n'
    for c in $SSH_ALLOW_FROM; do echo "$c"; done
  fi
  printf '\n[RULES]\n'
  if [[ -n $SSH_ALLOW_FROM ]]; then
    echo "IN ACCEPT -i ${WAN_IF} -source +ssh_public -p tcp -dport ${SSH_PORT} -log nolog # SSH public restreint (clé uniquement)"
  else
    echo "IN ACCEPT -i ${WAN_IF} -p tcp -dport ${SSH_PORT} -log nolog # SSH public (clé uniquement, fail2ban)"
  fi
  echo "IN Ping(ACCEPT) -log nolog # supervision OVH (sans réponse au ping, OVH intervient sur le serveur)"
  printf '\n[group vm-base] # entrées communes à toutes les VM\n'
  echo "IN ACCEPT -source ${CT_IP} -p tcp -dport 80,443 -log nolog # routeur web : sites publics"
  echo "IN ACCEPT -source ${LAN_GW} -p tcp -dport 22 -log nolog # administration SSH par rebond sur l'hôte"
  if [[ -n $COOLIFY_IP ]]; then
    echo "IN ACCEPT -source ${COOLIFY_IP} -p tcp -dport 22 -log nolog # Coolify pilote les serveurs en SSH"
  fi
  echo "IN Ping(ACCEPT) -source ${LAN_CIDR} -log nolog"
}

gen_host_fw() {
  cat <<'EOF'
# ks5-setup
[OPTIONS]
enable: 1
tcpflags: 1
nosmurfs: 1
EOF
}

gen_rollback() {
  cat <<EOF
#!/bin/sh
# ks5-setup : restauration automatique des accès quand la connexion n'a pas été confirmée
logger -t ks5-setup "Accès non confirmé : restauration de SSH et arrêt du pare-feu Proxmox"
rm -f ${SSHD_DROPIN}
if [ -f ${BACKUP_DIR}/sshd-dropin.prev ]; then cp ${BACKUP_DIR}/sshd-dropin.prev ${SSHD_DROPIN}; fi
systemctl reload ssh || systemctl restart ssh
if [ -f /etc/pve/firewall/cluster.fw ]; then
  t=\$(sed 's/^enable: 1/enable: 0/' /etc/pve/firewall/cluster.fw) && printf '%s\n' "\$t" > /etc/pve/firewall/cluster.fw
fi
pve-firewall stop || true
EOF
}

disarm_rollback() {
  systemctl stop ks5-rollback.timer >/dev/null 2>&1 || true
  systemctl reset-failed ks5-rollback.service ks5-rollback.timer >/dev/null 2>&1 || true
}

arm_rollback() {
  disarm_rollback
  gen_rollback | put 700 "$ROLLBACK_SCRIPT"
  systemd-run --quiet --unit=ks5-rollback --on-active="${ROLLBACK_DELAY}" /bin/sh "$ROLLBACK_SCRIPT"
  info "Filet de sécurité armé : sans confirmation sous $(( ROLLBACK_DELAY / 60 )) min, SSH et pare-feu sont restaurés."
}

access_ok_auto() {
  sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' || return 1
  sshd -T 2>/dev/null | grep -qx "port ${SSH_PORT}" || return 1
  ss -Hltn "sport = :${SSH_PORT}" | grep -q . || return 1
  if (( ENABLE_FIREWALL )); then
    pve-firewall status 2>/dev/null | grep -q 'enabled/running' || return 1
    iptables-save 2>/dev/null | grep -q -- "--dport ${SSH_PORT}" || return 1
  fi
}

confirm_access() {
  local ans=""
  if (( ASSUME_YES )); then
    sleep 5
    if access_ok_auto; then disarm_rollback; ok "Accès vérifiés automatiquement."; return 0; fi
    /bin/sh "$ROLLBACK_SCRIPT"; disarm_rollback
    die "Contrôle des accès en échec : SSH et pare-feu restaurés. Relancer en mode interactif."
  fi
  cat <<EOF

  Vérification de l'accès — NE FERMEZ PAS cette session.
  Depuis votre poste, dans un NOUVEAU terminal :

      ssh -p ${SSH_PORT} root@${PUBLIC_IP}

  Si la connexion aboutit, tapez OK ci-dessous.

EOF
  read -r -t $(( ROLLBACK_DELAY - 30 )) -p "  Nouvelle connexion réussie ? (OK) : " ans </dev/tty || ans=""
  if [[ ${ans^^} == OK ]]; then
    disarm_rollback; ok "Accès confirmé, filet de sécurité désarmé."
  else
    /bin/sh "$ROLLBACK_SCRIPT"; disarm_rollback
    die "Accès non confirmé : SSH et pare-feu restaurés. Corriger puis relancer le script."
  fi
}

if systemctl is-active --quiet ssh.socket && (( SSH_PORT != 22 )); then
  die "SSH est activé par socket sur ce système : garder le port 22 ou adapter ssh.socket à la main."
fi
grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

ACCESS_CHANGED=0
NEW_SSHD="$(gen_sshd)"
[[ "$(cat "$SSHD_DROPIN" 2>/dev/null)" == "$NEW_SSHD" ]] || ACCESS_CHANGED=1

WRITE_CLUSTER_FW=0
if (( ENABLE_FIREWALL )); then
  NEW_CLUSTER_FW="$(gen_cluster_fw)"
  if [[ ! -f /etc/pve/firewall/cluster.fw ]]; then
    WRITE_CLUSTER_FW=1
  elif [[ "$(cat /etc/pve/firewall/cluster.fw)" != "$NEW_CLUSTER_FW" ]]; then
    # Fichier existant (modifié dans l'interface, ou paramètres changés) : on ne l'écrase que sur accord
    if grep -qE '^enable:[[:space:]]*1' /etc/pve/firewall/cluster.fw; then fw_default=n; else fw_default=o; fi
    if ask_yn "Le pare-feu du datacenter diffère de la configuration du script. Le remplacer (l'actuel est sauvegardé) ?" "$fw_default"; then
      WRITE_CLUSTER_FW=1
    fi
  fi
  if (( WRITE_CLUSTER_FW )); then ACCESS_CHANGED=1; fi
fi

if (( ACCESS_CHANGED )); then
  if [[ -f $SSHD_DROPIN ]]; then
    cp -a "$SSHD_DROPIN" "${BACKUP_DIR}/sshd-dropin.prev"
  else
    rm -f "${BACKUP_DIR}/sshd-dropin.prev"
  fi
  arm_rollback
  rm -f /etc/ssh/sshd_config.d/99-ks5-hardening.conf
  printf '%s\n' "$NEW_SSHD" | put 644 "$SSHD_DROPIN"
  if ! sshd -t; then
    /bin/sh "$ROLLBACK_SCRIPT"; disarm_rollback
    die "Configuration SSH invalide : version précédente restaurée."
  fi
  systemctl reload ssh
  if (( WRITE_CLUSTER_FW )); then
    mkdir -p /etc/pve/firewall
    if [[ -f /etc/pve/firewall/cluster.fw ]]; then
      cp /etc/pve/firewall/cluster.fw "${BACKUP_DIR}/cluster.fw.$(date +%F-%H%M%S)"
    fi
    printf '%s\n' "$NEW_CLUSTER_FW" >/etc/pve/firewall/cluster.fw
    HOST_FW="/etc/pve/nodes/${NODE}/host.fw"
    if [[ -f $HOST_FW ]] && ! grep -q '^# ks5-setup' "$HOST_FW"; then
      cp "$HOST_FW" "${BACKUP_DIR}/host.fw.$(date +%F-%H%M%S)"
    fi
    gen_host_fw >"$HOST_FW"
    if ! pve-firewall compile >/dev/null 2>"${BACKUP_DIR}/pve-firewall-compile.err"; then
      /bin/sh "$ROLLBACK_SCRIPT"; disarm_rollback
      die "Règles de pare-feu refusées (${BACKUP_DIR}/pve-firewall-compile.err) : pare-feu arrêté."
    fi
    pve-firewall restart
  fi
  confirm_access
else
  ok "SSH et pare-feu déjà conformes."
fi
if (( ENABLE_FIREWALL == 0 )); then warn "Pare-feu Proxmox non géré par le script (ENABLE_FIREWALL=0)."; fi

put 644 /etc/fail2ban/jail.d/ks5.local <<EOF
# ks5-setup : bannissement par nftables (table dédiée évaluée avant les règles du pare-feu Proxmox)
[DEFAULT]
backend            = systemd
banaction          = nftables-multiport
banaction_allports = nftables-allports
bantime            = 1h
bantime.increment  = true
bantime.maxtime    = 1w
findtime           = 10m
maxretry           = 5
ignoreip           = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${SSH_PORT}
mode    = aggressive
EOF
fail2ban-client -t >/dev/null || die "Configuration fail2ban invalide (/etc/fail2ban/jail.d/ks5.local)."
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# Interface Proxmox (8006) : écoute sur l'adresse privée seulement, même pare-feu arrêté
if (( GUI_LAN_ONLY )); then
  touch /etc/default/pveproxy
  if ! grep -qx "LISTEN_IP=\"${LAN_GW}\"" /etc/default/pveproxy; then
    cp -a /etc/default/pveproxy "${BACKUP_DIR}/pveproxy.$(date +%F-%H%M%S)"
    sed -i '/^LISTEN_IP=/d' /etc/default/pveproxy
    echo "LISTEN_IP=\"${LAN_GW}\"" >>/etc/default/pveproxy
    chmod 644 /etc/default/pveproxy
    systemctl restart pveproxy spiceproxy
    for _ in $(seq 1 15); do
      ss -Hltn "sport = :8006" | grep -q "${LAN_GW}:8006" && break
      sleep 1
    done
    if ! ss -Hltn "sport = :8006" | grep -q "${LAN_GW}:8006"; then
      sed -i '/^LISTEN_IP=/d' /etc/default/pveproxy
      systemctl restart pveproxy spiceproxy
      warn "L'interface n'a pas démarré sur ${LAN_GW} : écoute globale rétablie (le pare-feu la protège)."
    fi
  fi
fi
ok "SSH par clé (port ${SSH_PORT}), fail2ban actif, interface Proxmox réservée au réseau privé."

# -----------------------------------------------------------------------------
# F. Clés SSH et fichiers cloud-init
# -----------------------------------------------------------------------------
step "Clés SSH et fichiers cloud-init"
install -d -m 700 "$KEYS_DIR"
grep -Eo "$KEY_REGEX" /root/.ssh/authorized_keys | sort -u >"${KEYS_DIR}/admin.pub"
if [[ ! -f "${KEYS_DIR}/coolify_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "coolify@${NODE}" -f "${KEYS_DIR}/coolify_ed25519"
fi
cat "${KEYS_DIR}/admin.pub" "${KEYS_DIR}/coolify_ed25519.pub" >"${KEYS_DIR}/managed.pub"
chmod 600 "${KEYS_DIR}"/*

# Vendor-data : complète la configuration cloud-init générée par Proxmox (utilisateur, clés, réseau)
write_snippet() {  # fichier disable_root write_files_en_plus runcmd_en_plus
  put 644 "${SNIPPETS_DIR}/$1" <<EOF
#cloud-config
# ks5-setup
timezone: ${TIMEZONE}
disable_root: $2
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - unattended-upgrades
  - ca-certificates
  - curl
  - git
swap:
  filename: /swap.img
  size: 2147483648
  maxsize: 2147483648
write_files:
  - path: /etc/ssh/sshd_config.d/00-ks5.conf
    permissions: "0644"
    content: |
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin prohibit-password
      X11Forwarding no
      MaxAuthTries 3
$3runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl try-restart ssh
$4
EOF
}
DOCKER_LOGS='  - path: /etc/docker/daemon.json
    permissions: "0644"
    content: |
      {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
'
write_snippet "ks5-base.yaml" true "" ""
write_snippet "ks5-managed.yaml" false "$DOCKER_LOGS" ""
write_snippet "ks5-coolify.yaml" true "" '  - "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"'
write_snippet "ks5-kobo.yaml" true "$DOCKER_LOGS" '  - "curl -fsSL https://get.docker.com | sh"
  - "git clone --depth 1 https://github.com/kobotoolbox/kobo-install.git /opt/kobo-install"'
ok "Clés dans ${KEYS_DIR}, fichiers cloud-init dans ${SNIPPETS_DIR}."

# -----------------------------------------------------------------------------
# G. Modèle Ubuntu cloud-init
# -----------------------------------------------------------------------------
step "Modèle Ubuntu ${UBUNTU_RELEASE} (VM ${TEMPLATE_ID})"
DISK_OPTS="discard=on,iothread=1"
[[ $HW_DISK_TYPE == hdd ]] || DISK_OPTS+=",ssd=1"
FMT_OPT=""
[[ $DISK_FORMAT == qcow2 ]] && FMT_OPT=",format=qcow2"
if qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
  ok "Le modèle ${TEMPLATE_ID} existe déjà."
else
  IMG_DIR="/var/lib/vz/template/cloud"
  IMG_NAME="${UBUNTU_RELEASE}-server-cloudimg-amd64.img"
  BASE_URL="https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/current"
  install -d -m 755 "$IMG_DIR"
  SUMS="$("${CURL[@]}" "${BASE_URL}/SHA256SUMS")" || die "Version Ubuntu introuvable : ${UBUNTU_RELEASE}."
  if ! ( cd "$IMG_DIR" && grep -E "[ *]${IMG_NAME}\$" <<<"$SUMS" | sha256sum -c --status - ) 2>/dev/null; then
    info "Téléchargement de ${IMG_NAME}…"
    "${CURL[@]}" -o "${IMG_DIR}/${IMG_NAME}" "${BASE_URL}/${IMG_NAME}"
    ( cd "$IMG_DIR" && grep -E "[ *]${IMG_NAME}\$" <<<"$SUMS" | sha256sum -c - ) \
      || die "Empreinte SHA-256 incorrecte pour ${IMG_NAME}."
  fi
  qm create "$TEMPLATE_ID" --name "ubuntu-${UBUNTU_RELEASE}-modele" --ostype l26 --cpu host \
    --cores 2 --memory 2048 --net0 "virtio,bridge=${LAN_BRIDGE},firewall=1" \
    --scsihw virtio-scsi-single --agent enabled=1,fstrim_cloned_disks=1 \
    --serial0 socket --vga serial0 --rng0 source=/dev/urandom --tags modele
  qm set "$TEMPLATE_ID" --scsi0 "${STORAGE}:0,import-from=${IMG_DIR}/${IMG_NAME},${DISK_OPTS}${FMT_OPT}"
  qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
  qm template "$TEMPLATE_ID"
  ok "Modèle ${TEMPLATE_ID} créé."
fi

# -----------------------------------------------------------------------------
# H. Routeur web : HAProxy reçoit 80/443 et aiguille chaque domaine vers sa VM
# -----------------------------------------------------------------------------
step "Routeur web ${CT_NAME} (${CT_ID}, ${CT_IP})"
if pct status "$CT_ID" >/dev/null 2>&1; then
  ok "Le conteneur ${CT_ID} existe déjà."
else
  pveam update >/dev/null || warn "Liste des modèles de conteneurs non actualisée."
  CT_TPL="$(pveam available --section system | awk '{print $2}' \
    | grep -E '^debian-1[2-9]-standard_.*_amd64' | sort -V | tail -1 || true)"
  [[ -n "$CT_TPL" ]] || die "Aucun modèle de conteneur Debian disponible (pveam available)."
  [[ -f "/var/lib/vz/template/cache/${CT_TPL}" ]] || pveam download local "$CT_TPL"
  pct create "$CT_ID" "local:vztmpl/${CT_TPL}" --hostname "$CT_NAME" \
    --cores "$CT_CORES" --memory "$CT_MEM_MB" --swap 512 --rootfs "${STORAGE}:${CT_DISK_GB}" \
    --net0 "name=eth0,bridge=${LAN_BRIDGE},ip=${CT_IP}/24,gw=${LAN_GW},firewall=1" \
    --nameserver "$DNS_SERVERS" --unprivileged 1 --features nesting=1 \
    --onboot 1 --startup order=1 --timezone "$TIMEZONE" --tags web
fi
if (( VM_ISOLATION )) && [[ ! -f "/etc/pve/firewall/${CT_ID}.fw" ]]; then
  cat >"/etc/pve/firewall/${CT_ID}.fw" <<EOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
ipfilter: 1

[RULES]
IN ACCEPT -p tcp -dport 80,443 -log nolog # sites publics, redirigés depuis l'IP publique
IN Ping(ACCEPT) -source ${LAN_CIDR} -log nolog
EOF
fi
pct status "$CT_ID" | grep -q running || pct start "$CT_ID"

info "Attente du réseau dans le conteneur…"
for _ in $(seq 1 45); do
  pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1 \
  || die "Le conteneur ${CT_ID} n'accède pas à Internet (vérifier le NAT de ${LAN_BRIDGE})."

pct exec "$CT_ID" -- bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y -q install haproxy unattended-upgrades
# Correctifs de sécurité Debian automatiques (HAProxy compris)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'X'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
X
# Aucun accès SSH au conteneur : « pct enter » depuis l'hôte
systemctl disable --now ssh.socket ssh.service >/dev/null 2>&1 || true
[ -f /etc/haproxy/haproxy.cfg.debian ] || cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.debian
EOF

gen_haproxy_cfg() {
  local spec id name oct profile proxy
  cat <<EOF
# ks5-setup : régénéré à chaque exécution du script, ne pas modifier ici.
# Domaines → VM : /etc/haproxy/domaines.map, puis « systemctl reload haproxy ».
global
    log stdout format short local0 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    maxconn 4096
    stats socket /run/haproxy/admin.sock mode 600 level admin

defaults
    log global
    option dontlognull
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    timeout tunnel 1h
    timeout http-request 10s

# HTTP (80) : validation Let's Encrypt des VM et redirection vers HTTPS, aiguillage sur Host
frontend http_in
    bind :80
    mode http
    use_backend http_%[req.hdr(host),field(1,:),lower,regsub(^,.),map_end(/etc/haproxy/domaines.map,${WEB_DEFAULT_VM})]
    default_backend http_${WEB_DEFAULT_VM}

# HTTPS (443) : aiguillage sur le nom demandé (SNI), sans déchiffrer ; chaque VM garde ses certificats
frontend https_in
    bind :443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend tls_%[req.ssl_sni,lower,regsub(^,.),map_end(/etc/haproxy/domaines.map,${WEB_DEFAULT_VM})]
    default_backend tls_${WEB_DEFAULT_VM}
EOF
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name _ _ _ oct profile _ <<<"$spec"
    # Traefik des serveurs Coolify reçoit l'adresse du visiteur par le protocole PROXY
    if [[ $profile == managed ]]; then proxy=" send-proxy-v2"; else proxy=""; fi
    printf '\nbackend http_%s # %s\n    mode http\n    server %s %s:80%s\n' "$id" "$name" "$name" "${LAN_PREFIX}.${oct}" "$proxy"
    printf '\nbackend tls_%s # %s\n    mode tcp\n    server %s %s:443%s\n' "$id" "$name" "$name" "${LAN_PREFIX}.${oct}" "$proxy"
  done
}

gen_haproxy_map() {
  local route id
  echo "# ks5-setup : « .domaine » = ce domaine et tous ses sous-domaines → identifiant de la VM."
  echo "# Domaine absent : VM ${WEB_DEFAULT_VM} (${VM_NAME[$WEB_DEFAULT_VM]}). Après modification : systemctl reload haproxy"
  echo "# Pas de commentaire en fin de ligne : HAProxy le lirait comme faisant partie de la valeur."
  for id in "${!VM_NAME[@]}"; do echo "#   ${id} = ${VM_NAME[$id]}"; done | sort
  for route in "${WEB_ROUTES[@]}"; do
    printf '%-32s %s\n' "${route%%|*}" "${route#*|}"
  done
}

HAP_TMP="$(mktemp)"
# La table des domaines n'est écrite qu'une fois : elle se modifie ensuite sur le conteneur
if ! pct exec "$CT_ID" -- test -f /etc/haproxy/domaines.map; then
  gen_haproxy_map >"$HAP_TMP"
  pct push "$CT_ID" "$HAP_TMP" /etc/haproxy/domaines.map --perms 0644
fi
gen_haproxy_cfg >"$HAP_TMP"
pct push "$CT_ID" "$HAP_TMP" /etc/haproxy/haproxy.cfg.new --perms 0644
rm -f "$HAP_TMP"
pct exec "$CT_ID" -- haproxy -c -q -f /etc/haproxy/haproxy.cfg.new \
  || die "Configuration HAProxy refusée (pct exec ${CT_ID} -- haproxy -c -f /etc/haproxy/haproxy.cfg.new)."
pct exec "$CT_ID" -- mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg
pct exec "$CT_ID" -- systemctl enable haproxy >/dev/null 2>&1
pct exec "$CT_ID" -- systemctl reload-or-restart haproxy
ok "Routeur web prêt : 80/443 aiguillés par domaine (table : pct exec ${CT_ID} -- cat /etc/haproxy/domaines.map)."

# -----------------------------------------------------------------------------
# I. Machines virtuelles (pare-feu par VM : entrées limitées au routeur web, à Coolify et à l'hôte)
# -----------------------------------------------------------------------------
step "Machines virtuelles"
write_vm_fw() {  # id ip profil
  local f="/etc/pve/firewall/$1.fw" extra
  if [[ -f $f ]] || (( VM_ISOLATION == 0 )); then return 0; fi
  {
    printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\nipfilter: 1\n\n'
    printf '[IPSET ipfilter-net0] # seule adresse source autorisée (anti-usurpation)\n%s\n\n' "$2"
    printf '[RULES]\nGROUP vm-base\n'
    if [[ $3 == coolify ]]; then
      echo "IN ACCEPT -source ${LAN_GW} -p tcp -dport 8000,6001,6002 -log nolog # interface Coolify par tunnel SSH"
      echo "IN ACCEPT -source ${LAN_CIDR} -p tcp -dport 8000 -log nolog # Sentinel des serveurs gérés"
    fi
    for extra in "${VM_FW_EXTRA[@]}"; do
      if [[ ${extra%%|*} == "$1" ]]; then echo "${extra#*|}"; fi
    done
  } >"$f"
}

for spec in "${VMS[@]}"; do
  IFS='|' read -r id name cores ram disk oct profile order <<<"$spec"
  ip="${LAN_PREFIX}.${oct}"
  if qm status "$id" >/dev/null 2>&1; then
    write_vm_fw "$id" "$ip" "$profile"
    ok "VM ${id} (${name}) existe déjà."
    continue
  fi
  case "$profile" in
    coolify) snippet="ks5-coolify.yaml"; keys="${KEYS_DIR}/admin.pub" ;;
    kobo)    snippet="ks5-kobo.yaml";    keys="${KEYS_DIR}/admin.pub" ;;
    managed) snippet="ks5-managed.yaml"; keys="${KEYS_DIR}/managed.pub" ;;
    base)    snippet="ks5-base.yaml";    keys="${KEYS_DIR}/admin.pub" ;;
  esac
  info "Création de ${name} (${id}) : ${cores} vCPU, ${ram} Go, ${disk} Go, ${ip}"
  clone_args=(--name "$name" --full 1 --storage "$STORAGE")
  [[ $DISK_FORMAT == qcow2 ]] && clone_args+=(--format qcow2)
  qm clone "$TEMPLATE_ID" "$id" "${clone_args[@]}"
  qm set "$id" --cores "$cores" --memory $(( ram * 1024 )) \
    --ipconfig0 "ip=${ip}/24,gw=${LAN_GW}" --nameserver "$DNS_SERVERS" \
    --ciuser "$CI_USER" --sshkeys "$keys" --cicustom "vendor=local:snippets/${snippet}" \
    --onboot 1 --startup "order=${order}" --tags "$profile" \
    --description "ks5-setup — profil ${profile}, ${ip}"
  qm resize "$id" scsi0 "${disk}G"
  write_vm_fw "$id" "$ip" "$profile"
  qm start "$id"
  ok "${name} démarrée (premier démarrage : mises à jour et installation en cours quelques minutes)."
done

# -----------------------------------------------------------------------------
# J. Sauvegardes locales
# -----------------------------------------------------------------------------
step "Sauvegarde quotidienne"
if [[ $BACKUP_STORAGE == local ]]; then ensure_content local backup; fi
PRUNE="keep-daily=${BACKUP_KEEP_DAILY}"
(( BACKUP_KEEP_WEEKLY > 0 )) && PRUNE+=",keep-weekly=${BACKUP_KEEP_WEEKLY}"
if grep -qE '^vzdump:[[:space:]]+ks5-daily$' /etc/pve/jobs.cfg 2>/dev/null; then
  pvesh set /cluster/backup/ks5-daily --schedule "$BACKUP_SCHEDULE" --storage "$BACKUP_STORAGE" \
    --prune-backups "$PRUNE"
  ok "Tâche ks5-daily mise à jour."
else
  pvesh create /cluster/backup --id ks5-daily --schedule "$BACKUP_SCHEDULE" \
    --storage "$BACKUP_STORAGE" --all 1 --exclude "$TEMPLATE_ID" --mode snapshot --compress zstd \
    --prune-backups "$PRUNE" --enabled 1
  ok "Sauvegarde quotidienne à ${BACKUP_SCHEDULE} (${PRUNE})."
fi

# -----------------------------------------------------------------------------
# K. Contrôles et récapitulatif
# -----------------------------------------------------------------------------
step "Contrôles"
FAILS=0
check() {  # check "libellé" "commande shell"
  if bash -o pipefail -c "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 : à vérifier"; FAILS=$((FAILS + 1)); fi
}
check "SSH : mots de passe refusés" "sshd -T | grep -qx 'passwordauthentication no'"
check "SSH : root par clé uniquement" "sshd -T | grep -qE '^permitrootlogin (without-password|prohibit-password)\$'"
check "fail2ban surveille SSH" "fail2ban-client status sshd"
if (( ENABLE_FIREWALL )); then
  check "Pare-feu Proxmox actif" "pve-firewall status | grep -q 'enabled/running'"
  check "Gestion limitée à l'hôte (tunnels SSH)" "pve-firewall localnet | grep -q '${LAN_GW}/32'"
fi
check "Interface 8006 absente de l'IP publique" \
  "! ss -Hltn 'sport = :8006' | awk '{print \$4}' | grep -qE -e '^(\*|0\.0\.0\.0|\[::\]):8006\$' -e '^${PUBLIC_IP}:8006\$'"
check "rpcbind (port 111) fermé" "! ss -Hltn 'sport = :111' | grep -q ."
check "NAT du réseau privé" "iptables -t nat -C POSTROUTING -s ${LAN_CIDR} -o ${WAN_IF} -j MASQUERADE"
check "80/443 redirigés vers le routeur web" \
  "iptables -t nat -C PREROUTING -d ${PUBLIC_IP}/32 -p tcp -m multiport --dports 80,443 -j DNAT --to-destination ${CT_IP}"
check "Autres entrées vers le réseau privé bloquées" \
  "iptables -C FORWARD ! -i ${LAN_BRIDGE} -o ${LAN_BRIDGE} -m conntrack --ctstate NEW -m conntrack ! --ctstate DNAT -j DROP"
check "Routeur web démarré" "pct exec ${CT_ID} -- systemctl is-active haproxy"
if (( USES_ZFS )); then check "Pools ZFS en bon état" "zpool status -x | grep -q 'all pools are healthy'"; fi
check "Tâche de sauvegarde présente" "grep -q 'ks5-daily' /etc/pve/jobs.cfg"

REBOOT_NEEDED=0
LATEST_KERNEL="$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -1 || true)"
[[ -z $LATEST_KERNEL || "$(uname -r)" == "$LATEST_KERNEL" ]] || REBOOT_NEEDED=1

{
  cat <<EOF
Serveur ${NODE} (${PUBLIC_IP}) — configuré le $(date '+%F %T') par ks5-setup.sh

Adresses internes
  Proxmox             https://${LAN_GW}:8006
  Routeur web (CT ${CT_ID}) ${CT_IP}       reçoit 80/443 de ${PUBLIC_IP}
EOF
  for spec in "${VMS[@]}"; do
    IFS='|' read -r id name _ _ _ oct profile _ <<<"$spec"
    printf '  %-19s %-15s %s\n' "${name} (${id})" "${LAN_PREFIX}.${oct}" "$profile"
  done
  echo
  show_routes
  cat <<EOF
  Table des domaines  pct exec ${CT_ID} -- nano /etc/haproxy/domaines.map  puis  pct exec ${CT_ID} -- systemctl reload haproxy

Administration (depuis votre poste, par tunnel SSH)
  Interface Proxmox   ssh -p ${SSH_PORT} -L 8006:${LAN_GW}:8006 root@${PUBLIC_IP}   puis https://localhost:8006
$([[ -n $COOLIFY_IP ]] && echo "  Coolify             ssh -p ${SSH_PORT} -L 8000:${COOLIFY_IP}:8000 -L 6001:${COOLIFY_IP}:6001 -L 6002:${COOLIFY_IP}:6002 root@${PUBLIC_IP}   puis http://localhost:8000")
  SSH d'une VM        ssh -p ${SSH_PORT} -J root@${PUBLIC_IP} ${CI_USER}@<adresse>
  Console d'une VM    qm terminal <id>   ·   qm guest exec <id> -- <commande>

Fichiers
  Clé privée Coolify  ${KEYS_DIR}/coolify_ed25519
  Réponses            ${ANSWERS_FILE}
  Sauvegardes config  ${BACKUP_DIR}
  Journal             ${LOG_FILE}
EOF
} | tee "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

echo
if (( FAILS > 0 )); then warn "${FAILS} contrôle(s) à vérifier (détail ci-dessus)."; else ok "Tous les contrôles sont passés."; fi
if [[ -f $CONF_FILE ]] && grep -qE '^SMTP_PASSWORD="[^"]+' "$CONF_FILE"; then
  if ask_yn "Effacer le mot de passe SMTP de ${CONF_FILE} (Proxmox l'a enregistré) ?" o; then
    sed -i -E 's/^SMTP_PASSWORD=.*/SMTP_PASSWORD=""/' "$CONF_FILE"
    ok "Mot de passe effacé de ${CONF_FILE}."
  else
    warn "Mot de passe SMTP encore présent dans ${CONF_FILE}."
  fi
fi
if (( REBOOT_NEEDED )); then warn "Nouveau noyau installé : redémarrer le serveur (reboot) dès que possible."; fi
info "Récapitulatif enregistré dans ${SUMMARY_FILE}."
info "Relancer avec les mêmes réponses : $(rerun_cmd -c "$ANSWERS_FILE")"
info "Étapes suivantes (Coolify, DNS, Kobo) : https://github.com/GRIDAC/ks5-proxmox-setup#4-après-linstallation"
exit 0
}
