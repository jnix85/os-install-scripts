#!/usr/bin/env bash
# ============================================================
# install-ubuntu-zfs.sh
# Ubuntu ZFS-on-root installer
#
# Run from an Ubuntu Desktop Live environment as root.
# Installs Ubuntu onto /dev/nvme0n1 with:
#   - GPT: EFI (1G) + bpool (4G) + rpool (remainder)
#   - Separate rpool/bpool ZFS structure
#   - ZFS datasets for /, /home, /var, /var/cache,
#     /var/lib, /var/lib/docker, /var/tmp, /srv, /usr/local
#   - Swap zvol on rpool
#   - Sanoid for scheduled snapshots + apt pre/post hooks
#   - ZFSBootMenu booted via systemd-boot chainload
#   - mmdebstrap for base OS install
#
# NOTES:
#   - Ubuntu 26.04 codename: verify with `lsb_release -cs`
#     on a running 26.04 system before running this script.
#   - This script DESTROYS all data on the target disk.
#   - Test in a VM first.
# ============================================================

set -euo pipefail
trap 'echo -e "\n${RED}[FATAL]${RESET} Script failed at line $LINENO — aborting." >&2' ERR

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━  $*  ━━━━━━━━━━${RESET}\n"; }

_usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

  --release   CODENAME   Ubuntu codename (e.g. resolute, noble)
  --hostname  NAME       System hostname
  --disk      DEV        Target disk (default: /dev/nvme0n1)
  --user      NAME       Non-root username (creates user, locks root)
  --password  PASS       Password for the non-root user
  --no-user              No non-root user; set root password instead
  --root-password PASS   Root password (only used with --no-user)
  --timezone  TZ         Timezone (e.g. UTC, America/Chicago)
  --quota     SIZE       ZFS quota for /home (e.g. 200G, 1T, none)
  --yes                  Skip the YES confirmation prompt (dangerous!)
  -h, --help             Show this help

Examples:
  sudo bash $0 --release resolute --hostname myserver --user jason --yes
  sudo bash $0 --release resolute --no-user --root-password s3cr3t --yes
EOF
    exit 0
}

# ── Hard-coded defaults ───────────────────────────────────────────────────────
TARGET_DISK="/dev/nvme0n1"
POOL_ROOT="/mnt/zfsinstall"
RPOOL="rpool"
BPOOL="bpool"
EFI_END="+1G"
BPOOL_END="+4G"
UBUNTU_MIRROR="https://archive.ubuntu.com/ubuntu"
# Live-system keyring path — update if your live ISO puts it elsewhere
UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

# ── Pre-root help shortcut ────────────────────────────────────────────────────
# Allow --help / -h without root so any user can read usage.
for _a in "$@"; do [[ "$_a" == "-h" || "$_a" == "--help" ]] && { _usage; }; done

# ── Root guard ────────────────────────────────────────────────────────────────
# TESTING=1 bypasses the root check so tests/test.sh can run without root.
[[ $EUID -eq 0 ]] || [[ "${TESTING:-}" == "1" ]] || die "Must run as root. Try: sudo bash $0"

# ── Logging ───────────────────────────────────────────────────────────────────
# All console output is transparently duplicated to the log file via tee.
# Console appearance is unchanged — tee passes stdout/stderr through as-is.
# In TESTING=1 mode, log to /tmp so root and /var/log are not required.
if [[ "${TESTING:-}" == "1" ]]; then
    LOG="/tmp/test-install-$$.log"
else
    LOG=/var/log/os-install.log
    mkdir -p /var/log
fi
printf '\n%s\n' "$(printf '=%.0s' {1..60})" >> "${LOG}"
printf '[%s] install-ubuntu-zfs.sh started (PID %s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$$" >> "${LOG}"
# Duplicate stdout → tee → log; merge stderr into the same stream.
exec > >(tee -a "${LOG}") 2>&1
# Redirect xtrace (set -x) to the log file only — never to console.
# BASH_XTRACEFD + set -x logs every command with timestamp and line number.
exec 9>>"${LOG}"
BASH_XTRACEFD=9
PS4='+[%(%H:%M:%S)T][L${LINENO}] '
set -x

# ── Argument parsing ──────────────────────────────────────────────────────────
# All flags are optional — any omitted value falls back to the interactive prompt.
# Passwords passed on the command line appear in /proc/<pid>/cmdline while the
# script runs; acceptable on a single-user live ISO, but be aware.

# Pre-initialize all flag-settable vars as empty so prompt logic can test them
UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-}"
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1}"
ADD_USER=""        # set by --user / --no-user; empty = ask interactively
NEW_USER=""
USER_PASSWORD=""
ROOT_PASSWORD=""
TIMEZONE="${TIMEZONE:-}"
LOCALE="en_US.UTF-8"
HOME_QUOTA="${HOME_QUOTA:-}"
AUTO_CONFIRM=no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release|--codename) UBUNTU_CODENAME="$2";  shift 2 ;;
        --hostname)           HOSTNAME_NEW="$2";      shift 2 ;;
        --disk)               TARGET_DISK="$2";       shift 2 ;;
        --user)               NEW_USER="$2"; ADD_USER=yes; shift 2 ;;
        --password)           USER_PASSWORD="$2";     shift 2 ;;
        --no-user)            ADD_USER=no;             shift   ;;
        --root-password)      ROOT_PASSWORD="$2";     shift 2 ;;
        --timezone)           TIMEZONE="$2";          shift 2 ;;
        --quota)              HOME_QUOTA="$2";        shift 2 ;;
        --yes|-y)             AUTO_CONFIRM=yes;        shift   ;;
        -h|--help)            _usage ;;
        *) die "Unknown flag: $1  (run with --help for usage)" ;;
    esac
done

# Validate disk early so we fail before any interactive prompts
[[ -b "${TARGET_DISK}" ]] || die "Disk not found: ${TARGET_DISK}"

# ── Prerequisite check & auto-install ────────────────────────────────────────
banner "Checking prerequisites"

NEEDED_PKGS=()
for cmd_pkg in \
    "debootstrap:debootstrap" \
    "zpool:zfsutils-linux" \
    "sgdisk:gdisk" \
    "partprobe:parted" \
    "mkfs.vfat:dosfstools" \
    "efibootmgr:efibootmgr" \
    "curl:curl" \
    "gpg:gnupg"; do
    cmd="${cmd_pkg%%:*}"; pkg="${cmd_pkg##*:}"
    command -v "$cmd" &>/dev/null || NEEDED_PKGS+=("$pkg")
done
# systemd-boot and its EFI stubs are needed to run `bootctl install` from the live env.
# bootctl is always present (from systemd) but the EFI stub files may not be — install
# both packages unconditionally.
NEEDED_PKGS+=(systemd-boot systemd-boot-efi)

if [[ ${#NEEDED_PKGS[@]} -gt 0 ]]; then
    info "Installing missing live-environment packages: ${NEEDED_PKGS[*]}"
    if [[ "${TESTING:-}" != "1" ]]; then
        apt-get update -qq
        apt-get install -y --no-install-recommends "${NEEDED_PKGS[@]}"
    fi
fi

for cmd in debootstrap zpool zfs sgdisk partprobe mkfs.vfat efibootmgr bootctl curl gpg; do
    command -v "$cmd" &>/dev/null || die "Still missing: $cmd"
done

[[ -f "${UBUNTU_KEYRING}" ]] || {
    warn "Ubuntu keyring not found at ${UBUNTU_KEYRING} — debootstrap will skip signature verification"
    UBUNTU_KEYRING=""
}

[[ "${TESTING:-}" == "1" ]] || modprobe zfs 2>/dev/null || die "Cannot load ZFS kernel module"
success "Prerequisites satisfied"

# ── Interactive configuration ─────────────────────────────────────────────────
banner "Installation configuration"

_prompt() {
    local q="$1" var="$2" def="${3:-}" val
    while true; do
        read -rp "$(echo -e "${YELLOW}${q}${def:+ [${def}]}: ${RESET}")" val
        val="${val:-$def}"
        [[ -n "$val" ]] && { printf -v "$var" '%s' "$val"; return; }
        warn "Value cannot be empty."
    done
}

_prompt_pw() {
    local q="$1" var="$2" a b
    while true; do
        read -rsp "$(echo -e "${YELLOW}${q}: ${RESET}")" a; echo
        read -rsp "$(echo -e "${YELLOW}Confirm: ${RESET}")" b; echo
        [[ "$a" == "$b" ]] || { warn "Passwords do not match."; continue; }
        [[ -n "$a" ]]      || { warn "Password cannot be empty."; continue; }
        printf -v "$var" '%s' "$a"; return
    done
}

echo -e "${BOLD}Ubuntu codename${RESET}"
echo -e "  Verify 26.04's codename on a running system: lsb_release -cs"
[[ -n "${UBUNTU_CODENAME}" ]] || _prompt "Ubuntu codename" UBUNTU_CODENAME "noble"
[[ -n "${HOSTNAME_NEW}"     ]] || _prompt "Hostname"        HOSTNAME_NEW    "ubuntu-server"

if [[ -z "${ADD_USER}" ]]; then
    read -rp "$(echo -e "${YELLOW}Add a non-root user? [Y/n]: ${RESET}")" _ADD_USER_REPLY
    [[ "${_ADD_USER_REPLY,,}" != "n" ]] && ADD_USER=yes || ADD_USER=no
fi

if [[ "${ADD_USER}" == "yes" ]]; then
    [[ -n "${NEW_USER}"      ]] || _prompt "New (non-root) username" NEW_USER
    # Validate before any destructive operations — reject slashes/spaces/special chars
    # that could cause path traversal in sudoers.d or malformed useradd calls.
    [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || \
        die "Invalid username '${NEW_USER}': use 1-31 chars, start with [a-z_], contain only [a-z0-9_-]"
    [[ -n "${USER_PASSWORD}" ]] || _prompt_pw "Password for ${NEW_USER}" USER_PASSWORD
    ROOT_PASSWORD=""
else
    NEW_USER=""
    USER_PASSWORD=""
    [[ -n "${ROOT_PASSWORD}" ]] || _prompt_pw "Root password" ROOT_PASSWORD
fi

echo -e "${YELLOW}Timezone — e.g. UTC, America/Chicago, Europe/London${RESET}"
[[ -n "${TIMEZONE}" ]] || _prompt "Timezone" TIMEZONE "UTC"
# Auto-size swap: equal to RAM up to 8G, half RAM up to 32G, capped at 16G above that.
# Supports hibernate when RAM ≤ 8G; sensible overhead above that.
_ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
_ram_gb=$(( (_ram_kb + 1048575) / 1048576 ))
if   (( _ram_gb <= 8  )); then SWAP_SIZE="${_ram_gb}G"
elif (( _ram_gb <= 32 )); then SWAP_SIZE="$(( (_ram_gb + 1) / 2 ))G"
else                           SWAP_SIZE="16G"
fi
info "Detected ${_ram_gb}G RAM → swap zvol auto-sized to ${SWAP_SIZE}"
echo -e "${YELLOW}/home total quota — ZFS size (e.g. 200G, 1T) or 'none'${RESET}"
[[ -n "${HOME_QUOTA}" ]] || _prompt "/home quota" HOME_QUOTA "none"

# ── Destruction confirmation ──────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${RED}${BOLD}  WARNING — ALL DATA ON ${TARGET_DISK} WILL BE PERMANENTLY DESTROYED  ${RESET}"
echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Disk:        ${BOLD}${TARGET_DISK}${RESET}  ($(lsblk -dno SIZE "${TARGET_DISK}") total)"
echo -e "  Hostname:    ${BOLD}${HOSTNAME_NEW}${RESET}"
if [[ "${ADD_USER}" == "yes" ]]; then
    echo -e "  User:        ${BOLD}${NEW_USER}${RESET}  (root remains locked)"
else
    echo -e "  Access:      ${BOLD}root password login${RESET}  (no non-root user)"
fi
echo -e "  Ubuntu:      ${BOLD}${UBUNTU_CODENAME}${RESET}"
echo -e "  Timezone:    ${BOLD}${TIMEZONE}${RESET}"
echo -e "  Swap:        ${BOLD}${SWAP_SIZE}${RESET} zvol on rpool"
echo -e "  /home quota: ${BOLD}${HOME_QUOTA}${RESET}  /  Locale: ${LOCALE}"
echo ""
if [[ "${AUTO_CONFIRM}" == "yes" ]]; then
    warn "--yes flag set: skipping confirmation prompt"
else
    read -rp "$(echo -e "${RED}${BOLD}Type YES (all caps) to proceed, anything else to abort: ${RESET}")" _CONFIRM
    [[ "${_CONFIRM}" == "YES" ]] || { echo "Aborted."; exit 0; }
fi

# ── Tear down any previous run ─────────────────────────────────────────────────
banner "Clearing any previous state"
# Unmount everything under POOL_ROOT before exporting pools.
# Order matters: bind mounts (resolv.conf, EFI, vfs) must come off before the
# ZFS datasets underneath them, otherwise zpool export sees the pool as busy.
for _bm in \
    "${POOL_ROOT}/etc/resolv.conf" \
    "${POOL_ROOT}/boot/efi" \
    "${POOL_ROOT}/dev/pts" \
    "${POOL_ROOT}/dev" \
    "${POOL_ROOT}/proc" \
    "${POOL_ROOT}/sys" \
    "${POOL_ROOT}/run"; do
    umount "${_bm}" 2>/dev/null || true
done
zfs unmount -a 2>/dev/null || true
umount -Rl "${POOL_ROOT}" 2>/dev/null || true

for _stale_pool in "${BPOOL}" "${RPOOL}"; do
    if zpool list "${_stale_pool}" &>/dev/null; then
        info "Exporting stale pool: ${_stale_pool}"
        if ! zpool export "${_stale_pool}" 2>/dev/null; then
            warn "Normal export failed — retrying with -f (force)"
            zpool export -f "${_stale_pool}" || \
                die "Pool '${_stale_pool}' could not be force-exported. Run: zpool export -f ${_stale_pool}"
        fi
        success "Exported ${_stale_pool}"
    fi
done

# ── Partition ─────────────────────────────────────────────────────────────────
banner "Partitioning ${TARGET_DISK}"

wipefs -af "${TARGET_DISK}"
sgdisk --zap-all "${TARGET_DISK}"
sgdisk --clear   "${TARGET_DISK}"

#  Part  Type   Size    Role
#  ──────────────────────────────
#  p1    EF00   1G      EFI System Partition
#  p2    BF01   4G      ZFS bpool (boot — kernels + initrds)
#  p3    BF00   rest    ZFS rpool (root — OS + data)
sgdisk -n1:0:${EFI_END}   -t1:EF00 -c1:"EFI System" "${TARGET_DISK}"
sgdisk -n2:0:${BPOOL_END} -t2:BF01 -c2:"ZFS bpool"  "${TARGET_DISK}"
sgdisk -n3:0:0            -t3:BF00 -c3:"ZFS rpool"   "${TARGET_DISK}"

partprobe "${TARGET_DISK}"
udevadm settle
sleep 2

# Resolve partition names (nvme/mmcblk use p-suffix)
if [[ "${TARGET_DISK}" == *nvme* || "${TARGET_DISK}" == *mmcblk* ]]; then
    EFI_PART="${TARGET_DISK}p1"
    BPOOL_PART="${TARGET_DISK}p2"
    RPOOL_PART="${TARGET_DISK}p3"
else
    EFI_PART="${TARGET_DISK}1"
    BPOOL_PART="${TARGET_DISK}2"
    RPOOL_PART="${TARGET_DISK}3"
fi

[[ -b "${EFI_PART}" ]]   || die "EFI partition not found: ${EFI_PART}"
[[ -b "${BPOOL_PART}" ]] || die "bpool partition not found: ${BPOOL_PART}"
[[ -b "${RPOOL_PART}" ]] || die "rpool partition not found: ${RPOOL_PART}"

mkfs.vfat -F 32 -n EFI "${EFI_PART}"
success "Partitioned: EFI=${EFI_PART}  bpool=${BPOOL_PART}  rpool=${RPOOL_PART}"

# ── Create ZFS pools ──────────────────────────────────────────────────────────
banner "Creating ZFS pools"

zpool labelclear -f "${BPOOL_PART}" 2>/dev/null || true
zpool labelclear -f "${RPOOL_PART}" 2>/dev/null || true

# ── bpool ──────────────────────────────────────────────────────────────────────
# Pool root gets canmount=off so it never auto-mounts and shadows nothing.
# Feature set is intentionally restricted for maximum ZFSBootMenu compatibility.
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -O canmount=off \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=/boot \
    -R "${POOL_ROOT}" \
    -f \
    "${BPOOL}" "${BPOOL_PART}"

# ── rpool ──────────────────────────────────────────────────────────────────────
# Pool root also gets canmount=off. Only rpool/ROOT/ubuntu gets explicitly mounted.
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O canmount=off \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=/ \
    -R "${POOL_ROOT}" \
    -f \
    "${RPOOL}" "${RPOOL_PART}"

success "ZFS pools created"

# ── Create datasets — ORDER MATTERS ───────────────────────────────────────────
#
# We must mount rpool/ROOT/ubuntu FIRST (via explicit `zfs mount`), THEN
# create bpool/BOOT/ubuntu so it lands on top of the live /boot directory.
# Without this ordering, rpool's pool-root auto-mount would shadow bpool.
#
banner "Creating ZFS datasets"

# rpool namespace containers (never mounted)
zfs create -o canmount=off -o mountpoint=none "${RPOOL}/ROOT"

# Root filesystem — canmount=noauto prevents auto-mount; we mount it explicitly
zfs create \
    -o canmount=noauto \
    -o mountpoint=/ \
    "${RPOOL}/ROOT/ubuntu"
zpool set bootfs="${RPOOL}/ROOT/ubuntu" "${RPOOL}"

# ── Mount root NOW before creating bpool datasets ──────────────────────────────
zfs mount "${RPOOL}/ROOT/ubuntu"
# Verify it is actually mounted where we expect
mountpoint -q "${POOL_ROOT}" || die "rpool/ROOT/ubuntu failed to mount at ${POOL_ROOT}"
success "rpool/ROOT/ubuntu mounted at ${POOL_ROOT}"

# ── Now create bpool datasets — /boot will land on top of the mounted root ────
mkdir -p "${POOL_ROOT}/boot"   # ensure target dir exists before mount
zfs create -o canmount=off -o mountpoint=none "${BPOOL}/BOOT"
zfs create -o canmount=on  -o mountpoint=/boot "${BPOOL}/BOOT/ubuntu"
mountpoint -q "${POOL_ROOT}/boot" || die "bpool/BOOT/ubuntu failed to mount at ${POOL_ROOT}/boot"
success "bpool/BOOT/ubuntu mounted at ${POOL_ROOT}/boot"

# [Patch 5] Mark the bpool boot dataset so ZFSBootMenu can pair it with rpool
zpool set bootfs="${BPOOL}/BOOT/ubuntu" "${BPOOL}"

# ── rpool child datasets (mount on top of the now-live root) ─────────────────

# /home
HOME_QUOTA_OPT=()
[[ "${HOME_QUOTA}" != "none" ]] && HOME_QUOTA_OPT=(-o quota="${HOME_QUOTA}")
zfs create -o mountpoint=/home "${HOME_QUOTA_OPT[@]}" "${RPOOL}/ROOT/ubuntu/home"

# /root (root user home)
zfs create -o mountpoint=/root -o com.sun:auto-snapshot=true "${RPOOL}/ROOT/ubuntu/root"
chmod 700 "${POOL_ROOT}/root"

# /srv
zfs create -o mountpoint=/srv "${RPOOL}/ROOT/ubuntu/srv"

# /tmp — exec on, no snapshots, sticky bit
zfs create \
    -o mountpoint=/tmp \
    -o com.sun:auto-snapshot=false \
    -o exec=on \
    -o setuid=off \
    "${RPOOL}/ROOT/ubuntu/tmp"
chmod 1777 "${POOL_ROOT}/tmp"

# /var — namespace container (directory lives in root dataset; children mount on top)
zfs create -o canmount=off -o mountpoint=/var "${RPOOL}/ROOT/ubuntu/var"

# /var/cache — high churn, no snapshots
zfs create \
    -o mountpoint=/var/cache \
    -o com.sun:auto-snapshot=false \
    "${RPOOL}/ROOT/ubuntu/var/cache"

# /var/lib — namespace container
zfs create -o canmount=off -o mountpoint=/var/lib "${RPOOL}/ROOT/ubuntu/var/lib"

# /var/lib/docker — Docker manages its own layers; no ZFS snapshots
zfs create \
    -o mountpoint=/var/lib/docker \
    -o com.sun:auto-snapshot=false \
    "${RPOOL}/ROOT/ubuntu/var/lib/docker"

# /var/log — keep snapshots for audit trail
zfs create -o mountpoint=/var/log "${RPOOL}/ROOT/ubuntu/var/log"

# /var/spool — no snapshots
zfs create \
    -o mountpoint=/var/spool \
    -o com.sun:auto-snapshot=false \
    "${RPOOL}/ROOT/ubuntu/var/spool"

# /var/tmp — no snapshots, no exec, sticky bit
zfs create \
    -o mountpoint=/var/tmp \
    -o com.sun:auto-snapshot=false \
    -o exec=off \
    -o setuid=off \
    "${RPOOL}/ROOT/ubuntu/var/tmp"
chmod 1777 "${POOL_ROOT}/var/tmp"

# /usr/local — survives OS reinstall if this dataset is kept
zfs create -o canmount=off -o mountpoint=/usr "${RPOOL}/ROOT/ubuntu/usr"
zfs create -o mountpoint=/usr/local           "${RPOOL}/ROOT/ubuntu/usr/local"

# ── Swap zvol ─────────────────────────────────────────────────────────────────
zfs create \
    -V "${SWAP_SIZE}" \
    -b "$(getconf PAGESIZE)" \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    "${RPOOL}/swap"

udevadm settle
sleep 1
mkswap -L swap "/dev/zvol/${RPOOL}/swap"
success "Swap zvol: /dev/zvol/${RPOOL}/swap  (${SWAP_SIZE})"

# ── Pool import cache — set from live env and copy to target ──────────────────
mkdir -p /etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "${RPOOL}"
zpool set cachefile=/etc/zfs/zpool.cache "${BPOOL}"

# [Patch 1] Set ZFSBootMenu commandline property HERE in the live env where the
# pool is actually imported. The same call inside the chroot is a no-op because
# the chroot cannot see the imported pools.
zfs set org.zfsbootmenu:commandline="" "${RPOOL}/ROOT/ubuntu"
success "ZFSBootMenu commandline property set on ${RPOOL}/ROOT/ubuntu"

success "All datasets created and mounted"
info "ZFS mount layout:"
zfs list -r -o name,mountpoint,canmount 2>/dev/null "${RPOOL}" "${BPOOL}" || true
echo ""

# ── debootstrap ──────────────────────────────────────────────────────────────
# debootstrap handles Ubuntu 26.04 packages correctly and, unlike mmdebstrap,
# does not require the target directory to be empty — so it works fine with
# ZFS child datasets already mounted at sub-paths of POOL_ROOT.
banner "Running debootstrap — ${UBUNTU_CODENAME}"

KEYRING_FLAG=()
[[ -n "${UBUNTU_KEYRING}" && -f "${UBUNTU_KEYRING}" ]] && \
    KEYRING_FLAG=(--keyring="${UBUNTU_KEYRING}")

info "debootstrap output is being logged to ${LOG}"
debootstrap \
    "${KEYRING_FLAG[@]}" \
    --include=locales,apt-utils,gpg,gpg-agent,ca-certificates,ubuntu-keyring \
    "${UBUNTU_CODENAME}" \
    "${POOL_ROOT}" \
    "${UBUNTU_MIRROR}" \
    || die "debootstrap failed — see ${LOG} for details"

success "debootstrap complete"

# ── Post-bootstrap: ZFS cache files + EFI mount ───────────────────────────────
mkdir -p "${POOL_ROOT}/etc/zfs"
cp /etc/zfs/zpool.cache "${POOL_ROOT}/etc/zfs/zpool.cache"
success "ZFS pool cache written to ${POOL_ROOT}/etc/zfs/zpool.cache"

# [Patch 3] Seed the zfs-mount-generator dataset cache from the live env.
mkdir -p "${POOL_ROOT}/etc/zfs/zfs-list.cache"
zfs list -H -t filesystem \
    -o name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand \
    2>/dev/null | grep "^${RPOOL}" \
    > "${POOL_ROOT}/etc/zfs/zfs-list.cache/${RPOOL}" || true
success "ZFS mount-generator cache seeded (${POOL_ROOT}/etc/zfs/zfs-list.cache/${RPOOL})"
zfs list -H -t filesystem \
    -o name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand \
    2>/dev/null | grep "^${BPOOL}" \
    > "${POOL_ROOT}/etc/zfs/zfs-list.cache/${BPOOL}" || true
success "ZFS mount-generator cache seeded (${POOL_ROOT}/etc/zfs/zfs-list.cache/${BPOOL})"

mkdir -p "${POOL_ROOT}/boot/efi"
mount "${EFI_PART}" "${POOL_ROOT}/boot/efi"
success "EFI partition mounted at ${POOL_ROOT}/boot/efi"

# ── Write configuration files into the target ─────────────────────────────────
banner "Writing configuration files"

echo "${HOSTNAME_NEW}" > "${POOL_ROOT}/etc/hostname"

cat > "${POOL_ROOT}/etc/hosts" <<HOSTS
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME_NEW}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

EFI_UUID="$(blkid -s UUID -o value "${EFI_PART}")"
cat > "${POOL_ROOT}/etc/fstab" <<FSTAB
# ZFS datasets are auto-mounted by zfs-mount.service — no entries here.
# EFI System Partition
UUID=${EFI_UUID}  /boot/efi  vfat  umask=0022,fmask=0022,dmask=0022  0  1
# Swap zvol
/dev/zvol/${RPOOL}/swap  none  swap  defaults  0  0
FSTAB

# DEB822 format (required for Ubuntu 24.04+; legacy sources.list is deprecated)
mkdir -p "${POOL_ROOT}/etc/apt/sources.list.d"
> "${POOL_ROOT}/etc/apt/sources.list"   # empty the legacy file to suppress warnings
cat > "${POOL_ROOT}/etc/apt/sources.list.d/ubuntu.sources" <<SOURCES
Types: deb
URIs: ${UBUNTU_MIRROR}
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-security ${UBUNTU_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES

cat > "${POOL_ROOT}/etc/locale.gen" <<LOCALEGEN
${LOCALE} UTF-8
en_US.UTF-8 UTF-8
LOCALEGEN

# ── Sanoid configuration ──────────────────────────────────────────────────────
mkdir -p "${POOL_ROOT}/etc/sanoid"
# Heredoc is unquoted so ${RPOOL} expands — dataset paths match the actual pool name.
cat > "${POOL_ROOT}/etc/sanoid/sanoid.conf" <<SANOIDCFG
###############################################
# Sanoid snapshot policy
###############################################

[template_system]
    hourly    = 24
    daily     = 30
    monthly   = 6
    yearly    = 0
    autosnap  = yes
    autoprune = yes

[template_home]
    hourly    = 48
    daily     = 60
    monthly   = 12
    yearly    = 2
    autosnap  = yes
    autoprune = yes

[template_logs]
    hourly    = 0
    daily     = 30
    monthly   = 6
    yearly    = 0
    autosnap  = yes
    autoprune = yes

[template_ignore]
    autosnap  = no
    autoprune = no

# ── Snapshot policies ──────────────────────────────────────────────────────────

[${RPOOL}/ROOT/ubuntu]
    use_template = system
    recursive    = no

[${RPOOL}/ROOT/ubuntu/home]
    use_template = home
    recursive    = yes

[${RPOOL}/ROOT/ubuntu/root]
    use_template = home
    recursive    = no

[${RPOOL}/ROOT/ubuntu/srv]
    use_template = system
    recursive    = no

[${RPOOL}/ROOT/ubuntu/usr/local]
    use_template = system
    recursive    = no

[${RPOOL}/ROOT/ubuntu/var/log]
    use_template = logs
    recursive    = no

# ── Excluded (high churn / externally managed) ─────────────────────────────────

[${RPOOL}/ROOT/ubuntu/var/cache]
    use_template = ignore

[${RPOOL}/ROOT/ubuntu/var/tmp]
    use_template = ignore

[${RPOOL}/ROOT/ubuntu/tmp]
    use_template = ignore

[${RPOOL}/ROOT/ubuntu/var/lib/docker]
    use_template = ignore

[${RPOOL}/ROOT/ubuntu/var/spool]
    use_template = ignore
SANOIDCFG

# ── apt pre/post snapshot hook ────────────────────────────────────────────────
mkdir -p "${POOL_ROOT}/etc/apt/apt.conf.d"
# Heredoc is unquoted so ${RPOOL} expands now; \$(date ...) is escaped so it
# expands at hook-execution time (not at write time).
cat > "${POOL_ROOT}/etc/apt/apt.conf.d/80-zfs-snapshot" <<APTHOOK
// Take ZFS snapshots around every apt/dpkg operation.
// Snapshots are named pre-apt-YYYYMMDD-HHMMSS / post-apt-YYYYMMDD-HHMMSS.
DPkg::Pre-Invoke  { "zfs snapshot -r ${RPOOL}/ROOT/ubuntu@pre-apt-\$(date +%Y%m%d-%H%M%S)  2>/dev/null || true"; };
DPkg::Post-Invoke { "zfs snapshot -r ${RPOOL}/ROOT/ubuntu@post-apt-\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"; };
APTHOOK

# ── ZFSBootMenu config (for post-install generate-zbm runs) ───────────────────
mkdir -p "${POOL_ROOT}/etc/zfsbootmenu"
mkdir -p "${POOL_ROOT}/etc/zfsbootmenu/dracut.conf.d"

cat > "${POOL_ROOT}/etc/zfsbootmenu/config.yaml" <<ZBMCFG
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d

Components:
  Enabled: false

EFI:
  ImageDir: /boot/efi/EFI/zbm
  Versions: 3
  Enabled: true

Kernel:
  CommandLine: ""
  Prefix: vmlinuz
ZBMCFG

cat > "${POOL_ROOT}/etc/zfsbootmenu/dracut.conf.d/zfsbootmenu.conf" <<'DRACUTCFG'
nofsck="yes"
DRACUTCFG

# ── Write the zfs-import-bpool.service unit ───────────────────────────────────
# Without this, the booted system may not reliably import bpool, causing
# kernel updates (update-initramfs) to write into a dead directory.
mkdir -p "${POOL_ROOT}/etc/systemd/system"
cat > "${POOL_ROOT}/etc/systemd/system/zfs-import-bpool.service" <<BPOOLUNIT
[Unit]
Description=Import ZFS bpool (boot pool)
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service
After=cryptsetup.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Import by name; -N means don't mount (zfs-mount handles that)
ExecStart=/sbin/zpool import -N -o cachefile=none ${BPOOL}

[Install]
WantedBy=zfs-import.target
BPOOLUNIT

# ── Bind-mount virtual filesystems ───────────────────────────────────────────
banner "Binding virtual filesystems for chroot"
mount --make-private --rbind /dev  "${POOL_ROOT}/dev"
mount --make-private --rbind /proc "${POOL_ROOT}/proc"
mount --make-private --rbind /sys  "${POOL_ROOT}/sys"
mount --make-private --rbind /run  "${POOL_ROOT}/run"
# Bind-mount rather than copy so the live system's DNS works during the chroot
# install without leaving a stale file on the target; NetworkManager/systemd-resolved
# will manage resolv.conf on first real boot.
touch "${POOL_ROOT}/etc/resolv.conf"
mount --bind /etc/resolv.conf "${POOL_ROOT}/etc/resolv.conf"
success "Virtual filesystems bound"

# ── Chroot ────────────────────────────────────────────────────────────────────
banner "Running chroot configuration"

# Passwords are NOT passed as env vars (they would appear in /proc/<pid>/environ).
# chpasswd is called from OUTSIDE the chroot after this block completes.
chroot "${POOL_ROOT}" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm-256color}" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    DEBIAN_FRONTEND=noninteractive \
    ADD_USER="${ADD_USER}" \
    NEW_USER="${NEW_USER}" \
    TIMEZONE="${TIMEZONE}" \
    LOCALE="${LOCALE}" \
    UBUNTU_CODENAME="${UBUNTU_CODENAME}" \
    RPOOL="${RPOOL}" \
    BPOOL="${BPOOL}" \
    HOSTNAME_NEW="${HOSTNAME_NEW}" \
    /bin/bash --login <<'CHROOTEOF'
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ci()  { echo -e "${CYAN}[chroot]${RESET} $*"; }
cok() { echo -e "${GREEN}[chroot OK]${RESET} $*"; }
cw()  { echo -e "${YELLOW}[chroot WARN]${RESET} $*"; }

# Locale
ci "Generating locale ${LOCALE}..."
locale-gen
update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}"

# Timezone
ci "Setting timezone: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
cok "Timezone set"

# apt update
ci "Updating package lists..."
apt-get update -qq

# Core packages
ci "Installing core packages..."
apt-get install -y --no-install-recommends \
    linux-image-generic \
    linux-headers-generic \
    linux-firmware \
    zfsutils-linux \
    zfs-initramfs \
    zfs-zed \
    openssh-server \
    network-manager \
    systemd-boot \
    systemd-boot-efi \
    efibootmgr \
    parted \
    gdisk \
    curl \
    wget \
    gnupg \
    ca-certificates \
    apt-transport-https \
    locales \
    tzdata \
    bash-completion \
    man-db \
    vim \
    less \
    sudo \
    sanoid \
    libconfig-inifiles-perl
cok "Core packages installed"
# Note: dracut is intentionally excluded here. The ZFSBootMenu EFI binary is
# downloaded pre-built (no dracut needed). If the ZBM apt package installs
# successfully below it will pull in dracut itself. Keeping dracut out of the
# base install avoids update-alternatives conflicts with initramfs-tools.

# Enable ZFS services
ci "Enabling ZFS services..."
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs-zed.service
# Dedicated bpool import service (unit file was written before chroot)
systemctl enable zfs-import-bpool.service
cok "ZFS services enabled (including zfs-import-bpool)"

# [Patch 3] Link the ZED hook that keeps the zfs-mount-generator cache current.
# Without this, the cache file seeded from the live env becomes stale after the
# first kernel update or dataset change, breaking mount ordering on subsequent boots.
ZED_HOOK_SRC="/usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh"
if [[ -f "${ZED_HOOK_SRC}" ]]; then
    mkdir -p /etc/zfs/zed.d
    ln -sf "${ZED_HOOK_SRC}" /etc/zfs/zed.d/history_event-zfs-list-cacher.sh
    cok "ZED zfs-mount-generator cache hook linked"
else
    cw "ZED list cacher hook not found at ${ZED_HOOK_SRC}"
    cw "After install, check: ls /usr/lib/zfs-linux/zed.d/ and link the cacher manually"
fi

# Build initramfs with ZFS support
ci "Building initramfs (all installed kernels)..."
update-initramfs -c -k all
cok "initramfs built"

# Sanoid snapshot timer
ci "Enabling sanoid.timer..."
systemctl enable sanoid.timer
cok "sanoid.timer enabled"

# ── ZFSBootMenu ───────────────────────────────────────────────────────────────
ci "Setting up ZFSBootMenu..."
mkdir -p /boot/efi/EFI/zbm

# Download the pre-built EFI binary from the official GitHub release.
# The asset URL is read directly from the GitHub API response so it stays
# correct across ZFSBootMenu releases regardless of filename changes.
ZBM_API="https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest"
ZBM_EFI_REL=""
ZBM_TMP="$(mktemp /tmp/zbm-efi.XXXXXX)"
ZBM_SHA_TMP="$(mktemp /tmp/zbm-sha.XXXXXX)"

_zbm_api_json="$(curl -fsSL "${ZBM_API}" 2>/dev/null)" || _zbm_api_json=""
if [[ -n "${_zbm_api_json}" ]]; then
    ZBM_VERSION="$(echo "${_zbm_api_json}" | grep '"tag_name"' \
        | sed 's/.*"v\([^"]*\)".*/\1/' | head -1)"
    # Extract the release EFI URL — prefer highest kernel version via sort -V.
    # "release" builds are the standard boot image; "recovery" builds include
    # extra rescue tools but are larger and unnecessary here.
    ZBM_URL="$(echo "${_zbm_api_json}" | grep '"browser_download_url"' \
        | grep 'release.*x86_64.*\.EFI"' | grep -v '\.sha256"' \
        | awk -F'"' '{print $4}' | sort -V | tail -1)"
    ZBM_SHA_URL="${ZBM_URL}.sha256"
    ci "Latest ZFSBootMenu release: v${ZBM_VERSION} — ${ZBM_URL##*/}"
    if [[ -n "${ZBM_URL}" ]] && curl -fsSL --progress-bar -o "${ZBM_TMP}" "${ZBM_URL}" 2>/dev/null; then
        if curl -fsSL -o "${ZBM_SHA_TMP}" "${ZBM_SHA_URL}" 2>/dev/null; then
            EXPECTED_HASH="$(awk '{print $1}' "${ZBM_SHA_TMP}")"
            ACTUAL_HASH="$(sha256sum "${ZBM_TMP}" | awk '{print $1}')"
            if [[ "${EXPECTED_HASH}" == "${ACTUAL_HASH}" ]]; then
                cok "ZFSBootMenu EFI checksum verified (SHA256: ${ACTUAL_HASH:0:16}...)"
                mv "${ZBM_TMP}" /boot/efi/EFI/zbm/vmlinuz.EFI
                ZBM_EFI_REL="/EFI/zbm/vmlinuz.EFI"
            else
                cw "ZFSBootMenu EFI checksum MISMATCH — discarding download"
                cw "  Expected: ${EXPECTED_HASH}"
                cw "  Got:      ${ACTUAL_HASH}"
            fi
        else
            cw "Checksum file unavailable — installing unverified binary"
            mv "${ZBM_TMP}" /boot/efi/EFI/zbm/vmlinuz.EFI
            ZBM_EFI_REL="/EFI/zbm/vmlinuz.EFI"
        fi
    else
        cw "ZFSBootMenu EFI binary download failed."
    fi
else
    cw "Could not reach GitHub API to find ZFSBootMenu release."
fi
rm -f "${ZBM_TMP}" "${ZBM_SHA_TMP}"

if [[ -z "${ZBM_EFI_REL}" ]]; then
    cw "No ZFSBootMenu EFI binary available."
    cw "Place it at /boot/efi/EFI/zbm/vmlinuz.EFI before rebooting."
    ZBM_EFI_REL="/EFI/zbm/vmlinuz.EFI"
fi

# org.zfsbootmenu:commandline was already set from the live environment (outside
# this chroot) where the pool was actually imported. Doing it here is a no-op.

# ── systemd-boot ──────────────────────────────────────────────────────────────
ci "Installing systemd-boot to ESP..."
bootctl install --esp-path=/boot/efi 2>/dev/null || bootctl install
cok "systemd-boot installed"

mkdir -p /boot/efi/loader/entries

cat > /boot/efi/loader/loader.conf <<LOADERCFG
default  zfsbootmenu.conf
timeout  3
console-mode max
editor   no
LOADERCFG

# systemd-boot entry: chainload ZFSBootMenu EFI binary
cat > /boot/efi/loader/entries/zfsbootmenu.conf <<ZBMENTRY
title   ZFSBootMenu
efi     ${ZBM_EFI_REL}
ZBMENTRY
cok "systemd-boot configured (default entry → ZFSBootMenu)"

# ── Network ───────────────────────────────────────────────────────────────────
ci "Enabling NetworkManager..."
systemctl enable NetworkManager
systemctl disable systemd-networkd 2>/dev/null || true
systemctl mask    systemd-networkd 2>/dev/null || true

# ── SSH ───────────────────────────────────────────────────────────────────────
ci "Enabling and hardening SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl enable ssh

# ── User account / root access ────────────────────────────────────────────────
# Passwords are set via pipe from OUTSIDE the chroot after this block completes.
if [[ "${ADD_USER}" == "yes" ]]; then
    ci "Creating user: ${NEW_USER}"
    useradd -m -s /bin/bash -G sudo,adm,audio,video,plugdev,netdev "${NEW_USER}"
    echo "${NEW_USER} ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/${NEW_USER}"
    chmod 440 "/etc/sudoers.d/${NEW_USER}"
    if ! visudo -c -f "/etc/sudoers.d/${NEW_USER}" 2>/dev/null; then
        rm -f "/etc/sudoers.d/${NEW_USER}"
        die "sudoers.d/${NEW_USER} failed visudo validation — file removed to prevent sudo lockout"
    fi
    cok "User ${NEW_USER} created (password set after chroot; root remains locked)"
else
    ci "No non-root user requested — root password will be set after chroot"
fi

# ── machine-id ────────────────────────────────────────────────────────────────
[[ -s /etc/machine-id ]] || systemd-machine-id-setup 2>/dev/null || true

# [Patch 2] Generate a unique host ID.
# ZFS uses /etc/hostid to bind pool imports to the correct host. Without it,
# importing pools across different machines (or after a reinstall) produces
# "hostid mismatch" warnings and may require `zpool import -f`.
ci "Generating ZFS host ID (/etc/hostid)..."
rm -f /etc/hostid
if command -v zgenhostid &>/dev/null; then
    zgenhostid
    cok "Host ID generated: $(hostid)"
else
    # Fallback: write 4 random bytes — same format as zgenhostid
    dd if=/dev/urandom bs=4 count=1 2>/dev/null > /etc/hostid
    cok "Host ID generated (dd fallback): $(hostid 2>/dev/null || hexdump -e '4/1 "%02x"' /etc/hostid)"
fi

# ── Final apt cleanup ─────────────────────────────────────────────────────────
ci "Cleaning apt cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━  chroot configuration complete  ━━━━━━━━━━${RESET}"
CHROOTEOF

success "Chroot configuration complete"

# ── Set passwords via pipe — never exposed in /proc environ ──────────────────
banner "Setting passwords"
if [[ "${ADD_USER}" == "yes" ]]; then
    info "Setting ${NEW_USER} password..."
    printf '%s:%s\n' "${NEW_USER}" "${USER_PASSWORD}" | chroot "${POOL_ROOT}" chpasswd
    success "${NEW_USER} password set; root account remains locked"
else
    info "Setting root password..."
    printf 'root:%s\n' "${ROOT_PASSWORD}" | chroot "${POOL_ROOT}" chpasswd
    success "Root password set"
fi

# ── Tear down bind mounts ─────────────────────────────────────────────────────
banner "Unmounting virtual filesystems"
umount "${POOL_ROOT}/etc/resolv.conf" 2>/dev/null || true
umount -Rl "${POOL_ROOT}/run"  2>/dev/null || true
umount -Rl "${POOL_ROOT}/sys"  2>/dev/null || true
umount -Rl "${POOL_ROOT}/proc" 2>/dev/null || true
umount -Rl "${POOL_ROOT}/dev"  2>/dev/null || true
success "Virtual filesystems unmounted"

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Installation summary"
echo -e "  ${BOLD}Target disk:${RESET}   ${TARGET_DISK}"
echo -e "  ${BOLD}EFI:${RESET}           ${EFI_PART}"
echo -e "  ${BOLD}bpool:${RESET}         ${BPOOL_PART}  →  /boot"
echo -e "  ${BOLD}rpool:${RESET}         ${RPOOL_PART}  →  /"
echo -e "  ${BOLD}Hostname:${RESET}      ${HOSTNAME_NEW}"
if [[ "${ADD_USER}" == "yes" ]]; then
    echo -e "  ${BOLD}User:${RESET}          ${NEW_USER}  (root locked)"
else
    echo -e "  ${BOLD}Access:${RESET}        root password login"
fi
echo -e "  ${BOLD}Ubuntu:${RESET}        ${UBUNTU_CODENAME}"
echo -e "  ${BOLD}Timezone:${RESET}      ${TIMEZONE}  /  Locale: ${LOCALE} (hardcoded)"
echo -e "  ${BOLD}Swap:${RESET}          ${SWAP_SIZE} zvol on rpool"
echo -e "  ${BOLD}Bootloader:${RESET}    systemd-boot → ZFSBootMenu (kexec) → kernel"
echo -e "  ${BOLD}Snapshots:${RESET}     sanoid.timer + apt pre/post hooks"
echo ""
info "ZFS dataset layout:"
zfs list -r -o name,used,avail,mountpoint,canmount 2>/dev/null \
    "${RPOOL}" "${BPOOL}" || true
echo ""

# ── First-boot checklist ──────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}━━━━━━━━━━  First-boot checklist  ━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}1. Verify ZFSBootMenu loads${RESET}"
echo    "     Reboot → systemd-boot menu → ZFSBootMenu should appear."
echo    "     If the ZBM EFI binary was not downloaded, place it at:"
echo    "       /boot/efi/EFI/zbm/vmlinuz.EFI"
echo    "     or run: generate-zbm  (if the apt package installed)"
echo ""
echo -e "  ${BOLD}2. Verify sanoid snapshots${RESET}"
echo    "     sudo sanoid --cron --verbose"
echo    "     sudo zfs list -t snapshot -r ${RPOOL}/ROOT/ubuntu"
echo ""
echo -e "  ${BOLD}3. Test apt snapshot hook${RESET}"
echo    "     sudo apt-get install --reinstall bash   # triggers pre/post snapshots"
echo    "     sudo zfs list -t snapshot | grep apt"
echo ""
echo -e "  ${BOLD}4. Harden SSH (if not already done)${RESET}"
if [[ "${ADD_USER}" == "yes" ]]; then
    echo    "     Add your public key:  ssh-copy-id ${NEW_USER}@${HOSTNAME_NEW}"
else
    echo    "     Add your public key:  ssh-copy-id root@${HOSTNAME_NEW}"
fi
echo    "     Then disable password auth in /etc/ssh/sshd_config:"
echo    "       PasswordAuthentication no"
echo    "       PubkeyAuthentication yes"
echo ""
echo -e "  ${BOLD}5. Check ZFS pool health${RESET}"
echo    "     zpool status"
echo    "     zpool list"
echo ""
echo -e "  ${BOLD}6. Verify bpool imports at boot${RESET}"
echo    "     systemctl status zfs-import-bpool.service"
echo ""

# ── Enter chroot or finish ────────────────────────────────────────────────────
banner "What would you like to do?"
echo "  1)  Enter interactive chroot — verify, make additional changes"
echo "  2)  Export pools and exit  — ready to remove media and reboot"
echo "  3)  Exit without exporting — you will handle pool export manually"
echo ""
read -rp "$(echo -e "${YELLOW}Choice [1/2/3]: ${RESET}")" _FINAL

_rebind() {
    mount --make-private --rbind /dev  "${POOL_ROOT}/dev"
    mount --make-private --rbind /proc "${POOL_ROOT}/proc"
    mount --make-private --rbind /sys  "${POOL_ROOT}/sys"
    mount --make-private --rbind /run  "${POOL_ROOT}/run"
}

_unbind() {
    umount "${POOL_ROOT}/etc/resolv.conf" 2>/dev/null || true
    umount -Rl "${POOL_ROOT}/run"  2>/dev/null || true
    umount -Rl "${POOL_ROOT}/sys"  2>/dev/null || true
    umount -Rl "${POOL_ROOT}/proc" 2>/dev/null || true
    umount -Rl "${POOL_ROOT}/dev"  2>/dev/null || true
}

_export() {
    umount "${POOL_ROOT}/boot/efi" 2>/dev/null || true
    info "Exporting ${BPOOL}..."
    zpool export "${BPOOL}" || warn "Could not export ${BPOOL} — try: zpool export ${BPOOL}"
    info "Exporting ${RPOOL}..."
    zpool export "${RPOOL}" || warn "Could not export ${RPOOL} — try: zpool export ${RPOOL}"
    success "Pools exported. Remove live media and reboot."
}

case "${_FINAL}" in
    1)
        info "Entering chroot. Type 'exit' to return."
        _rebind
        chroot "${POOL_ROOT}" /bin/bash --login || true
        info "Returned from chroot."
        _unbind
        echo ""
        read -rp "$(echo -e "${YELLOW}Export pools and finish? [Y/n]: ${RESET}")" _EXP
        [[ "${_EXP,,}" == "n" ]] || _export
        ;;
    2)
        _export
        echo -e "\n${GREEN}${BOLD}Remove live media and reboot!${RESET}"
        ;;
    3)
        warn "Exiting without exporting. When ready:"
        warn "  umount -Rl ${POOL_ROOT}"
        warn "  zpool export ${BPOOL}"
        warn "  zpool export ${RPOOL}"
        ;;
    *)
        warn "Unrecognised choice — exiting without action."
        ;;
esac

echo ""
success "install-ubuntu-zfs.sh done."
