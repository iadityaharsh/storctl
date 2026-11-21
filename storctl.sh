#!/usr/bin/env bash
# storctl.sh — attach CIFS/SMB, NFS, iSCSI or NVMe-oF storage to Linux.
#
# One self-contained script, in the spirit of community-scripts.org:
#
#   bash -c "$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
#
# It installs the client packages it needs, mounts the share/device right away,
# verifies it, and records the configuration in /etc/fstab so it comes back
# after a reboot.  Nothing is installed permanently except the mount's own
# configuration, credentials and (for NVMe-oF) a systemd unit.
#
# Safe to re-run: the same command lets you inspect, mount, unmount or remove
# the mounts it created.
#
# Environment (mostly for testing):
#   STORCTL_ROOT=/some/dir     relocate every system path under /some/dir
#   STORCTL_DRY_RUN=1          log commands instead of running them
set -Eeuo pipefail

APP_NAME="storctl"
APP_VERSION="1.0.2"
BRAND_MARK="▸▤"
BACKTITLE="$BRAND_MARK $APP_NAME $APP_VERSION · storage control for Linux"
MARK_BEGIN='# >>> storctl managed block (do not edit) >>>'
MARK_END='# <<< storctl managed block <<<'

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------
ROOT="${STORCTL_ROOT:-}"
DRY_RUN="${STORCTL_DRY_RUN:-0}"
TEST_MODE="${STORCTL_ROOT:+1}"

syspath() { printf '%s%s' "$ROOT" "$1"; }

home_dir() {
    local home=${HOME:-}
    if [[ -z $home ]]; then
        home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
    fi
    [[ -n $home ]] || home=/tmp
    printf '%s' "$home"
}

# Mount definitions and state live in the invoking user's config directory by
# default; only the test harness relocates them under STORCTL_ROOT.
default_config_dir() {
    if [[ -n ${STORCTL_ROOT:-} ]]; then
        syspath /etc/storctl
        return 0
    fi
    printf '%s' "${XDG_CONFIG_HOME:-$(home_dir)/.config}/storctl"
}

CONFIG_DIR=$(default_config_dir)
FSTAB=$(syspath /etc/fstab)
FSTAB_BAK=$(syspath /etc/fstab.storctl.bak)
UNITS_DIR=$(syspath /etc/systemd/system)

# User preferences live in the invoking user's home, never in /etc.  They are
# deliberately independent of CONFIG_DIR so the setting that chooses the
# config directory is always discoverable.
settings_path() {
    if [[ -n ${STORCTL_SETTINGS:-} ]]; then
        printf '%s' "$STORCTL_SETTINGS"
        return 0
    fi
    if [[ -n ${STORCTL_ROOT:-} ]]; then
        syspath /etc/storctl/settings.conf
        return 0
    fi
    printf '%s' "${XDG_CONFIG_HOME:-$(home_dir)/.config}/storctl/settings.conf"
}

LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/storctl.XXXXXX.log")
KEEP_LOG=0
cleanup() { ((KEEP_LOG == 0)) && rm -f "$LOG_FILE" 2>/dev/null; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_ACC=$'\033[36m'
    if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* ]]; then
        C_LOGO=$'\033[38;2;255;122;26m'
    else
        C_LOGO=$'\033[38;5;208m'
    fi
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""
    C_LOGO=""
fi

# Nord-inspired dark palette: black/gray for Polar Night, lightgray/white for
# Snow Storm, and brown as the orange substitute where Nord would use blue.
# Buttons keep the stock high-contrast focus so the selection is always visible.
apply_tui_theme() {
    [[ -n ${NEWT_COLORS:-} || -n ${STORCTL_NO_THEME:-} ]] && return 0
    local colors
    colors=$(tput colors 2>/dev/null || printf '16')
    if [[ $colors =~ ^[0-9]+$ ]] && ((colors >= 256)); then
        # xterm-256 approximations of the logo palette:
        #   #1B1F23 -> 234, #FF7A1A -> 208, #F3F0EA -> 255, #E8EBEE -> 255.
        NEWT_COLORS='
root=color255,color234
window=color255,color234
border=color208,color234
shadow=color234,color234
title=color234,color208
roottext=color208,color234
button=color234,color208
actbutton=color208,color234
compactbutton=color234,color208
checkbox=color255,color234
actcheckbox=color234,color208
entry=color255,color234
label=color255,color234
listbox=color255,color234
actlistbox=color234,color208
sellistbox=color234,color208
actsellistbox=color234,color208
textbox=color255,color234
acttextbox=color234,color208
helpline=color250,color234
emptyscale=,color234
fullscale=,color208
disentry=color243,color234
'
    else
        NEWT_COLORS='
root=lightgray,black
window=lightgray,black
border=brown,black
shadow=black,black
title=white,brown
roottext=brown,black
button=lightgray,black
actbutton=black,lightgray
compactbutton=lightgray,black
checkbox=lightgray,black
actcheckbox=white,brown
entry=white,black
label=lightgray,black
listbox=lightgray,black
actlistbox=white,brown
sellistbox=white,brown
actsellistbox=white,brown
textbox=lightgray,black
acttextbox=white,brown
helpline=lightgray,black
emptyscale=,black
fullscale=,brown
disentry=gray,black
'
    fi
    export NEWT_COLORS
}

msg_info() { printf '  %s•%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
msg_ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_RESET" "$1"; }
msg_warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_RESET" "$1"; }
msg_err()  { printf '  %s✗%s %s\n' "$C_ERR" "$C_RESET" "$1" >&2; }
die()      { msg_err "$1"; exit "${2:-1}"; }
mounted_phrase() {
    if ((DRY_RUN)); then
        printf 'would be mounted at'
    else
        printf 'is mounted at'
    fi
}
box_title() {
    if ((DRY_RUN)); then
        printf 'Dry run'
    else
        printf 'Mounted'
    fi
}

print_banner() {
    printf '\n%s%s' "$C_LOGO" "$C_BOLD"
    cat <<'BANNER'
███████ ████████  ██████  ██████   ██████ ████████ ██
██         ██    ██    ██ ██   ██ ██         ██    ██
███████    ██    ██    ██ ██████  ██         ██    ██
     ██    ██    ██    ██ ██   ██ ██         ██    ██
███████    ██     ██████  ██   ██  ██████    ██    ███████
BANNER
    printf '%s' "$C_RESET"
}

# ---------------------------------------------------------------------------
# user preferences (~/.config/storctl/settings.conf)
# ---------------------------------------------------------------------------
SETTINGS_FILE=$(settings_path)
SMB_VERSION=3.1.1
NFS_VERSION=4.2
ISCSI_PORT=3260
ISCSI_LUN=0
NVME_TRANSPORT=tcp
NVME_PORT=4420
DEFAULT_AUTOMOUNT=boot
MOUNT_ROOT=/mnt
CREDS_DIR=$(syspath /etc/storctl/credentials)

dedicated_dir_ok() {
    local v=${1%/}
    [[ -n $v && $v == /* && $v != *[[:space:]]* ]] || return 1
    [[ $v != *'"'* ]] || return 1
    # require a dedicated subdirectory, never a system directory itself
    local slashes=${v//[^\/]/}
    (( ${#slashes} >= 2 )) || return 1
    case $v in
        /etc|/usr|/var|/bin|/sbin|/lib|/lib64|/boot|/home|/root|/tmp|/opt|/srv|/dev|/proc|/sys|/run)
            return 1
            ;;
    esac
    return 0
}

creds_dir_ok() { dedicated_dir_ok "$1"; }
config_dir_ok() { dedicated_dir_ok "$1"; }

load_settings() {
    SMB_VERSION=3.1.1
    NFS_VERSION=4.2
    ISCSI_PORT=3260
    ISCSI_LUN=0
    NVME_TRANSPORT=tcp
    NVME_PORT=4420
    DEFAULT_AUTOMOUNT=boot
    MOUNT_ROOT=/mnt
    CREDS_DIR=$(syspath /etc/storctl/credentials)
    CONFIG_DIR=$(default_config_dir)
    [[ -f $SETTINGS_FILE ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case $key in
            SMB_VERSION)
                [[ $value =~ ^(3\.1\.1|3\.0|2\.1|1\.0)$ ]] && SMB_VERSION=$value
                ;;
            NFS_VERSION)
                [[ $value =~ ^(4\.2|4\.1|4\.0|3)$ ]] && NFS_VERSION=$value
                ;;
            ISCSI_PORT)
                [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) \
                    && ISCSI_PORT=$value
                ;;
            ISCSI_LUN)
                [[ $value =~ ^[0-9]+$ ]] && ISCSI_LUN=$value
                ;;
            NVME_TRANSPORT)
                [[ $value =~ ^(tcp|rdma)$ ]] && NVME_TRANSPORT=$value
                ;;
            NVME_PORT)
                [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) \
                    && NVME_PORT=$value
                ;;
            DEFAULT_AUTOMOUNT)
                [[ $value =~ ^(boot|access|manual)$ ]] && DEFAULT_AUTOMOUNT=$value
                ;;
            MOUNT_ROOT)
                [[ $value == /* && $value != *[[:space:]]* ]] && MOUNT_ROOT=${value%/}
                ;;
            CREDS_DIR)
                if creds_dir_ok "$value"; then
                    CREDS_DIR=${value%/}
                fi
                ;;
            CONFIG_DIR)
                if config_dir_ok "$value"; then
                    CONFIG_DIR=${value%/}
                fi
                ;;
        esac
    done <"$SETTINGS_FILE"
    [[ -n $MOUNT_ROOT ]] || MOUNT_ROOT=/
    if ! creds_dir_ok "$CREDS_DIR"; then
        CREDS_DIR=$(syspath /etc/storctl/credentials)
    fi
    if ! config_dir_ok "$CONFIG_DIR"; then
        CONFIG_DIR=$(default_config_dir)
    fi
}

save_settings() {
    local dir tmp
    dir=$(dirname "$SETTINGS_FILE")
    if ! mkdir -p "$dir" 2>/dev/null; then
        msg_err "cannot create $dir"
        return 1
    fi
    tmp=$(mktemp "$dir/.settings.XXXXXX") || return 1
    {
        printf '# storctl user preferences (%s)\n' "$APP_NAME"
        printf 'SMB_VERSION=%s\n' "$SMB_VERSION"
        printf 'NFS_VERSION=%s\n' "$NFS_VERSION"
        printf 'ISCSI_PORT=%s\n' "$ISCSI_PORT"
        printf 'ISCSI_LUN=%s\n' "$ISCSI_LUN"
        printf 'NVME_TRANSPORT=%s\n' "$NVME_TRANSPORT"
        printf 'NVME_PORT=%s\n' "$NVME_PORT"
        printf 'DEFAULT_AUTOMOUNT=%s\n' "$DEFAULT_AUTOMOUNT"
        printf 'MOUNT_ROOT=%s\n' "$MOUNT_ROOT"
        printf 'CREDS_DIR=%s\n' "$CREDS_DIR"
        printf 'CONFIG_DIR=%s\n' "$CONFIG_DIR"
    } >"$tmp"
    chmod 0600 "$tmp"
    if ! mv -f "$tmp" "$SETTINGS_FILE"; then
        rm -f "$tmp"
        msg_err "could not write $SETTINGS_FILE"
        return 1
    fi
    return 0
}

load_settings
MOUNTS_DIR="$CONFIG_DIR/mounts"
STATE_FILE="$CONFIG_DIR/state.json"

SPIN_TEXT=""
spin_until() {
    local pid=$1 i=0 frames=('|' '/' '-' '\\')
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K  %s%s%s %s' "$C_DIM" "${frames[i%4]}" "$C_RESET" "$SPIN_TEXT"
        i=$((i + 1))
        sleep 0.12
    done
}

# run_step <text> <command...>  — runs quietly, shows a spinner, aborts on error.
run_step() {
    local text=$1
    shift
    if ((DRY_RUN)); then
        local shown="$*"
        shown=${shown#as_root }
        shown=${shown#as_root}
        printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$shown"
        return 0
    fi
    SPIN_TEXT=$text
    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$! rc=0
    spin_until "$pid"
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if ((rc == 0)); then
        msg_ok "$text"
        return 0
    fi
    msg_err "$text"
    printf '%s%s%s\n' "$C_DIM" "$(tail -n 6 "$LOG_FILE" 2>/dev/null)" "$C_RESET" >&2
    return "$rc"
}

# run a command as root, aborting on failure
as_root() {
    if ((EUID == 0)) || [[ -n $TEST_MODE ]]; then
        "$@"
    else
        sudo -n -- "$@"
    fi
}

# capture stdout of a privileged command; stderr goes to the log
root_capture() {
    if ((DRY_RUN)); then
        return 1
    fi
    if ((EUID == 0)) || [[ -n $TEST_MODE ]]; then
        "$@" 2>>"$LOG_FILE"
    else
        sudo -n -- "$@" 2>>"$LOG_FILE"
    fi
}

ensure_dir() {
    local dir=$1
    [[ -d $dir ]] && return 0
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s mkdir -p %s\n' "$C_DIM" "$C_RESET" "$dir"
        return 0
    fi
    as_root mkdir -p "$dir"
}

install_file() { # src dest mode
    local src=$1 dest=$2 mode=$3
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s write %s (mode %s)\n' "$C_DIM" "$C_RESET" "$dest" "$mode"
        rm -f "$src"
        return 0
    fi
    ensure_dir "$(dirname "$dest")"
    if ((EUID == 0)) || [[ -n $TEST_MODE ]]; then
        install -m "$mode" "$src" "$dest"
    else
        sudo -n -- install -m "$mode" -o root -g root "$src" "$dest"
    fi
}

# Config files live under the invoking user's home by default, so they should
# be created and owned by that user -- not root.
config_owned_by_user() {
    local home
    home=$(home_dir)
    [[ $1 == "$home"/* || $1 == "${XDG_CONFIG_HOME:-$home/.config}"/* ]]
}

ensure_config_dir() {
    local dir=$1
    [[ -d $dir ]] && return 0
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s mkdir -p %s\n' "$C_DIM" "$C_RESET" "$dir"
        return 0
    fi
    if mkdir -p "$dir" 2>/dev/null; then
        return 0
    fi
    as_root mkdir -p "$dir"
    if ((EUID != 0)) && config_owned_by_user "$dir"; then
        as_root chown "$(id -u):$(id -g)" "$dir" 2>/dev/null || true
    fi
}

install_config_file() { # src dest mode
    local src=$1 dest=$2 mode=$3 dir owner=(-o root -g root)
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s write %s (mode %s)\n' "$C_DIM" "$C_RESET" "$dest" "$mode"
        rm -f "$src"
        return 0
    fi
    dir=$(dirname "$dest")
    ensure_config_dir "$dir"
    if ((EUID == 0)) || [[ -n $TEST_MODE ]]; then
        install -m "$mode" "$src" "$dest"
        return 0
    fi
    if config_owned_by_user "$dir"; then
        owner=(-o "$(id -u)" -g "$(id -g)")
    fi
    if [[ -w $dir ]] && install -m "$mode" "$src" "$dest" 2>/dev/null; then
        return 0
    fi
    sudo -n -- install -m "$mode" "${owner[@]}" "$src" "$dest"
}

require_sudo() {
    ((EUID == 0)) && return 0
    [[ -n $TEST_MODE ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed"
    sudo -v || die "could not obtain administrator rights"
}

# Refresh the sudo timestamp if it expired while the menu sat idle.
require_sudo_fresh() {
    ((EUID == 0)) && return 0
    [[ -n $TEST_MODE || $DRY_RUN == 1 ]] && return 0
    sudo -n true >/dev/null 2>&1 && return 0
    printf '%s\n' "Administrator rights are needed again."
    sudo -v || die "could not refresh administrator rights"
}

# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------
detect_pm() {
    local pm
    for pm in apt-get dnf pacman zypper; do
        if command -v "$pm" >/dev/null 2>&1; then
            printf '%s' "$pm"
            return 0
        fi
    done
    return 1
}

pkg_install() {
    local pkg=$1 pm
    pm=$(detect_pm) || return 1
    case $pm in
        apt-get)
            as_root env DEBIAN_FRONTEND=noninteractive apt-get update
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
            ;;
        dnf)    as_root dnf install -y "$pkg" ;;
        pacman) as_root pacman -S --noconfirm --needed "$pkg" ;;
        zypper) as_root zypper --non-interactive install "$pkg" ;;
    esac
}

dep_binary() {
    case $1 in
        cifs)   printf 'mount.cifs' ;;
        nfs)    printf 'mount.nfs' ;;
        iscsi)  printf 'iscsiadm' ;;
        nvmeof) printf 'nvme' ;;
    esac
}

dep_package() {
    local key=$1 pm
    pm=$(detect_pm) || pm=apt-get
    case $pm:$key in
        *:cifs) printf 'cifs-utils' ;;
        apt-get:nfs) printf 'nfs-common' ;;
        dnf:nfs|pacman:nfs) printf 'nfs-utils' ;;
        zypper:nfs) printf 'nfs-client' ;;
        apt-get:iscsi|pacman:iscsi|zypper:iscsi) printf 'open-iscsi' ;;
        dnf:iscsi) printf 'iscsi-initiator-utils' ;;
        *:nvmeof) printf 'nvme-cli' ;;
        *) printf '%s' "$key" ;;
    esac
}

ensure_dep() {
    local key=$1 bin pkg
    bin=$(dep_binary "$key")
    command -v "$bin" >/dev/null 2>&1 && return 0
    pkg=$(dep_package "$key")
    if ! ui_yesno "Missing dependency" \
        "$bin was not found.\n\nInstall the package '$pkg' now?"; then
        return 1
    fi
    run_step "Installing $pkg" pkg_install "$pkg"
    hash -r
    if ! command -v "$bin" >/dev/null 2>&1; then
        if ((DRY_RUN)); then
            return 0
        fi
        ui_msg "Dependency missing" \
            "Installed '$pkg' but '$bin' is still not on PATH.\n\nInstall it manually and re-run."
        return 1
    fi
    return 0
}

ensure_whiptail() {
    command -v whiptail >/dev/null 2>&1 && return 0
    printf '%s\n' "whiptail is required for the interactive interface."
    require_sudo
    pkg_install whiptail || die "could not install whiptail (package: whiptail)"
    hash -r
    command -v whiptail >/dev/null 2>&1 || die "whiptail is still unavailable"
}

# ---------------------------------------------------------------------------
# whiptail wrappers
# ---------------------------------------------------------------------------
# Keep dialogs inside the terminal. Fixed 88-column boxes get clipped on
# 80-column terminals, which hides the button bar.
term_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || printf '24')
    cols=$(tput cols 2>/dev/null || printf '80')
    [[ $rows =~ ^[0-9]+$ ]] && ((rows >= 10)) || rows=24
    [[ $cols =~ ^[0-9]+$ ]] && ((cols >= 24)) || cols=80
    printf '%s %s\n' "$rows" "$cols"
}

fit_dialog() { # requested rows, requested cols
    local rows cols h=$1 w=$2
    read -r rows cols < <(term_size)
    ((h > rows - 2)) && h=$((rows - 2))
    ((w > cols - 2)) && w=$((cols - 2))
    ((h < 8)) && h=8
    ((w < 24)) && w=24
    printf '%s %s\n' "$h" "$w"
}

ui_input() {
    local title=$1 prompt=$2 default=${3:-} h w
    read -r h w < <(fit_dialog 11 74)
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" \
        \
        --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3
}

ui_password() {
    local title=$1 prompt=$2 h w
    read -r h w < <(fit_dialog 11 74)
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" \
        \
        --passwordbox "$prompt" "$h" "$w" 3>&1 1>&2 2>&3
}

ui_menu() {
    local title=$1 prompt=${2//\\n/$'\n'} h w list_h
    shift 2
    local extra=()
    if [[ -n ${MENU_DEFAULT:-} ]]; then
        extra+=(--default-item "$MENU_DEFAULT")
    fi
    read -r h w < <(fit_dialog 22 78)
    list_h=$((h - 8))
    ((list_h < 4)) && list_h=4
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" "${extra[@]}" \
        \
        --menu "$prompt" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3
}

# A menu with readable labels only (no duplicate tag column).
ui_menu_labels() {
    local title=$1 prompt=${2//\\n/$'\n'} h w list_h label count wanted
    shift 2
    count=$#
    local args=() extra=()
    for label in "$@"; do
        args+=("$label" "")
    done
    if [[ -n ${MENU_DEFAULT:-} ]]; then
        extra+=(--default-item "$MENU_DEFAULT")
    fi
    read -r h w < <(fit_dialog 22 78)
    # --fb draws real button boxes, which take an extra line. Keep enough room
    # for the prompt text above them.
    wanted=$((count + 13))
    ((h > wanted)) && h=$wanted
    ((h < 18)) && h=18
    # With --fb the button boxes take one extra line; leave room for the prompt.
    list_h=$((h - 10))
    ((list_h < 4)) && list_h=4
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" --noitem "${extra[@]}" \
        \
        --menu "$prompt" "$h" "$w" "$list_h" "${args[@]}" 3>&1 1>&2 2>&3
}

ui_yesno() {
    local title=$1 prompt=${2//\\n/$'\n'} h lines chars w
    lines=$(printf '%s\n' "$prompt" | wc -l)
    chars=$(printf '%s' "$prompt" | wc -c)
    h=$((lines + chars / 60 + 4))
    ((h > 30)) && h=30
    ((h < 12)) && h=12
    read -r h w < <(fit_dialog "$h" 88)
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" \
        --yesno "$prompt" "$h" "$w" 3>&1 1>&2 2>&3
}

ui_msg() {
    local title=$1 text=${2//\\n/$'\n'} h lines w
    lines=$(printf '%s\n' "$text" | wc -l)
    h=$((lines + 8))
    ((h > 34)) && h=34
    ((h < 12)) && h=12
    read -r h w < <(fit_dialog "$h" 88)
    whiptail --fb --backtitle "$BACKTITLE" --title "$title" \
        \
        --msgbox "$text" "$h" "$w" 3>&1 1>&2 2>&3 || true
}

# ---------------------------------------------------------------------------
# validation (sets VALIDATION_ERROR and returns non-zero on failure)
# ---------------------------------------------------------------------------
VALIDATION_ERROR=""
fail() { VALIDATION_ERROR=$1; return 1; }

v_host() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v != *[[:space:],]* ]] || { fail "no spaces or commas"; return 1; }
    [[ $v =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9._:-]*)$ ]] \
        || { fail "invalid host name or IP address"; return 1; }
    return 0
}

v_share() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v != */* ]] || { fail "share name only, no slashes"; return 1; }
    [[ $v != *[[:space:],]* ]] || { fail "no spaces or commas"; return 1; }
    return 0
}

v_export() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v == /* ]] || { fail "must start with /"; return 1; }
    [[ $v != *[[:space:],]* ]] || { fail "no spaces or commas"; return 1; }
    return 0
}

v_mountpoint() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v == /* ]] || { fail "must be an absolute path"; return 1; }
    [[ $v == / ]] && { fail "refusing to use /"; return 1; }
    [[ $v != *[[:space:]]* ]] || { fail "no spaces allowed"; return 1; }
    [[ $v =~ (^|/)\.\.(/|$) ]] && { fail "must not contain .."; return 1; }
    [[ $v =~ ^/[A-Za-z0-9._/-]*$ ]] || { fail "only letters, digits, / . _ -"; return 1; }
    return 0
}

v_name() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    (( ${#v} <= 32 )) || { fail "max 32 characters"; return 1; }
    [[ $v =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || { fail "lowercase letters, digits, - and _ only"; return 1; }
    return 0
}

v_new_name() {
    v_name "$1" || return 1
    [[ -e $(conf_file_for "$1") ]] && { fail "a mount with this name already exists"; return 1; }
    return 0
}

slugify() {
    local s
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//' \
        | cut -c1-32)
    printf '%s' "${s:-mount}"
}

unique_name() {
    local base candidate n=2
    base=$(slugify "$1")
    candidate=$base
    while [[ -e $(conf_file_for "$candidate") ]]; do
        candidate="${base:0:29}-$n"
        n=$((n + 1))
        ((n > 99)) && break
    done
    printf '%s' "$candidate"
}

v_port() {
    local v=$1
    [[ -z $v ]] && return 0
    [[ $v =~ ^[0-9]+$ ]] || { fail "must be a number"; return 1; }
    ((10#$v >= 1 && 10#$v <= 65535)) || { fail "must be 1-65535"; return 1; }
    return 0
}

v_port_required() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    v_port "$v"
}

v_iqn_opt() {
    local v=$1
    [[ -z $v ]] && return 0
    [[ $v == iqn.* || $v == eui.* || $v == naa.* ]] \
        || { fail "must start with iqn. / eui. / naa."; return 1; }
    [[ $v != *[[:space:],]* ]] || { fail "no spaces or commas"; return 1; }
    return 0
}

v_nqn_opt() {
    local v=$1
    [[ -z $v ]] && return 0
    [[ $v == nqn.* ]] || { fail "must start with nqn."; return 1; }
    [[ $v != *[[:space:],]* ]] || { fail "no spaces or commas"; return 1; }
    return 0
}

v_cred_opt() {
    local v=$1
    [[ $v == *$'\n'* || $v == *$'\r'* ]] && { fail "must be a single line"; return 1; }
    [[ $v == " "* || $v == *" " ]] && { fail "no leading/trailing spaces"; return 1; }
    return 0
}

v_cred_required() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    v_cred_opt "$v"
}

v_lun() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v =~ ^[0-9]+$ ]] || { fail "must be a number"; return 1; }
    return 0
}

v_extra_opt() {
    local v=$1
    [[ -z $v ]] && return 0
    [[ $v != *[[:space:]]* ]] || { fail "no spaces (comma separated options)"; return 1; }
    [[ $v != ,* ]] || { fail "do not start with a comma"; return 1; }
    [[ $v != *, ]] || { fail "do not end with a comma"; return 1; }
    [[ $v != *'"'* && $v != *'\'* ]] || { fail "quotes and backslashes are not allowed"; return 1; }
    return 0
}

v_abs_dir() {
    local v=$1
    [[ -n $v ]] || { fail "required"; return 1; }
    [[ $v == /* ]] || { fail "must be an absolute path"; return 1; }
    [[ $v != *[[:space:]]* ]] || { fail "no spaces allowed"; return 1; }
    [[ $v =~ (^|/)\.\.(/|$) ]] && { fail "must not contain .."; return 1; }
    [[ $v =~ ^/[A-Za-z0-9._/-]*$ ]] || { fail "only letters, digits, / . _ -"; return 1; }
    return 0
}

v_creds_dir() {
    v_abs_dir "$1" || return 1
    if ! creds_dir_ok "$1"; then
        fail "choose a dedicated subdirectory, not a system directory"
        return 1
    fi
    return 0
}

v_config_dir() {
    v_abs_dir "$1" || return 1
    if ! config_dir_ok "$1"; then
        fail "choose a dedicated subdirectory, not a system directory"
        return 1
    fi
    return 0
}

# ask_field <title> <prompt> <default> <validator> -> prints the value
ask_field() {
    local title=$1 prompt=$2 default=$3 validator=$4 value
    while :; do
        value=$(ui_input "$title" "$prompt" "$default") || return 1
        if "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
        ui_msg "Invalid value" "$VALIDATION_ERROR"
        default=$value
    done
}

ask_secret() {
    local title=$1 prompt=$2 value
    while :; do
        value=$(ui_password "$title" "$prompt") || return 1
        if v_cred_required "$value"; then
            printf '%s' "$value"
            return 0
        fi
        ui_msg "Invalid value" "$VALIDATION_ERROR"
    done
}

# ---------------------------------------------------------------------------
# state: per-mount .conf files are the source of truth; state.json is kept in
# sync for the optional Python UI, and /etc/fstab is regenerated from confs.
# ---------------------------------------------------------------------------
conf_file_for() { printf '%s/%s.conf' "$MOUNTS_DIR" "$1"; }
conf_files() { find "$MOUNTS_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort; }

reset_mount_vars() {
    PROTOCOL=""; NAME=""; TARGET=""; SOURCE=""; AUTOMOUNT=boot
    READ_ONLY=0; EXTRA_OPTS=""; UNIT=""; CRED_FILE=""; UUID=""; DEVICE=""; FS=""
    CREATED=""; OPTS=""
    unset OPT_SERVER OPT_SHARE OPT_USERNAME OPT_PASSWORD OPT_DOMAIN OPT_VERS \
          OPT_UID OPT_GID OPT_GUEST OPT_EXPORT OPT_PORT OPT_PORTAL OPT_IQN \
          OPT_LUN OPT_CHAP_USER OPT_FS_POLICY OPT_CHOWN OPT_TRANSPORT \
          OPT_ADDRESS OPT_NQN 2>/dev/null || true
}

load_conf() {
    local file=$1 key
    reset_mount_vars
    # clear any stale OPT_* variables before sourcing
    while IFS='=' read -r key _; do
        [[ $key == OPT_* ]] && unset "$key" 2>/dev/null || true
    done <"$file"
    # shellcheck disable=SC1090
    . "$file"
}

option_keys() {
    case $PROTOCOL in
        cifs)   printf 'server share username domain vers uid gid guest' ;;
        nfs)    printf 'server export vers port' ;;
        iscsi)  printf 'portal port iqn lun chap_user fs_policy chown' ;;
        nvmeof) printf 'transport address port nqn fs_policy chown' ;;
    esac
}

opt_get() {
    local var="OPT_${1^^}"
    printf '%s' "${!var-}"
}

write_conf() {
    local tmp key
    tmp=$(mktemp)
    {
        printf 'PROTOCOL=%q\n' "$PROTOCOL"
        printf 'NAME=%q\n' "$NAME"
        printf 'TARGET=%q\n' "$TARGET"
        printf 'SOURCE=%q\n' "$SOURCE"
        printf 'AUTOMOUNT=%q\n' "$AUTOMOUNT"
        printf 'READ_ONLY=%q\n' "$READ_ONLY"
        printf 'EXTRA_OPTS=%q\n' "$EXTRA_OPTS"
        printf 'UNIT=%q\n' "$UNIT"
        printf 'CRED_FILE=%q\n' "$CRED_FILE"
        printf 'UUID=%q\n' "$UUID"
        printf 'DEVICE=%q\n' "$DEVICE"
        printf 'FS=%q\n' "$FS"
        printf 'CREATED=%q\n' "$CREATED"
        for key in $(option_keys); do
            printf 'OPT_%s=%q\n' "${key^^}" "$(opt_get "$key")"
        done
    } >"$tmp"
    install_config_file "$tmp" "$(conf_file_for "$NAME")" 0644
}

json_str() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    printf '"%s"' "$s"
}

emit_options_json() {
    local key var value first=1
    printf '{'
    for key in $(option_keys); do
        var="OPT_${key^^}"
        value=${!var-}
        if ((first == 0)); then printf ', '; fi
        first=0
        case $key in
            uid|gid)
                [[ $value =~ ^[0-9]+$ ]] || value=0
                printf '"%s": %s' "$key" "$value"
                ;;
            guest|chown)
                if [[ $value == 1 ]]; then
                    printf '"%s": true' "$key"
                else
                    printf '"%s": false' "$key"
                fi
                ;;
            *)
                printf '"%s": %s' "$key" "$(json_str "$value")"
                ;;
        esac
    done
    printf '}'
}

emit_spec_json() {
    local created=${CREATED:-$(date -Iseconds 2>/dev/null || date)}
    printf '    {\n'
    printf '      "name": %s,\n' "$(json_str "$NAME")"
    printf '      "protocol": %s,\n' "$(json_str "$PROTOCOL")"
    printf '      "target": %s,\n' "$(json_str "$TARGET")"
    printf '      "source": %s,\n' "$(json_str "$SOURCE")"
    printf '      "options": %s,\n' "$(emit_options_json)"
    printf '      "automount": %s,\n' "$(json_str "$AUTOMOUNT")"
    printf '      "read_only": %s,\n' "$([[ $READ_ONLY == 1 ]] && printf true || printf false)"
    printf '      "extra_opts": %s,\n' "$(json_str "$EXTRA_OPTS")"
    printf '      "created": %s,\n' "$(json_str "$created")"
    printf '      "unit": %s,\n' "$([[ -n $UNIT ]] && json_str "$UNIT" || printf null)"
    printf '      "cred_file": %s,\n' "$([[ -n $CRED_FILE ]] && json_str "$CRED_FILE" || printf null)"
    printf '      "uuid": %s,\n' "$([[ -n $UUID ]] && json_str "$UUID" || printf null)"
    printf '      "device": %s,\n' "$([[ -n $DEVICE ]] && json_str "$DEVICE" || printf null)"
    printf '      "fs": %s\n' "$([[ -n $FS ]] && json_str "$FS" || printf null)"
    printf '    }'
}

sync_state() {
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s would update %s\n' "$C_DIM" "$C_RESET" "$STATE_FILE"
        return 0
    fi
    local tmp file first=1 count=0
    tmp=$(mktemp)
    {
        printf '{\n'
        printf '  "version": 1,\n'
        printf '  "updated": %s,\n' "$(json_str "$(date -Iseconds 2>/dev/null || date)")"
        printf '  "mounts": ['
        while IFS= read -r file; do
            [[ -n $file ]] || continue
            load_conf "$file"
            if ((first == 0)); then printf ','; fi
            first=0
            printf '\n'
            emit_spec_json
            count=$((count + 1))
        done < <(conf_files)
        if ((count > 0)); then printf '\n  '; fi
        printf ']\n}\n'
    } >"$tmp"
    install_config_file "$tmp" "$STATE_FILE" 0644
}

# -- fstab ------------------------------------------------------------------
add_opt() {
    if [[ -n ${OPTS:-} ]]; then
        OPTS+=",$1"
    else
        OPTS=$1
    fi
}

host_src() {
    local host=$1
    if [[ $host == *:* && $host != \[* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

build_fstab_line() {
    local src type
    OPTS=""
    case $PROTOCOL in
        cifs)
            if [[ -n ${OPT_USERNAME:-} ]]; then
                add_opt "credentials=$CRED_FILE"
            else
                add_opt guest
            fi
            add_opt "uid=${OPT_UID:-0}"
            add_opt "gid=${OPT_GID:-0}"
            add_opt "vers=${OPT_VERS:-3.0}"
            add_opt "iocharset=utf8"
            ;;
        nfs)
            add_opt hard
            add_opt timeo=600
            add_opt retrans=2
            add_opt noatime
            [[ -n ${OPT_VERS:-} ]] && add_opt "vers=$OPT_VERS"
            [[ -n ${OPT_PORT:-} ]] && add_opt "port=$OPT_PORT"
            ;;
        iscsi|nvmeof)
            add_opt defaults
            add_opt noatime
            ;;
    esac

    if [[ $AUTOMOUNT == boot ]]; then
        [[ $READ_ONLY == 1 ]] && add_opt ro || add_opt rw
        add_opt _netdev
        add_opt nofail
        add_opt x-systemd.device-timeout=30s
    elif [[ $AUTOMOUNT == access ]]; then
        [[ $READ_ONLY == 1 ]] && add_opt ro || add_opt rw
        add_opt _netdev
        add_opt nofail
        add_opt x-systemd.automount
        add_opt x-systemd.idle-timeout=60
    else
        [[ $READ_ONLY == 1 ]] && add_opt ro || add_opt rw
        add_opt _netdev
        add_opt noauto
    fi

    if [[ $PROTOCOL == nvmeof && -n $UNIT ]]; then
        add_opt "x-systemd.requires=$UNIT"
    fi
    [[ -n ${EXTRA_OPTS:-} ]] && add_opt "$EXTRA_OPTS"

    case $PROTOCOL in
        cifs)   src=$SOURCE; type=cifs ;;
        nfs)
            src=$SOURCE
            if [[ ${OPT_VERS:-4.2} == 4* ]]; then type=nfs4; else type=nfs; fi
            ;;
        iscsi|nvmeof)
            src="UUID=$UUID"
            type=${FS:-auto}
            ;;
        *) src=$SOURCE; type=auto ;;
    esac
    printf '%s %s %s %s 0 0' "$src" "$TARGET" "$type" "$OPTS"
}

build_runtime_opts() {
    OPTS=""
    case $PROTOCOL in
        cifs)
            if [[ -n ${OPT_USERNAME:-} ]]; then
                add_opt "credentials=$CRED_FILE"
            else
                add_opt guest
            fi
            add_opt "uid=${OPT_UID:-0}"
            add_opt "gid=${OPT_GID:-0}"
            add_opt "vers=${OPT_VERS:-3.0}"
            add_opt "iocharset=utf8"
            ;;
        nfs)
            add_opt hard
            add_opt timeo=600
            add_opt retrans=2
            add_opt noatime
            [[ -n ${OPT_VERS:-} ]] && add_opt "vers=$OPT_VERS"
            [[ -n ${OPT_PORT:-} ]] && add_opt "port=$OPT_PORT"
            ;;
        *)
            add_opt defaults
            add_opt noatime
            ;;
    esac
    [[ $READ_ONLY == 1 ]] && add_opt ro || add_opt rw
    [[ -n ${EXTRA_OPTS:-} ]] && add_opt "$EXTRA_OPTS"
    printf '%s' "$OPTS"
}

wrap_fstab_line() {
    local line=$1 src target type opts dump pass opt current=""
    read -r src target type opts dump pass <<<"$line"
    printf '%s %s %s\n' "$src" "$target" "$type"
    local IFS=,
    for opt in $opts; do
        if [[ -z $current ]]; then
            current=$opt
        elif (( ${#current} + ${#opt} + 1 > 72 )); then
            printf '  %s\n' "$current"
            current=$opt
        else
            current+=",$opt"
        fi
    done
    [[ -n $current ]] && printf '  %s\n' "$current"
    printf '  dump=%s pass=%s\n' "$dump" "$pass"
}

build_fstab_block() {
    local file
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        printf '# %s\n%s\n' "$NAME" "$(build_fstab_line)"
    done < <(conf_files)
}

validate_fstab_block() {
    local block=$1 line t
    local -a fields
    local -A seen=()
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        read -r -a fields <<<"$line"
        if ((${#fields[@]} != 6)); then
            msg_err "generated fstab line has ${#fields[@]} fields: $line"
            return 1
        fi
        if [[ ${fields[1]} != /* ]]; then
            msg_err "generated fstab target is not absolute: $line"
            return 1
        fi
        if [[ ! ${fields[4]} =~ ^[0-9]+$ || ! ${fields[5]} =~ ^[0-9]+$ ]]; then
            msg_err "generated fstab dump/pass fields are not numeric: $line"
            return 1
        fi
        t=${fields[1]}
        if [[ -n ${seen[$t]:-} ]]; then
            msg_err "two mounts use the same target: $t"
            return 1
        fi
        seen[$t]=1
    done <<<"$block"
    return 0
}

systemd_running() {
    [[ -z ${TEST_MODE:-} ]] && command -v systemctl >/dev/null 2>&1 \
        && [[ -d /run/systemd/system ]]
}

sync_fstab() {
    if ((DRY_RUN)); then
        printf '  %s[dry-run]%s would update %s\n' "$C_DIM" "$C_RESET" "$FSTAB"
        return 0
    fi
    local orig stripped base new block
    orig=$(mktemp); stripped=$(mktemp); base=$(mktemp); new=$(mktemp)
    if [[ -f $FSTAB ]]; then
        cat "$FSTAB" >"$orig"
    fi
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
        '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$orig" >"$stripped"
    # drop trailing blank lines from the unmanaged part
    awk 'NF{last=NR} {line[NR]=$0} END{for(i=1;i<=last;i++) print line[i]}' \
        "$stripped" >"$base"
    block=$(build_fstab_block)
    if ! validate_fstab_block "$block"; then
        rm -f "$orig" "$stripped" "$base" "$new"
        return 1
    fi
    {
        if [[ -s $base ]]; then
            cat "$base"
        fi
        if [[ -n $block ]]; then
            [[ -s $base ]] && printf '\n'
            printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$block" "$MARK_END"
        fi
    } >"$new"

    if [[ -s $orig && ! -e $FSTAB_BAK ]]; then
        install_file "$orig" "$FSTAB_BAK" 0644 || true
    fi
    install_file "$new" "$FSTAB" 0644
    rm -f "$orig" "$stripped" "$base" "$new"
    if systemd_running; then
        run_step "Reloading systemd" as_root systemctl daemon-reload || true
    fi
}

# ---------------------------------------------------------------------------
# mount / unmount / verification helpers
# ---------------------------------------------------------------------------
is_mounted() {
    findmnt -rn -M "$1" >/dev/null 2>&1
}

verify_mounted() {
    local target=$1
    ((DRY_RUN)) && return 0
    if ! is_mounted "$target"; then
        msg_err "nothing is mounted on $target after mounting"
        return 1
    fi
    msg_ok "verified: $(findmnt -rn -o SOURCE,FSTYPE,TARGET -M "$target" | head -n1)"
}

do_mount_direct() {
    local opts
    opts=$(build_runtime_opts)
    case $PROTOCOL in
        cifs)
            run_step "Mounting $SOURCE" as_root mount -t cifs "$SOURCE" "$TARGET" -o "$opts"
            ;;
        nfs)
            local type=nfs
            [[ ${OPT_VERS:-4.2} == 4* ]] && type=nfs4
            run_step "Mounting $SOURCE" as_root mount -t "$type" "$SOURCE" "$TARGET" -o "$opts"
            ;;
        *)
            run_step "Mounting UUID=$UUID" as_root mount -U "$UUID" "$TARGET" -o "$opts"
            ;;
    esac
}

do_mount_by_fstab() {
    run_step "Mounting $TARGET" as_root mount "$TARGET"
}

do_unmount() {
    local target=$1
    is_mounted "$target" || return 0
    local unit auto
    if command -v systemd-escape >/dev/null 2>&1; then
        unit=$(systemd-escape -p --suffix=mount "$target" 2>/dev/null || true)
        if [[ -n $unit ]] && systemd_running; then
            auto=${unit%.mount}.automount
            as_root systemctl stop "$auto" >/dev/null 2>&1 || true
            as_root systemctl stop "$unit" >/dev/null 2>&1 || true
        fi
    fi
    if run_step "Unmounting $target" as_root umount "$target"; then
        return 0
    fi
    if ui_yesno "Device is busy" \
        "$target could not be unmounted.\n\nForce a lazy unmount? Open files will get I/O errors."; then
        run_step "Lazy unmount" as_root umount -l "$target"
        return 0
    fi
    return 1
}

wait_by_path() {
    local pattern=$1 i path
    for i in {1..40}; do
        path=$(compgen -G "/dev/disk/by-path/$pattern" 2>/dev/null | head -n1 || true)
        if [[ -n $path && -e $path ]]; then
            readlink -f "$path"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

disk_paths() { lsblk -dn -o PATH,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'; }

pick_new_disk() {
    local before=$1 p size best="" best_size=0
    while IFS= read -r p; do
        [[ -n $p ]] || continue
        grep -qxF "$p" <<<"$before" && continue
        size=$(lsblk -bdno SIZE "$p" 2>/dev/null || printf 0)
        [[ $size =~ ^[0-9]+$ ]] || size=0
        if ((size > best_size)); then
            best_size=$size
            best=$p
        fi
    done < <(disk_paths)
    [[ -n $best ]] && { printf '%s' "$best"; return 0; }
    return 1
}

wait_new_disk() {
    local before=$1 i disk
    for i in {1..20}; do
        if disk=$(pick_new_disk "$before"); then
            printf '%s' "$disk"
            return 0
        fi
        sleep 0.4
    done
    return 1
}

blkid_type() { root_capture blkid -s TYPE -o value "$1" 2>/dev/null || true; }
blkid_uuid() { root_capture blkid -s UUID -o value "$1" 2>/dev/null || true; }

format_tool() {
    case $1 in
        ext4)  printf 'mkfs.ext4' ;;
        xfs)   printf 'mkfs.xfs' ;;
        btrfs) printf 'mkfs.btrfs' ;;
        f2fs)  printf 'mkfs.f2fs' ;;
        vfat)  printf 'mkfs.vfat' ;;
        exfat) printf 'mkfs.exfat' ;;
        ntfs)  printf 'mkfs.ntfs' ;;
        *)     return 1 ;;
    esac
}

format_package() {
    local fs=$1 pm
    pm=$(detect_pm) || pm=apt-get
    case $fs in
        ext4)  printf 'e2fsprogs' ;;
        xfs)   printf 'xfsprogs' ;;
        btrfs) printf 'btrfs-progs' ;;
        f2fs)  printf 'f2fs-tools' ;;
        vfat)  printf 'dosfstools' ;;
        exfat) printf 'exfatprogs' ;;
        ntfs)  printf 'ntfs-3g' ;;
        *)     printf '%s' "$fs" ;;
    esac
}

format_label() {
    local fs=$1 max
    case $fs in
        ext4)          max=16 ;;
        xfs)           max=12 ;;
        vfat|exfat)    max=11 ;;
        ntfs|btrfs|f2fs) max=32 ;;
        *)             max=16 ;;
    esac
    printf '%s' "${NAME:0:max}"
}

ensure_format_tool() {
    local fs=$1 tool pkg
    tool=$(format_tool "$fs") || return 1
    command -v "$tool" >/dev/null 2>&1 && return 0
    pkg=$(format_package "$fs")
    if ! ui_yesno "Missing filesystem tools" \
        "$tool was not found.\n\nInstall the package '$pkg' now to format this device as $fs?"; then
        return 1
    fi
    run_step "Installing $pkg" pkg_install "$pkg"
    hash -r
    if ! command -v "$tool" >/dev/null 2>&1; then
        if ((DRY_RUN)); then
            return 0
        fi
        ui_msg "Filesystem tools missing" \
            "Installed '$pkg' but '$tool' is still not on PATH.\n\nInstall it manually and re-run."
        return 1
    fi
    return 0
}

format_device() {
    local fs=$1 node=$2 label
    label=$(format_label "$fs")
    case $fs in
        ext4)
            run_step "Formatting $node as ext4" as_root mkfs.ext4 -F -L "$label" "$node" ;;
        xfs)
            run_step "Formatting $node as xfs" as_root mkfs.xfs -f -L "$label" "$node" ;;
        btrfs)
            run_step "Formatting $node as btrfs" as_root mkfs.btrfs -f -L "$label" "$node" ;;
        f2fs)
            run_step "Formatting $node as f2fs" as_root mkfs.f2fs -f -l "$label" "$node" ;;
        vfat)
            run_step "Formatting $node as FAT32" as_root mkfs.vfat -F 32 -n "$label" "$node" ;;
        exfat)
            run_step "Formatting $node as exFAT" as_root mkfs.exfat -L "$label" "$node" ;;
        ntfs)
            run_step "Formatting $node as NTFS" as_root mkfs.ntfs -F -L "$label" "$node" ;;
        *)
            msg_err "unsupported filesystem: $fs"
            return 1 ;;
    esac
}

prepare_filesystem() {
    local dev=$1 node=$1 part fstype uuid policy label
    if ((DRY_RUN)); then
        DEVICE=$node
        FS=${FS:-ext4}
        UUID=${UUID:-00000000-0000-0000-0000-000000000000}
        msg_ok "filesystem: $FS on $node ($UUID) [dry-run]"
        return 0
    fi
    fstype=$(blkid_type "$node")
    uuid=$(blkid_uuid "$node")
    if [[ -z $fstype && -z $uuid ]]; then
        while IFS= read -r part; do
            [[ -n $part ]] || continue
            fstype=$(blkid_type "$part")
            uuid=$(blkid_uuid "$part")
            if [[ -n $fstype || -n $uuid ]]; then
                node=$part
                break
            fi
        done < <(lsblk -lnpo PATH "$dev" 2>/dev/null | tail -n +2)
    fi

    policy=${OPT_FS_POLICY:-ask}
    if [[ -z $uuid ]]; then
        if [[ $policy == abort ]]; then
            msg_err "$node has no filesystem and formatting is disabled"
            return 1
        fi
        if [[ $policy == ask ]]; then
            local choice
            choice=$(ui_menu_labels "No filesystem found" \
                "$node looks empty. Formatting erases all data on the device." \
                "Format as ext4 (recommended)" \
                "Format as xfs (large files / many writers)" \
                "Format as btrfs (snapshots, checksums)" \
                "Format as f2fs (flash-friendly)" \
                "Format as FAT32 (vfat)" \
                "Format as exFAT (large files, cross-platform)" \
                "Format as NTFS (Windows compatibility)" \
                "Do not mount") || return 1
            case $choice in
                "Format as ext4"*)  policy=ext4 ;;
                "Format as xfs"*)   policy=xfs ;;
                "Format as btrfs"*) policy=btrfs ;;
                "Format as f2fs"*)  policy=f2fs ;;
                "Format as FAT32"*) policy=vfat ;;
                "Format as exFAT"*) policy=exfat ;;
                "Format as NTFS"*)  policy=ntfs ;;
                *)                  return 1 ;;
            esac
        fi
        ensure_format_tool "$policy" || return 1
        local answer
        answer=$(ui_input "Confirm format" \
            "ALL DATA on $node will be destroyed.\n\nType ERASE to format as $policy:" "") || return 1
        [[ $answer == ERASE ]] || { msg_warn "formatting was not confirmed"; return 1; }

        format_device "$policy" "$node" || return 1
        run_step "Waiting for udev" as_root udevadm settle
        fstype=$(blkid_type "$node")
        uuid=$(blkid_uuid "$node")
        if [[ -z $uuid ]]; then
            msg_err "formatting succeeded but blkid reports no UUID on $node"
            return 1
        fi
    fi

    DEVICE=$node
    FS=${fstype:-auto}
    UUID=$uuid
    msg_ok "filesystem: $FS on $node ($UUID)"
}

chown_mount() {
    local uid=${SUDO_UID:-$(id -u)} gid=${SUDO_GID:-$(id -g)}
    run_step "Setting ownership to $uid:$gid" as_root chown "$uid:$gid" "$TARGET" || true
}

# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------
ROLLBACK=()
register_rollback() { ROLLBACK+=("$*"); }

run_rollback() {
    local entry kind a b last
    set +e
    while ((${#ROLLBACK[@]} > 0)); do
        last=$(( ${#ROLLBACK[@]} - 1 ))
        entry=${ROLLBACK[$last]}
        unset "ROLLBACK[$last]"
        IFS='|' read -r kind a b <<<"$entry"
        case $kind in
            umount)
                msg_warn "rollback: unmounting $a"
                as_root umount "$a" >/dev/null 2>&1 || as_root umount -l "$a" >/dev/null 2>&1
                ;;
            logout)
                msg_warn "rollback: logging out of $b"
                as_root iscsiadm -m node -T "$b" -p "$a" --logout >/dev/null 2>&1
                ;;
            nvme-disconnect)
                msg_warn "rollback: disconnecting $a"
                as_root nvme disconnect -n "$a" >/dev/null 2>&1
                ;;
            rm-unit)
                msg_warn "rollback: removing unit $a"
                if systemd_running; then
                    as_root systemctl disable --now "$a" >/dev/null 2>&1
                fi
                as_root rm -f "$UNITS_DIR/$a" >/dev/null 2>&1
                if systemd_running; then
                    as_root systemctl daemon-reload >/dev/null 2>&1
                fi
                ;;
            rm-creds)
                msg_warn "rollback: deleting credentials"
                as_root rm -f "$a" >/dev/null 2>&1
                ;;
            rm-conf)
                msg_warn "rollback: removing saved configuration for $a"
                as_root rm -f "$(conf_file_for "$a")" >/dev/null 2>&1
                ;;
            rmdir)
                as_root rmdir "$a" >/dev/null 2>&1
                ;;
        esac
    done
    set -e
}

on_apply_error() {
    local code=$?
    set +e
    KEEP_LOG=1
    printf '\n%s✗ setup failed%s\n' "$C_ERR" "$C_RESET" >&2
    if [[ -s $LOG_FILE ]]; then
        tail -n 12 "$LOG_FILE" | sed 's/^/    /' >&2
    fi
    error_hint
    if ((${#ROLLBACK[@]} > 0)); then
        printf '%srolling back…%s\n' "$C_WARN" "$C_RESET" >&2
        run_rollback
    fi
    printf 'Full log: %s\n' "$LOG_FILE" >&2
    exit "$code"
}

error_hint() {
    local text
    text=$(tail -n 30 "$LOG_FILE" 2>/dev/null || true)
    case $text in
        *"mount error(13)"*|*"access denied"*|*"logon failure"*)
            printf '%sHint:%s the server rejected the credentials — check username, password and share permissions.\n' \
                "$C_WARN" "$C_RESET" >&2 ;;
        *"mount error(2)"*|*"No such file or directory"*|*"not exported"*)
            printf '%sHint:%s the share or export was not found on the server.\n' "$C_WARN" "$C_RESET" >&2 ;;
        *"Connection refused"*)
            printf '%sHint:%s the server refused the connection — is the service running and the port open?\n' "$C_WARN" "$C_RESET" >&2 ;;
        *"Connection timed out"*|*"No route to host"*|*"host is down"*)
            printf '%sHint:%s the server did not answer — check the address, network and firewall.\n' "$C_WARN" "$C_RESET" >&2 ;;
        *"target is busy"*|*"device is busy"*)
            printf '%sHint:%s files are still open on the mount.\n' "$C_WARN" "$C_RESET" >&2 ;;
        *"wrong fs type"*|*"bad option"*|*"unknown filesystem"*)
            printf '%sHint:%s the kernel module or mount helper for this filesystem is missing.\n' "$C_WARN" "$C_RESET" >&2 ;;
        *"authorization failure"*|*"CHAP"*)
            printf '%sHint:%s the target rejected the login (CHAP) credentials.\n' "$C_WARN" "$C_RESET" >&2 ;;
    esac
}

on_interrupt() {
    set +e
    KEEP_LOG=1
    printf '\n%scancelled%s\n' "$C_WARN" "$C_RESET" >&2
    if ((${#ROLLBACK[@]} > 0)); then
        printf 'rolling back…\n' >&2
        run_rollback
    fi
    exit 130
}

begin_apply() {
    trap on_apply_error ERR
    trap on_interrupt INT TERM
}
end_apply() {
    trap - ERR INT TERM
    ROLLBACK=()
}

# ---------------------------------------------------------------------------
# common wizard section
# ---------------------------------------------------------------------------
collect_common() {
    local default_name=$1 default_target
    NAME=$(ask_field "Name" "Short name for this mount:" "$default_name" v_new_name) || return 1
    default_target="${MOUNT_ROOT%/}/$NAME"
    [[ -z ${MOUNT_ROOT%/} ]] && default_target="/$NAME"
    while :; do
        TARGET=$(ask_field "Mount point" \
            "Directory to mount at (created if missing):" "$default_target" v_mountpoint) || return 1
        TARGET=${TARGET%/}
        if target_in_use "$TARGET"; then
            ui_msg "Mount point in use" "$TARGET is already used by another mount."
            default_target=$TARGET
            continue
        fi
        break
    done
    case $DEFAULT_AUTOMOUNT in
        boot)   MENU_DEFAULT="At boot (normal fstab entry)" ;;
        access) MENU_DEFAULT="On first access (systemd automount)" ;;
        manual) MENU_DEFAULT="Manual only (noauto)" ;;
    esac
    if ! AUTOMOUNT=$(ui_menu_labels "Auto-mount" "When should this mount come back?" \
        "At boot (normal fstab entry)" \
        "On first access (systemd automount)" \
        "Manual only (noauto)"); then
        MENU_DEFAULT=""
        return 1
    fi
    MENU_DEFAULT=""
    case $AUTOMOUNT in
        "At boot"*)         AUTOMOUNT=boot ;;
        "On first access"*) AUTOMOUNT=access ;;
        *)                  AUTOMOUNT=manual ;;
    esac
    if ui_yesno "Read-only" "Mount this read-only?"; then
        READ_ONLY=1
    else
        READ_ONLY=0
    fi
    EXTRA_OPTS=$(ask_field "Extra options" \
        "Additional mount options (comma separated, may be empty):" "" v_extra_opt) || return 1
    CREATED=$(date -Iseconds 2>/dev/null || date)
    return 0
}

target_in_use() (
    local want=$1 file
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        [[ ${TARGET%/} == "$want" ]] && return 0
    done < <(conf_files)
    return 1
)

review_and_confirm() {
    local fstab_line mode_line block_note=""
    fstab_line=$(build_fstab_line)
    # build_fstab_line runs in a subshell above; run it again to populate OPTS
    build_fstab_line >/dev/null
    if [[ $PROTOCOL == iscsi || $PROTOCOL == nvmeof ]]; then
        block_note=$'\n(UUID is filled in after the device is connected.)'
        fstab_line="UUID=<pending> $TARGET ${FS:-auto} $OPTS 0 0"
    fi
    case $AUTOMOUNT in
        boot) mode_line="at boot" ;;
        access) mode_line="on first access" ;;
        *) mode_line="manual only" ;;
    esac
    ui_yesno "Review" \
"Apply now?

Protocol:    $PROTOCOL
Source:      $SOURCE
Mount point: $TARGET
Auto-mount:  $mode_line
Read-only:   $([[ $READ_ONLY == 1 ]] && echo yes || echo no)

fstab entry:
$(wrap_fstab_line "$fstab_line")$block_note"
}

# ---------------------------------------------------------------------------
# CIFS / SMB
# ---------------------------------------------------------------------------
parse_smb_shares() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*Sharename[[:space:]]+Type/ { in_list=1; next }
        in_list && /^[[:space:]]*-+[[:space:]]*-+/ { next }
        in_list && $2 == "Disk" { print $1 }
    '
}

smbclient_package() {
    local pm
    pm=$(detect_pm) || pm=apt-get
    case $pm in
        apt-get) printf 'smbclient' ;;
        dnf)     printf 'samba-client' ;;
        pacman)  printf 'samba' ;;
        zypper)  printf 'samba-client' ;;
        *)       printf 'smbclient' ;;
    esac
}

ensure_smbclient() {
    command -v smbclient >/dev/null 2>&1 && return 0
    ((DRY_RUN)) && return 0
    local pkg
    pkg=$(smbclient_package)
    if ! ui_yesno "Share browser" \
        "smbclient was not found.\n\nInstall '$pkg' to list the shares on this server?"; then
        return 1
    fi
    run_step "Installing $pkg" pkg_install "$pkg"
    hash -r
    command -v smbclient >/dev/null 2>&1
}

read_as_root() {
    if ((EUID == 0)) || [[ -n $TEST_MODE ]]; then
        "$@"
        return
    fi
    if "$@" 2>/dev/null; then
        return 0
    fi
    sudo -n -- "$@"
}

load_cred_values() {
    local file=$1 key value content
    SAVED_USERNAME=""; SAVED_PASSWORD=""; SAVED_DOMAIN=""
    content=$(read_as_root cat "$file" 2>/dev/null || true)
    [[ -n $content ]] || return 1
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case $key in
            username) SAVED_USERNAME=$value ;;
            password) SAVED_PASSWORD=$value ;;
            domain)   SAVED_DOMAIN=$value ;;
        esac
    done <<<"$content"
    [[ -n $SAVED_USERNAME ]]
}

choose_cifs_auth() {
    local server=$1 file label choice i
    local -a labels=() files=()
    local -A seen=()
    AUTH_USERNAME=""; AUTH_PASSWORD=""; AUTH_DOMAIN=""

    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_cred_values "$file" || continue
        label="Use saved credentials: ${SAVED_USERNAME}${SAVED_DOMAIN:+ @ $SAVED_DOMAIN}"
        [[ -n ${seen[$label]:-} ]] && continue
        seen[$label]=1
        labels+=("$label")
        files+=("$file")
    done < <(read_as_root find "$CREDS_DIR" -maxdepth 1 -type f -name '*.cred' 2>/dev/null | sort || true)

    labels+=("Guest / no password" "Enter new credentials")
    choice=$(ui_menu_labels "Authentication" "How does the server authenticate?" \
        "${labels[@]}") || return 1

    case $choice in
        "Use saved credentials:"*)
            for i in "${!labels[@]}"; do
                if [[ ${labels[$i]} == "$choice" ]]; then
                    load_cred_values "${files[$i]}" || return 1
                    AUTH_USERNAME=$SAVED_USERNAME
                    AUTH_PASSWORD=$SAVED_PASSWORD
                    AUTH_DOMAIN=$SAVED_DOMAIN
                    return 0
                fi
            done
            return 1
            ;;
        "Enter new credentials")
            AUTH_USERNAME=$(ask_field "CIFS / SMB" "Username:" "" v_cred_required) || return 1
            AUTH_PASSWORD=$(ask_secret "CIFS / SMB" "Password for $AUTH_USERNAME:") || return 1
            AUTH_DOMAIN=$(ask_field "CIFS / SMB" "Domain / workgroup (optional):" "" v_cred_opt) || return 1
            ;;
        *) ;;
    esac
    return 0
}

choose_cifs_share() {
    local server=$1 username=$2 password=$3 domain=$4
    if ((DRY_RUN)); then
        ask_field "CIFS / SMB" "Share name:" "" v_share
        return
    fi
    local choice out tmp share
    local -a shares=()
    if ensure_smbclient; then
        tmp=$(mktemp "${TMPDIR:-/tmp}/storctl-smb.XXXXXX")
        chmod 600 "$tmp"
        if [[ -n $username ]]; then
            {
                printf 'username=%s\n' "$username"
                printf 'password=%s\n' "$password"
                [[ -n $domain ]] && printf 'domain=%s\n' "$domain"
            } >"$tmp"
            out=$(root_capture timeout 10 env LC_ALL=C smbclient -L "//$server" -A "$tmp" || true)
        else
            out=$(root_capture timeout 10 env LC_ALL=C smbclient -L "//$server" -N || true)
        fi
        rm -f "$tmp"
        mapfile -t shares < <(parse_smb_shares <<<"$out")
    fi

    if ((${#shares[@]} > 0)); then
        choice=$(ui_menu_labels "CIFS / SMB" "Shares on $server:" \
            "${shares[@]}" "Enter share name manually") || return 1
        if [[ $choice == "Enter share name manually" ]]; then
            ask_field "CIFS / SMB" "Share name:" "" v_share
            return
        fi
        printf '%s' "$choice"
        return
    fi
    ask_field "CIFS / SMB" "Share name:" "" v_share
}

add_cifs() {
    reset_mount_vars
    PROTOCOL=cifs
    local server share username="" password="" domain="" default_name
    local step=server
    while :; do
        case $step in
            server)
                server=$(ask_field "CIFS / SMB" "Server name or IP address:" "" v_host) || return 0
                step=auth
                ;;
            auth)
                if choose_cifs_auth "$server"; then
                    username=$AUTH_USERNAME
                    password=$AUTH_PASSWORD
                    domain=$AUTH_DOMAIN
                    step=share
                else
                    step=server
                fi
                ;;
            share)
                if share=$(choose_cifs_share "$server" "$username" "$password" "$domain"); then
                    break
                fi
                step=auth
                ;;
        esac
    done

    SOURCE="//$(host_src "$server")/$share"
    OPT_SERVER=$server
    OPT_SHARE=$share
    OPT_USERNAME=$username
    OPT_PASSWORD=$password
    OPT_DOMAIN=$domain
    OPT_VERS=$SMB_VERSION
    OPT_UID=$(id -u)
    OPT_GID=$(id -g)
    [[ -n $username ]] && OPT_GUEST=0 || OPT_GUEST=1
    default_name=$share
    [[ -z $default_name ]] && default_name=$server
    default_name=$(unique_name "$default_name")

    collect_common "$default_name" || return 0
    CRED_FILE=""
    if [[ -n $username ]]; then
        CRED_FILE="$CREDS_DIR/$NAME.cred"
    fi
    review_and_confirm || return 0

    ensure_dep cifs || return 0
    begin_apply
    ensure_dir "$TARGET"
    run_step "Creating mount point" as_root install -d -m 0755 "$TARGET"
    register_rollback "rmdir|$TARGET"

    if [[ -n $username ]]; then
        run_step "Storing credentials" write_creds
        register_rollback "rm-creds|$CRED_FILE"
    fi
    do_mount_direct
    register_rollback "umount|$TARGET"
    verify_mounted "$TARGET"
    run_step "Saving configuration" write_conf
    register_rollback "rm-conf|$NAME"
    sync_state
    run_step "Updating /etc/fstab" sync_fstab
    end_apply

    ui_msg "$(box_title)" "$SOURCE $(mounted_phrase) $TARGET.\n\nIt would come back $(
        case $AUTOMOUNT in boot) echo "at boot";; access) echo "on first access";; *) echo "when you mount it manually";; esac)."
}

write_creds() {
    local tmp
    if ! creds_dir_ok "$CREDS_DIR"; then
        CREDS_DIR=$(syspath /etc/storctl/credentials)
    fi
    tmp=$(mktemp)
    {
        [[ -n ${OPT_USERNAME:-} ]] && printf 'username=%s\n' "$OPT_USERNAME"
        printf 'password=%s\n' "${OPT_PASSWORD:-}"
        [[ -n ${OPT_DOMAIN:-} ]] && printf 'domain=%s\n' "$OPT_DOMAIN"
    } >"$tmp"
    ensure_dir "$CREDS_DIR"
    if ((DRY_RUN == 0)); then
        as_root chmod 0700 "$CREDS_DIR" 2>/dev/null || true
    fi
    install_file "$tmp" "$CRED_FILE" 0600
    if ((DRY_RUN == 0)); then
        as_root chmod 0700 "$CREDS_DIR" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# NFS
# ---------------------------------------------------------------------------
parse_nfs_exports() {
    awk '{ sub(/\r$/, "") } NR > 1 && $1 ~ /^\// { print $1 }'
}

choose_nfs_export() {
    local server=$1
    if ((DRY_RUN)); then
        ask_field "NFS" "Export path (server side):" "" v_export
        return
    fi
    local choice out
    local -a exports=()
    if command -v showmount >/dev/null 2>&1; then
        out=$(root_capture timeout 5 env LC_ALL=C showmount -e "$server" || true)
        mapfile -t exports < <(parse_nfs_exports <<<"$out")
    fi

    if ((${#exports[@]} > 0)); then
        choice=$(ui_menu_labels "NFS" "Exports on $server:" \
            "${exports[@]}" "Enter export path manually") || return 1
        if [[ $choice == "Enter export path manually" ]]; then
            ask_field "NFS" "Export path (server side):" "" v_export
            return
        fi
        printf '%s' "$choice"
        return
    fi
    ask_field "NFS" "Export path (server side):" "" v_export
}

add_nfs() {
    reset_mount_vars
    PROTOCOL=nfs
    local server export port default_name
    local step=server
    while :; do
        case $step in
            server)
                server=$(ask_field "NFS" "Server name or IP address:" "" v_host) || return 0
                step=export
                ;;
            export)
                ensure_dep nfs || return 0
                if export=$(choose_nfs_export "$server"); then
                    step=port
                else
                    step=server
                fi
                ;;
            port)
                if port=$(ask_field "NFS" "Port (empty = auto, usually 2049):" "" v_port); then
                    break
                fi
                step=export
                ;;
        esac
    done

    SOURCE="$(host_src "$server"):$export"
    OPT_SERVER=$server
    OPT_EXPORT=$export
    OPT_VERS=$NFS_VERSION
    OPT_PORT=$port
    default_name=${export##*/}
    [[ -z $default_name ]] && default_name=$server
    default_name=$(unique_name "$default_name")

    collect_common "$default_name" || return 0
    review_and_confirm || return 0

    begin_apply
    run_step "Creating mount point" as_root install -d -m 0755 "$TARGET"
    register_rollback "rmdir|$TARGET"
    do_mount_direct
    register_rollback "umount|$TARGET"
    verify_mounted "$TARGET"
    run_step "Saving configuration" write_conf
    register_rollback "rm-conf|$NAME"
    sync_state
    run_step "Updating /etc/fstab" sync_fstab
    end_apply

    ui_msg "$(box_title)" "$SOURCE $(mounted_phrase) $TARGET."
}

# ---------------------------------------------------------------------------
# iSCSI
# ---------------------------------------------------------------------------
discover_iscsi_targets() {
    local portal=$1 out
    out=$(root_capture iscsiadm -m discovery -t sendtargets -p "$portal") || return 1
    awk '{print $NF}' <<<"$out" | grep -E '^(iqn\.|eui\.|naa\.)' | sort -u
}

choose_fs_policy() {
    local prompt=$1 choice
    choice=$(ui_menu_labels "If no filesystem" "$prompt" \
        "Ask me at mount time" \
        "Format as ext4" \
        "Format as xfs" \
        "Format as btrfs" \
        "Format as f2fs" \
        "Format as FAT32 (vfat)" \
        "Format as exFAT" \
        "Format as NTFS" \
        "Never format (abort)") || return 1
    case $choice in
        "Ask me"*)          printf 'ask' ;;
        "Format as ext4"*)  printf 'ext4' ;;
        "Format as xfs"*)   printf 'xfs' ;;
        "Format as btrfs"*) printf 'btrfs' ;;
        "Format as f2fs"*)  printf 'f2fs' ;;
        "Format as FAT32"*) printf 'vfat' ;;
        "Format as exFAT"*) printf 'exfat' ;;
        "Format as NTFS"*)  printf 'ntfs' ;;
        *)                  printf 'abort' ;;
    esac
}

add_iscsi() {
    reset_mount_vars
    PROTOCOL=iscsi
    local portal port=$ISCSI_PORT iqn lun=$ISCSI_LUN
    local chap_user="" chap_password="" policy chown default_name before
    portal=$(ask_field "iSCSI" "Target portal IP or host:" "" v_host) || return 0
    iqn=$(ask_field "iSCSI" "Target IQN (empty = discover):" "" v_iqn_opt) || return 0

    if ui_yesno "CHAP" "Does this target require CHAP authentication?"; then
        chap_user=$(ask_field "iSCSI" "CHAP username:" "" v_cred_required) || return 0
        chap_password=$(ask_secret "iSCSI" "CHAP secret:") || return 0
    fi

    policy=$(choose_fs_policy "What should happen if the LUN has no filesystem?") || return 0
    if ui_yesno "Ownership" "Give your user ownership of the mount point?"; then
        chown=1
    else
        chown=0
    fi

    OPT_PORTAL=$portal
    OPT_PORT=$port
    OPT_IQN=$iqn
    OPT_LUN=$lun
    OPT_CHAP_USER=$chap_user
    OPT_FS_POLICY=$policy
    OPT_CHOWN=$chown
    SOURCE=${iqn:-"$portal:$port"}
    default_name=${iqn##*:}
    if [[ -z $default_name ]]; then
        default_name=$portal
    fi
    default_name=$(unique_name "$default_name")

    collect_common "$default_name" || return 0
    review_and_confirm || return 0

    ensure_dep iscsi || return 0
    local pl="$portal:$port"
    begin_apply
    run_step "Creating mount point" as_root install -d -m 0755 "$TARGET"
    register_rollback "rmdir|$TARGET"
    run_step "Starting iSCSI services" enable_iscsid

    local targets
    if ((DRY_RUN)); then
        [[ -z $iqn ]] && iqn="iqn.2024-01.example:dry-run"
        OPT_IQN=$iqn
        SOURCE=$iqn
    else
        if ! targets=$(discover_iscsi_targets "$pl"); then
            if [[ -n $iqn ]]; then
                msg_warn "discovery failed — trying the supplied IQN anyway"
            else
                msg_err "iSCSI discovery failed (portal $pl)"
                false
            fi
        fi
        if [[ -z $iqn ]]; then
            if [[ -z ${targets:-} ]]; then
                msg_err "the portal advertised no targets"
                false
            fi
            if [[ $(wc -l <<<"$targets") -eq 1 ]]; then
                iqn=$targets
            else
                local menu_args=() t
                while IFS= read -r t; do
                    menu_args+=("$t" "")
                done <<<"$targets"
                # a cancelled menu must roll back, not silently return
                iqn=$(ui_menu "iSCSI targets" "Targets advertised by $pl:" \
                    "${menu_args[@]}") || false
            fi
            OPT_IQN=$iqn
            SOURCE=$iqn
        fi
    fi
    msg_ok "target: $iqn"

    if [[ -n $chap_user ]]; then
        run_step "Configuring CHAP" configure_chap "$pl" "$iqn" "$chap_user" "$chap_password"
    fi

    before=$(disk_paths)
    run_step "Logging in to $iqn" as_root iscsiadm -m node -T "$iqn" -p "$pl" --login
    register_rollback "logout|$pl|$iqn"

    DEVICE=""
    if ((DRY_RUN)); then
        DEVICE="/dev/disk/by-path/ip-$pl-iscsi-$iqn-lun-$lun"
        FS=ext4
        UUID="00000000-0000-0000-0000-000000000000"
    elif ! DEVICE=$(wait_by_path "ip-$pl-iscsi-$iqn-lun-$lun"); then
        msg_warn "by-path device not found yet, looking for a new disk"
        DEVICE=$(wait_new_disk "$before") || {
            msg_err "no block device appeared for LUN $lun"
            false
        }
    fi
    msg_ok "device: $DEVICE"

    prepare_filesystem "$DEVICE"

    do_mount_direct
    register_rollback "umount|$TARGET"
    verify_mounted "$TARGET"
    [[ $chown == 1 ]] && chown_mount

    run_step "Enabling login at boot" enable_iscsi_boot "$pl" "$iqn"
    run_step "Saving configuration" write_conf
    register_rollback "rm-conf|$NAME"
    sync_state
    run_step "Updating /etc/fstab" sync_fstab
    end_apply

    ui_msg "$(box_title)" "$SOURCE $(mounted_phrase) $TARGET.\n\nDevice: $DEVICE\nFilesystem: $FS\nLogins automatically at boot."
}

enable_iscsid() {
    local unit started=0
    if ! systemd_running; then
        msg_warn "systemd is not available — skipping service activation"
        return 0
    fi
    for unit in iscsid iscsid.socket; do
        if as_root systemctl enable --now "$unit" >/dev/null 2>&1; then
            started=1
            break
        fi
    done
    if ((started == 0)); then
        return 1
    fi
    as_root systemctl enable iscsi >/dev/null 2>&1 || true
}

configure_chap() {
    local pl=$1 iqn=$2 user=$3 secret=$4
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o new >/dev/null 2>&1 || true
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o update \
        -n node.session.auth.authmethod -v CHAP
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o update \
        -n node.session.auth.username -v "$user"
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o update \
        -n node.session.auth.password -v "$secret"
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o update \
        -n node.startup -v automatic >/dev/null 2>&1 || true
}

enable_iscsi_boot() {
    local pl=$1 iqn=$2
    as_root iscsiadm -m node -T "$iqn" -p "$pl" -o update \
        -n node.startup -v automatic
}

# ---------------------------------------------------------------------------
# NVMe-oF
# ---------------------------------------------------------------------------
discover_nvme_nqns() {
    local transport=$1 address=$2 port=$3 out
    out=$(root_capture nvme discover -t "$transport" -a "$address" -s "$port") || return 1
    awk -F': *' '/^subnqn:/{print $2}' <<<"$out" \
        | grep -E '^nqn\.' | grep -v 'nvmexpress.discovery' | sort -u
}

add_nvmeof() {
    reset_mount_vars
    PROTOCOL=nvmeof
    local transport=$NVME_TRANSPORT port=$NVME_PORT address nqn
    local policy chown default_name before
    address=$(ask_field "NVMe-oF" "Target IP or host:" "" v_host) || return 0
    nqn=$(ask_field "NVMe-oF" "Subsystem NQN (empty = discover):" "" v_nqn_opt) || return 0

    policy=$(choose_fs_policy "What should happen if the namespace has no filesystem?") || return 0
    if ui_yesno "Ownership" "Give your user ownership of the mount point?"; then
        chown=1
    else
        chown=0
    fi

    OPT_TRANSPORT=$transport
    OPT_ADDRESS=$address
    OPT_PORT=$port
    OPT_NQN=$nqn
    OPT_FS_POLICY=$policy
    OPT_CHOWN=$chown
    SOURCE=${nqn:-"$transport://$address:$port"}
    default_name=${nqn##*:}
    if [[ -z $default_name ]]; then
        default_name=$address
    fi
    default_name=$(unique_name "$default_name")

    collect_common "$default_name" || return 0
    UNIT="storctl-nvmeof-$NAME.service"
    review_and_confirm || return 0

    ensure_dep nvmeof || return 0
    begin_apply
    run_step "Creating mount point" as_root install -d -m 0755 "$TARGET"
    register_rollback "rmdir|$TARGET"

    local nqns
    if ((DRY_RUN)); then
        [[ -z $nqn ]] && nqn="nqn.2024-01.example:dry-run"
        OPT_NQN=$nqn
        SOURCE=$nqn
    else
        if ! nqns=$(discover_nvme_nqns "$transport" "$address" "$port"); then
            if [[ -n $nqn ]]; then
                msg_warn "discovery failed — trying the supplied NQN anyway"
            else
                msg_err "NVMe-oF discovery failed ($address:$port)"
                false
            fi
        fi
        if [[ -z $nqn ]]; then
            if [[ -z ${nqns:-} ]]; then
                msg_err "the target advertised no subsystems"
                false
            fi
            if [[ $(wc -l <<<"$nqns") -eq 1 ]]; then
                nqn=$nqns
            else
                local menu_args=() n
                while IFS= read -r n; do
                    menu_args+=("$n" "")
                done <<<"$nqns"
                nqn=$(ui_menu "NVMe-oF subsystems" \
                    "Subsystems advertised by $address:$port:" \
                    "${menu_args[@]}") || false
            fi
            OPT_NQN=$nqn
            SOURCE=$nqn
        fi
    fi
    msg_ok "subsystem: $nqn"

    before=$(disk_paths)
    run_step "Connecting to $nqn" as_root nvme connect \
        -t "$transport" -n "$nqn" -a "$address" -s "$port"
    register_rollback "nvme-disconnect|$nqn"

    DEVICE=""
    if ((DRY_RUN)); then
        DEVICE="/dev/disk/by-path/nvme-$transport-$address:$port-$nqn"
        FS=ext4
        UUID="00000000-0000-0000-0000-000000000000"
    elif ! DEVICE=$(wait_by_path "nvme-$transport-$address:$port-$nqn"); then
        msg_warn "by-path namespace not found yet, looking for a new disk"
        DEVICE=$(wait_new_disk "$before") || {
            msg_err "no NVMe namespace appeared"
            false
        }
    fi
    msg_ok "namespace: $DEVICE"

    prepare_filesystem "$DEVICE"

    do_mount_direct
    register_rollback "umount|$TARGET"
    verify_mounted "$TARGET"
    [[ $chown == 1 ]] && chown_mount

    run_step "Writing boot unit" write_nvme_unit "$transport" "$address" "$port" "$nqn"
    register_rollback "rm-unit|$UNIT"

    run_step "Saving configuration" write_conf
    register_rollback "rm-conf|$NAME"
    sync_state
    run_step "Updating /etc/fstab" sync_fstab
    end_apply

    ui_msg "$(box_title)" "$SOURCE $(mounted_phrase) $TARGET.\n\nNamespace: $DEVICE\nFilesystem: $FS\nBoot unit: $UNIT"
}

write_nvme_unit() {
    local transport=$1 address=$2 port=$3 nqn=$4 nvme tmp
    nvme=$(command -v nvme || printf '/usr/sbin/nvme')
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Unit]
Description=storctl NVMe-oF connect for $NAME
Documentation=man:nvme-connect(1)
After=network-online.target
Wants=network-online.target
Before=remote-fs-pre.target
Wants=remote-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nvme connect -t $transport -n $nqn -a $address -s $port
ExecStop=-$nvme disconnect -n $nqn

[Install]
WantedBy=multi-user.target
EOF
    install_file "$tmp" "$UNITS_DIR/$UNIT" 0644
    if systemd_running; then
        as_root systemctl daemon-reload
        as_root systemctl enable "$UNIT" >/dev/null
    fi
}

# ---------------------------------------------------------------------------
# manage existing mounts
# ---------------------------------------------------------------------------
pick_mount() {
    local file name desc menu_args=()
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        if is_mounted "$TARGET"; then
            desc="$PROTOCOL · $TARGET · mounted"
        else
            desc="$PROTOCOL · $TARGET · not mounted"
        fi
        menu_args+=("$NAME" "$desc")
    done < <(conf_files)
    if ((${#menu_args[@]} == 0)); then
        ui_msg "No mounts" "Nothing has been configured yet."
        return 1
    fi
    ui_menu "Mounts" "Select a mount:" "${menu_args[@]}"
}

load_mount() {
    local name=$1 file
    file=$(conf_file_for "$name")
    [[ -f $file ]] || { msg_err "unknown mount: $name"; return 1; }
    load_conf "$file"
}

connect_block_device() {
    case $PROTOCOL in
        iscsi)
            local pl="$OPT_PORTAL:$OPT_PORT"
            if ! iscsiadm -m session 2>/dev/null | grep -qF "$OPT_IQN"; then
                run_step "Logging in to $OPT_IQN" as_root iscsiadm \
                    -m node -T "$OPT_IQN" -p "$pl" --login || true
            fi
            ;;
        nvmeof)
            if [[ -n $UNIT && -f $UNITS_DIR/$UNIT ]] && systemd_running; then
                run_step "Starting $UNIT" as_root systemctl start "$UNIT" || true
            else
                run_step "Connecting to $OPT_NQN" as_root nvme connect \
                    -t "${OPT_TRANSPORT:-tcp}" -n "$OPT_NQN" \
                    -a "$OPT_ADDRESS" -s "$OPT_PORT" || true
            fi
            ;;
    esac
}

mount_existing() {
    local name=$1
    load_mount "$name" || return 1
    ensure_dep "$PROTOCOL" || return 1
    if is_mounted "$TARGET"; then
        ui_msg "Already mounted" "$TARGET is already mounted."
        return 0
    fi
    ensure_dir "$TARGET"
    connect_block_device
    if ! do_mount_by_fstab; then
        msg_warn "mounting via fstab failed, trying directly"
        if ! do_mount_direct; then
            ui_msg "Mount failed" \
                "Could not mount $SOURCE at $TARGET.\n\nSee the terminal output for the reason."
            return 1
        fi
    fi
    if ! verify_mounted "$TARGET"; then
        return 1
    fi
    ui_msg "Mounted" "$SOURCE $(mounted_phrase) $TARGET."
}

unmount_existing() {
    local name=$1
    load_mount "$name" || return 1
    if ! is_mounted "$TARGET"; then
        ui_msg "Not mounted" "$TARGET is not mounted."
        return 0
    fi
    if ! do_unmount "$TARGET"; then
        ui_msg "Unmount failed" "Could not unmount $TARGET."
        return 1
    fi
    msg_ok "unmounted $TARGET"
}

remove_existing() {
    local name=$1
    load_mount "$name" || return 1
    ui_yesno "Remove mount" \
"Remove '$NAME'?

  $SOURCE → $TARGET

The fstab entry, credentials and session are removed. Data on the server is not touched." || return 1

    set +e
    if is_mounted "$TARGET"; then
        do_unmount "$TARGET"
    fi
    case $PROTOCOL in
        iscsi)
            local pl="$OPT_PORTAL:$OPT_PORT"
            run_step "Logging out of target" as_root iscsiadm \
                -m node -T "$OPT_IQN" -p "$pl" --logout || true
            run_step "Removing node record" as_root iscsiadm \
                -m node -T "$OPT_IQN" -p "$pl" -o delete || true
            ;;
        nvmeof)
            if [[ -n $UNIT ]]; then
                if systemd_running; then
                    run_step "Removing boot unit" as_root systemctl disable --now "$UNIT" || true
                fi
                as_root rm -f "$UNITS_DIR/$UNIT" >/dev/null 2>&1 || true
                if systemd_running; then
                    as_root systemctl daemon-reload >/dev/null 2>&1 || true
                fi
            fi
            [[ -n $OPT_NQN ]] && run_step "Disconnecting $OPT_NQN" \
                as_root nvme disconnect -n "$OPT_NQN" || true
            ;;
    esac
    as_root rm -f "$(conf_file_for "$NAME")"
    if [[ -n $CRED_FILE ]]; then
        as_root rm -f "$CRED_FILE"
    fi
    as_root rmdir "$TARGET" >/dev/null 2>&1 || true
    sync_state || true
    run_step "Updating /etc/fstab" sync_fstab || true
    set -e
    msg_ok "$NAME removed"
}

show_details() {
    local name=$1 text
    load_mount "$name" || return 1
    text="Name:        $NAME
Protocol:    $PROTOCOL
Source:      $SOURCE
Mount point: $TARGET
Auto-mount:  $AUTOMOUNT
Read-only:   $([[ $READ_ONLY == 1 ]] && echo yes || echo no)
Status:      $(is_mounted "$TARGET" && echo mounted || echo "not mounted")
"
    [[ -n $DEVICE ]] && text+="Device:      $DEVICE"$'\n'
    [[ -n $UUID ]] && text+="UUID:        $UUID"$'\n'
    [[ -n $FS ]] && text+="Filesystem:  $FS"$'\n'
    [[ -n $CRED_FILE ]] && text+="Credentials: $CRED_FILE"$'\n'
    [[ -n $UNIT ]] && text+="Boot unit:   $UNIT"$'\n'
    [[ -n $EXTRA_OPTS ]] && text+="Extra opts:  $EXTRA_OPTS"$'\n'
    text+=$'\n'"fstab: $(build_fstab_line)"
    ui_msg "$NAME" "$text"
}

manage_mounts() {
    local name
    while :; do
        name=$(pick_mount) || return 0
        local action
        action=$(ui_menu_labels "$name" "What do you want to do?" \
            "Show details" \
            "Mount now" \
            "Unmount" \
            "Remove completely" \
            "Back to main menu") || return 0
        case $action in
            "Show details")      show_details "$name" || true ;;
            "Mount now")         mount_existing "$name" || true ;;
            "Unmount")           unmount_existing "$name" || true ;;
            "Remove completely") remove_existing "$name" || true ;;
            "Back to main menu") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# summary / check
# ---------------------------------------------------------------------------
print_summary() {
    local file total=0 active=0
    local tmp
    tmp=$(mktemp)
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        total=$((total + 1))
        local status="not mounted"
        if is_mounted "$TARGET"; then
            status="mounted"
            active=$((active + 1))
        fi
        printf '  %-16s %-8s %-12s %-26s %s\n' \
            "${NAME:0:16}" "${PROTOCOL:0:8}" "$status" "${TARGET:0:26}" "$SOURCE" >>"$tmp"
    done < <(conf_files)

    print_banner
    printf '  %sstorage control for Linux%s  ·  v%s  ·  %ssession summary%s\n' \
        "$C_DIM" "$C_RESET" "$APP_VERSION" "$C_BOLD" "$C_RESET"
    printf '  %s\n' "$(printf '─%.0s' {1..73})"
    if ((total == 0)); then
        printf '%sMounts: none configured%s\n' "$C_BOLD" "$C_RESET"
    else
        printf '\n%sMounts (%d/%d active)%s\n' "$C_BOLD" "$active" "$total" "$C_RESET"
        printf '  %s%-16s %-8s %-12s %-26s %s%s\n' \
            "$C_DIM" NAME PROTO STATUS TARGET SOURCE "$C_RESET"
        cat "$tmp"
    fi
    rm -f "$tmp"

    local any=0
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        ((any == 0)) && { printf '\n%sPersistence%s\n' "$C_BOLD" "$C_RESET"; any=1; }
        printf '  %-16s %-10s %s\n' "${NAME:0:16}" "$AUTOMOUNT" "$(build_fstab_line)"
    done < <(conf_files)

    printf '\n%sNotes%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s·%s configuration: %s\n' "$C_DIM" "$C_RESET" "$CONFIG_DIR"
    printf '  %s·%s preferences: %s\n' "$C_DIM" "$C_RESET" "$SETTINGS_FILE"
    printf '  %s·%s mounts are recorded in %s inside a managed block\n' \
        "$C_DIM" "$C_RESET" "$FSTAB"
    [[ -e $FSTAB_BAK ]] && printf '  %s·%s original fstab backup: %s\n' \
        "$C_DIM" "$C_RESET" "$FSTAB_BAK"
    [[ -d $CREDS_DIR ]] && printf '  %s·%s SMB credentials: %s (root only, mode 0600)\n' \
        "$C_DIM" "$C_RESET" "$CREDS_DIR"
    if ((DRY_RUN)); then
        printf '  %s·%s DRY RUN: no changes were made.\n' "$C_DIM" "$C_RESET"
    fi
    printf '\n'
}

run_check() {
    local pm
    pm=$(detect_pm || printf 'unsupported')
    pm=${pm%-get}
    printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
    printf '  user        : %s (uid %d)\n' "$(id -un)" "$(id -u)"
    printf '  root        : %s\n' "$([[ $EUID == 0 ]] && echo yes || echo no)"
    printf '  sudo        : %s\n' "$(command -v sudo >/dev/null 2>&1 && echo yes || echo no)"
    printf '  package mgr : %s\n' "$pm"
    printf '  config dir  : %s\n' "$CONFIG_DIR"
    printf '  mounts dir  : %s\n' "$MOUNTS_DIR"
    printf '  settings    : %s\n' "$SETTINGS_FILE"
    printf '  defaults    : smb=%s nfs=%s automount=%s\n' \
        "$SMB_VERSION" "$NFS_VERSION" "$DEFAULT_AUTOMOUNT"
    printf '  iSCSI       : port %s, lun %s (protocol 1.0)\n' "$ISCSI_PORT" "$ISCSI_LUN"
    printf '  NVMe-oF     : %s, port %s (spec negotiated)\n' "$NVME_TRANSPORT" "$NVME_PORT"
    printf '  mount root  : %s\n' "$MOUNT_ROOT"
    printf '  creds dir   : %s\n' "$CREDS_DIR"
    printf '  state file  : %s (%s)\n' "$STATE_FILE" \
        "$([[ -e $STATE_FILE ]] && echo present || echo missing)"
    printf '  fstab       : %s\n' "$FSTAB"
    printf '  managed     : %s\n' "$(grep -qF "$MARK_BEGIN" "$FSTAB" 2>/dev/null && echo yes || echo no)"
    printf '\n  %-10s %-14s %s\n' protocol package status
    local key bin pkg
    for key in cifs nfs iscsi nvmeof; do
        bin=$(dep_binary "$key")
        pkg=$(dep_package "$key")
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-10s %-14s %s\n' "$key" "$pkg" ok
        else
            printf '  %-10s %-14s %s\n' "$key" "$pkg" missing
        fi
    done
    local file total=0 active=0
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        total=$((total + 1))
        is_mounted "$TARGET" && active=$((active + 1))
    done < <(conf_files)
    printf '\n  mounts      : %d configured, %d mounted\n' "$total" "$active"
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        load_conf "$file"
        printf '    %-16s %-8s %-10s %s\n' "$NAME" "$PROTOCOL" \
            "$(is_mounted "$TARGET" && echo mounted || echo unmounted)" "$TARGET"
    done < <(conf_files)
}

# ---------------------------------------------------------------------------
# options / preferences
# ---------------------------------------------------------------------------
show_environment() {
    local tmp
    tmp=$(mktemp)
    run_check >"$tmp" 2>&1 || true
    ui_msg "Environment" "$(cat "$tmp")"
    rm -f "$tmp"
}

options_smb_version() {
    local value
    case $SMB_VERSION in
        3.1.1) MENU_DEFAULT="SMB 3.1.1 (latest: AES-GCM, pre-auth integrity)" ;;
        3.0)   MENU_DEFAULT="SMB 3.0 (widest compatibility)" ;;
        2.1)   MENU_DEFAULT="SMB 2.1 (older NAS)" ;;
        1.0)   MENU_DEFAULT="SMB 1.0 (legacy, insecure)" ;;
    esac
    if ! value=$(ui_menu_labels "Default SMB version" "Used for new CIFS / SMB mounts:" \
        "SMB 3.1.1 (latest: AES-GCM, pre-auth integrity)" \
        "SMB 3.0 (widest compatibility)" \
        "SMB 2.1 (older NAS)" \
        "SMB 1.0 (legacy, insecure)"); then
        MENU_DEFAULT=""
        return 0
    fi
    MENU_DEFAULT=""
    case $value in
        "SMB 3.1.1"*) SMB_VERSION=3.1.1 ;;
        "SMB 3.0"*)   SMB_VERSION=3.0 ;;
        "SMB 2.1"*)   SMB_VERSION=2.1 ;;
        *)            SMB_VERSION=1.0 ;;
    esac
    save_settings && ui_msg "Saved" "Default SMB version is now $SMB_VERSION."
}

options_nfs_version() {
    local value
    case $NFS_VERSION in
        4.2) MENU_DEFAULT="NFS 4.2 (latest)" ;;
        4.1) MENU_DEFAULT="NFS 4.1" ;;
        4.0) MENU_DEFAULT="NFS 4.0" ;;
        3)   MENU_DEFAULT="NFS 3 (legacy)" ;;
    esac
    if ! value=$(ui_menu_labels "Default NFS version" "Used for new NFS mounts:" \
        "NFS 4.2 (latest)" \
        "NFS 4.1" \
        "NFS 4.0" \
        "NFS 3 (legacy)"); then
        MENU_DEFAULT=""
        return 0
    fi
    MENU_DEFAULT=""
    case $value in
        "NFS 4.2"*) NFS_VERSION=4.2 ;;
        "NFS 4.1"*) NFS_VERSION=4.1 ;;
        "NFS 4.0"*) NFS_VERSION=4.0 ;;
        *)          NFS_VERSION=3 ;;
    esac
    save_settings && ui_msg "Saved" "Default NFS version is now $NFS_VERSION."
}

options_automount() {
    local value
    case $DEFAULT_AUTOMOUNT in
        boot)   MENU_DEFAULT="At boot (normal fstab entry)" ;;
        access) MENU_DEFAULT="On first access (systemd automount)" ;;
        manual) MENU_DEFAULT="Manual only (noauto)" ;;
    esac
    if ! value=$(ui_menu_labels "Default auto-mount" "Used for new mounts:" \
        "At boot (normal fstab entry)" \
        "On first access (systemd automount)" \
        "Manual only (noauto)"); then
        MENU_DEFAULT=""
        return 0
    fi
    MENU_DEFAULT=""
    case $value in
        "At boot"*)         DEFAULT_AUTOMOUNT=boot ;;
        "On first access"*) DEFAULT_AUTOMOUNT=access ;;
        *)                  DEFAULT_AUTOMOUNT=manual ;;
    esac
    save_settings && ui_msg "Saved" "Default auto-mount is now $DEFAULT_AUTOMOUNT."
}

options_mount_root() {
    local value
    value=$(ask_field "Default mount root" \
        "Base directory for new mount points:" "$MOUNT_ROOT" v_abs_dir) || return 0
    value=${value%/}
    [[ -z $value ]] && value=/
    MOUNT_ROOT=$value
    save_settings && ui_msg "Saved" "New mount points default to $MOUNT_ROOT/<name>."
}

options_creds_dir() {
    local value
    value=$(ask_field "Credentials directory" \
        "Where new SMB password files are stored (root-only, mode 0600):" \
        "$CREDS_DIR" v_creds_dir) || return 0
    value=${value%/}
    if ! ui_yesno "Credentials location" \
"New SMB credentials will be written to:

$value

Files stay root-owned with mode 0600. If this path is inside an
encrypted or network-mounted home directory, SMB mounts may fail at
boot before that location is available.

Existing credential files are not moved.

Use this directory?"; then
        return 0
    fi
    CREDS_DIR=$value
    save_settings && ui_msg "Saved" "SMB credentials will be stored in $CREDS_DIR."
}

move_config_tree() {
    local old=$1 new=$2 file base
    [[ $old == "$new" ]] && return 0
    ensure_config_dir "$new/mounts"
    if [[ -d $old/mounts ]]; then
        while IFS= read -r file; do
            [[ -n $file ]] || continue
            base=$(basename "$file")
            as_root mv -f "$file" "$new/mounts/$base" || return 1
            if ((EUID != 0)) && config_owned_by_user "$new/mounts/$base"; then
                as_root chown "$(id -u):$(id -g)" "$new/mounts/$base" 2>/dev/null || true
            fi
        done < <(find "$old/mounts" -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
        as_root rmdir "$old/mounts" 2>/dev/null || true
    fi
    if [[ -f $old/state.json ]]; then
        as_root mv -f "$old/state.json" "$new/state.json" || return 1
        if ((EUID != 0)) && config_owned_by_user "$new/state.json"; then
            as_root chown "$(id -u):$(id -g)" "$new/state.json" 2>/dev/null || true
        fi
    fi
    return 0
}

options_config_dir() {
    local value old=$CONFIG_DIR message
    value=$(ask_field "Config directory" \
        "Where mount definitions and state.json are stored:" \
        "$CONFIG_DIR" v_config_dir) || return 0
    value=${value%/}
    [[ $value == "$old" ]] && return 0
    if [[ $value == "$old"/* || $old == "$value"/* ]]; then
        ui_msg "Invalid location" "Choose a directory outside $old."
        return 0
    fi
    message="Mount definitions and state.json will move from:

  $old

to:

  $value

Existing mounts keep working; only the files move. The settings file
stays at $SETTINGS_FILE.

Move the configuration now?"
    if ! ui_yesno "Move configuration" "$message"; then
        return 0
    fi
    if ! move_config_tree "$old" "$value"; then
        ui_msg "Not moved" "Could not move the configuration. Nothing was changed."
        return 0
    fi
    CONFIG_DIR=$value
    MOUNTS_DIR="$CONFIG_DIR/mounts"
    STATE_FILE="$CONFIG_DIR/state.json"
    ensure_dir "$MOUNTS_DIR"
    sync_state || true
    run_step "Updating /etc/fstab" sync_fstab || true
    save_settings && ui_msg "Saved" "Mount definitions now live in $CONFIG_DIR."
}

options_iscsi_defaults() {
    local choice value
    while :; do
        choice=$(ui_menu_labels "iSCSI defaults" \
            "iSCSI uses protocol 1.0 (RFC 7143) — there is no version to choose" \
            "Default port — $ISCSI_PORT" \
            "Default LUN — $ISCSI_LUN" \
            "Back") || return 0
        case $choice in
            "Default port"*)
                value=$(ask_field "iSCSI default port" \
                    "Target portal port:" "$ISCSI_PORT" v_port_required) || return 0
                ISCSI_PORT=$value
                save_settings && ui_msg "Saved" "Default iSCSI port is now $ISCSI_PORT."
                ;;
            "Default LUN"*)
                value=$(ask_field "iSCSI default LUN" \
                    "LUN number:" "$ISCSI_LUN" v_lun) || return 0
                ISCSI_LUN=$value
                save_settings && ui_msg "Saved" "Default iSCSI LUN is now $ISCSI_LUN."
                ;;
            *) return 0 ;;
        esac
    done
}

options_nvme_defaults() {
    local choice value
    while :; do
        choice=$(ui_menu_labels "NVMe-oF defaults" \
            "The NVMe spec revision is negotiated by the controller; transport and port are yours to pick" \
            "Default transport — $NVME_TRANSPORT" \
            "Default port — $NVME_PORT" \
            "Back") || return 0
        case $choice in
            "Default transport"*)
                if [[ $NVME_TRANSPORT == rdma ]]; then
                    MENU_DEFAULT="RDMA (RoCE / InfiniBand)"
                else
                    MENU_DEFAULT="TCP (modern fabrics, most common)"
                fi
                if ! value=$(ui_menu_labels "NVMe-oF transport" "Default transport:" \
                    "TCP (modern fabrics, most common)" \
                    "RDMA (RoCE / InfiniBand)"); then
                    MENU_DEFAULT=""
                    return 0
                fi
                MENU_DEFAULT=""
                case $value in
                    "RDMA"*) NVME_TRANSPORT=rdma ;;
                    *)       NVME_TRANSPORT=tcp ;;
                esac
                save_settings && ui_msg "Saved" "Default NVMe-oF transport is now $NVME_TRANSPORT."
                ;;
            "Default port"*)
                value=$(ask_field "NVMe-oF default port" \
                    "Target port:" "$NVME_PORT" v_port_required) || return 0
                NVME_PORT=$value
                save_settings && ui_msg "Saved" "Default NVMe-oF port is now $NVME_PORT."
                ;;
            *) return 0 ;;
        esac
    done
}

options_reset() {
    if ! ui_yesno "Reset settings" \
        "Restore the built-in defaults?

  SMB 3.1.1   NFS 4.2   auto-mount: at boot
  iSCSI port 3260, LUN 0
  NVMe-oF tcp, port 4420
  mount root: /mnt
  credentials: /etc/storctl/credentials

The config directory is kept at $CONFIG_DIR so existing mounts are not
orphaned. Existing mounts and credential files are not changed."; then
        return 0
    fi
    SMB_VERSION=3.1.1
    NFS_VERSION=4.2
    ISCSI_PORT=3260
    ISCSI_LUN=0
    NVME_TRANSPORT=tcp
    NVME_PORT=4420
    DEFAULT_AUTOMOUNT=boot
    MOUNT_ROOT=/mnt
    CREDS_DIR=$(syspath /etc/storctl/credentials)
    save_settings && ui_msg "Reset" "Settings restored to defaults."
}

options_menu() {
    local choice
    while :; do
        choice=$(ui_menu_labels "Settings" "Saved in: $SETTINGS_FILE" \
            "SMB version — $SMB_VERSION" \
            "NFS version — $NFS_VERSION" \
            "iSCSI — port $ISCSI_PORT, LUN $ISCSI_LUN" \
            "NVMe-oF — $NVME_TRANSPORT, port $NVME_PORT" \
            "Auto-mount — $DEFAULT_AUTOMOUNT" \
            "Mount root — $MOUNT_ROOT" \
            "Config directory — $CONFIG_DIR" \
            "Credentials — $CREDS_DIR" \
            "Environment and dependency check" \
            "Show settings file" \
            "Reset to defaults" \
            "Back to main menu") || return 0
        case $choice in
            "SMB version"*)        options_smb_version ;;
            "NFS version"*)        options_nfs_version ;;
            "iSCSI"*)              options_iscsi_defaults ;;
            "NVMe-oF"*)            options_nvme_defaults ;;
            "Auto-mount"*)         options_automount ;;
            "Mount root"*)         options_mount_root ;;
            "Config directory"*)   options_config_dir ;;
            "Credentials"*)        options_creds_dir ;;
            "Environment and dependency check") show_environment ;;
            "Show settings file")
                if [[ -f $SETTINGS_FILE ]]; then
                    ui_msg "Settings file" "$SETTINGS_FILE\n\n$(cat "$SETTINGS_FILE")"
                else
                    ui_msg "Settings file" \
                        "$SETTINGS_FILE\n\nNot created yet — defaults are in use."
                fi
                ;;
            "Reset to defaults") options_reset ;;
            "Back to main menu") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# main menu
# ---------------------------------------------------------------------------
protocol_menu() {
    ui_menu_labels "New storage" "Choose a protocol:" \
        "SMB / CIFS — Windows shares, Samba, NAS" \
        "NFS — Unix exports" \
        "iSCSI — block storage (open-iscsi)" \
        "NVMe-oF — NVMe over TCP/RDMA" \
        "Back"
}

help_text() {
    cat <<'EOF'
Navigation
  Up / Down     move
  Enter         select or confirm
  Esc           cancel or go back
  Ctrl-C        exit immediately

The bottom buttons are optional. Every action can be reached with the
arrow keys and Enter from the menu or list.

Main menu
  Add storage   mount SMB/CIFS, NFS, iSCSI or NVMe-oF
  Manage        show details, mount, unmount or remove
  Settings      versions, ports, credentials, config, check

Safety
  Formatting requires choosing a filesystem and typing ERASE.
  Removing a mount never deletes data on the server.
EOF
}

main_menu() {
    local choice
    while :; do
        choice=$(ui_menu_labels "$BRAND_MARK $APP_NAME" "What do you want to do?" \
            "Add storage — SMB, NFS, iSCSI, NVMe-oF" \
            "Manage existing mounts" \
            "Settings — versions, credentials, config, check" \
            "Exit" \
            "Help — keys, protocols and safety") || continue
        case $choice in
            "Add storage"*)
                require_sudo_fresh
                local proto
                proto=$(protocol_menu) || continue
                case $proto in
                    "SMB / CIFS"*) add_cifs ;;
                    "NFS"*)        add_nfs ;;
                    "iSCSI"*)      add_iscsi ;;
                    "NVMe-oF"*)    add_nvmeof ;;
                    *)             continue ;;
                esac
                ;;
            "Manage existing mounts")  require_sudo_fresh; manage_mounts ;;
            "Settings"*)               options_menu ;;
            "Help"*)                   ui_msg "storctl help" "$(help_text)" ;;
            "Exit"|*)                  break ;;
        esac
    done
}

usage() {
    cat <<EOF
$APP_NAME $APP_VERSION — mount network and fabric storage

Usage:
  bash -c "\$(curl -fsSL https://iadityaharsh.github.io/storctl/storctl.sh)"
  ./storctl.sh                  interactive menu
  ./storctl.sh --check          environment and dependency status
  ./storctl.sh --summary        print the mount summary
  ./storctl.sh --dry-run        interactive, but run no commands
  ./storctl.sh --version
  ./storctl.sh --help

Interactive menu:
  Add a network drive · Manage existing mounts · Options · Quit
  Options holds SMB/NFS version defaults, iSCSI port/LUN, NVMe-oF
  transport/port, mount root, credentials directory, environment check
  and the settings file in the user's home.

Supported: CIFS/SMB, NFS, iSCSI (open-iscsi), NVMe-oF (nvme-cli).
Configuration lives in ~/.config/storctl (configurable in Options);
mounts live in a marked /etc/fstab block.
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case $arg in
            -h|--help) usage; return 0 ;;
            --version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; return 0 ;;
            --check) run_check; return 0 ;;
            --summary) print_summary; return 0 ;;
            --dry-run) DRY_RUN=1 ;;
            *) die "unknown argument: $arg (try --help)" 2 ;;
        esac
    done

    if [[ ! -t 0 || ! -t 1 ]]; then
        die "storctl needs an interactive terminal.
Run it as: bash -c \"\$(curl -fsSL .../storctl.sh)\"
Or use --check / --summary for scriptable output." 2
    fi
    [[ -n ${TERM:-} ]] || die "TERM is not set" 2

    apply_tui_theme
    printf '\n  %sstorage control for Linux%s  ·  v%s\n' \
        "$C_DIM" "$C_RESET" "$APP_VERSION"
    printf '  %sCtrl-C exits at any time. Configuration and fstab changes are logged.%s\n\n' \
        "$C_DIM" "$C_RESET"

    require_sudo
    ensure_whiptail
    main_menu
    print_summary
}

# Execute only when run, not when sourced (used by the test-suite).
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
