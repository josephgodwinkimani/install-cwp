#!/bin/bash
#
# ============================================================================
#  install-cwp.sh
#  Unattended installer, configurator and hardening script for
#  CentOS Web Panel (CWP) on:
#     - AlmaLinux 8 / 9
#     - CentOS Linux 7 / 8 / 9 (Stream)
#     - Rocky Linux 8 / 9
#
#  All required input is collected once, at the very start. Everything
#  after that runs unattended.
#
#  RESUME / CHECKPOINT DESIGN
#  ---------------------------------------------------------------------
#  Every mutating step is checkpointed to a state file. A systemd
#  one-shot resume unit is installed and enabled at the very beginning
#  of the run (before any mutating step executes) and stays enabled
#  until the script reaches true completion. This means:
#    - the two intentional reboots (post system-update, and the final
#      optional reboot) resume automatically, and
#    - an UNEXPECTED reboot/crash/power-loss at ANY point during ANY
#      step also resumes automatically on next boot, picking up exactly
#      where it left off instead of re-running already-completed work
#      or leaving the server half-configured.
#  Completed steps are recorded by name in $STATE_FILE and are skipped
#  on every subsequent invocation until the run fully completes, at
#  which point the resume unit and state file are removed.
#
#  On any failure the script stops immediately, reports the error, and
#  points to the log file. Nothing here silently continues past a
#  failure.
#
#  Usage (must be saved to disk and run as root, not piped from a URL):
#     sudo bash install-cwp.sh
#
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
C_RESET="\e[0m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RED="\e[0;31m"
C_BRED="\e[1;31m"
C_GREEN="\e[0;32m"
C_BGREEN="\e[1;32m"
C_YELLOW="\e[0;33m"
C_BYELLOW="\e[1;33m"
C_BLUE="\e[0;34m"
C_MAGENTA="\e[0;35m"
C_BMAGENTA="\e[1;35m"
C_CYAN="\e[0;36m"
C_BCYAN="\e[1;36m"
C_WHITE="\e[1;37m"

log_step() { printf "\n${C_BMAGENTA}▶ %s${C_RESET}\n" "$1"; }
log_sub()  { printf "  ${C_BLUE}•${C_RESET} %s\n" "$1"; }
log_info() { printf "${C_BCYAN}[INFO]${C_RESET} %s\n" "$1"; }
log_ok()   { printf "${C_BGREEN}[ OK ]${C_RESET} %s\n" "$1"; }
log_warn() { printf "${C_BYELLOW}[WARN]${C_RESET} %s\n" "$1"; }
log_err()  { printf "${C_BRED}[FAIL]${C_RESET} %s\n" "$1" >&2; }
log_hdr()  { printf "\n${C_WHITE}%s${C_RESET}\n" "$1"; }

# ----------------------------------------------------------------------------
# Persistent paths (survive reboots)
# ----------------------------------------------------------------------------
CONFIG_DIR="/etc/cwp-installer"
ANSWERS_FILE="${CONFIG_DIR}/answers.conf"
STATE_FILE="${CONFIG_DIR}/completed_steps"
PERSIST_SCRIPT="/usr/local/src/cwp-install.sh"
RESUME_UNIT="/etc/systemd/system/cwp-install-resume.service"
LOGFILE="/var/log/cwp_install.log"

mkdir -p "$CONFIG_DIR" /usr/local/src
touch "$LOGFILE" "$STATE_FILE"
exec > >(tee -a "$LOGFILE") 2>&1

SCRIPT_START_TIME=$(date +%s)

trap 'ret=$?; if [ $ret -ne 0 ]; then log_err "Script stopped in function \"${FUNCNAME[1]:-main}\" at line $LINENO while running: ${BASH_COMMAND}"; log_err "Exit code: $ret"; log_err "Full log: $LOGFILE"; log_err "Re-run this script to resume automatically from the last completed step."; fi; exit $ret' EXIT

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This script must be run as root (sudo bash install-cwp.sh)."
        exit 1
    fi
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -r -p "$(printf "${C_CYAN}?${C_RESET} %s [%s]: " "$prompt" "$default")" reply
        echo "${reply:-$default}"
    else
        read -r -p "$(printf "${C_CYAN}?${C_RESET} %s: " "$prompt")" reply
        echo "$reply"
    fi
}

confirm() {
    local prompt="$1" default="${2:-y}" reply hint="y/N"
    [ "$default" = "y" ] && hint="Y/n"
    while true; do
        read -r -p "$(printf "${C_CYAN}?${C_RESET} %s [%s]: " "$prompt" "$hint")" reply
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

die() {
    log_err "$1"
    exit 1
}

# ----------------------------------------------------------------------------
# Checkpoint / resume framework
# ----------------------------------------------------------------------------
step_done() {
    grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    step_done "$1" || echo "$1" >> "$STATE_FILE"
}

# Runs $1 (a function name) unless already marked complete in $STATE_FILE.
# On success, marks it complete. Steps must be idempotent/safe to be
# skipped entirely on resume - that is exactly what this guarantees.
run_step() {
    local name="$1"
    if step_done "$name"; then
        log_sub "Step '${name}' already completed in a previous run — skipping."
        return 0
    fi
    "$name"
    mark_done "$name"
}

install_resume_unit() {
    local script_path
    script_path="$(readlink -f "$0")"
    [ -f "$script_path" ] || die "Could not resolve the absolute path of this script for resume support."

    cp -f "$script_path" "$PERSIST_SCRIPT" || die "Could not persist installer script to $PERSIST_SCRIPT for post-reboot resume."
    chmod +x "$PERSIST_SCRIPT"

    cat > "$RESUME_UNIT" <<EOF
[Unit]
Description=Resume CWP unattended installation after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${PERSIST_SCRIPT}
RemainAfterExit=no
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cwp-install-resume.service >/dev/null 2>&1
    log_ok "Resume checkpoint active: any reboot from this point forward will automatically continue the installation."
}

remove_resume_unit() {
    systemctl disable cwp-install-resume.service >/dev/null 2>&1 || true
    rm -f "$RESUME_UNIT"
    systemctl daemon-reload
}

reboot_and_resume() {
    local reason="$1"
    log_warn "Rebooting now: ${reason}"
    log_warn "Full log: $LOGFILE"
    log_warn "The install will resume automatically after boot via cwp-install-resume.service."
    sync
    sleep 5
    systemctl reboot
    exit 0
}

# ============================================================================
# Step: Accurate OS detection - zero assumptions
# (Always re-run on every invocation - cheap, read-only, and later steps
#  need the variables it sets even after a resume.)
# ============================================================================
detect_os() {
    log_step "Detecting operating system"

    [ -f /etc/os-release ]      || die "/etc/os-release not found. Cannot identify the OS."
    [ -f /etc/redhat-release ]  || die "/etc/redhat-release not found. Only RHEL-family distros are supported."

    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
    REDHAT_RELEASE_CONTENT="$(cat /etc/redhat-release)"

    [ -n "$OS_ID" ]         || die "ID missing from /etc/os-release."
    [ -n "$OS_VERSION_ID" ] || die "VERSION_ID missing from /etc/os-release."

    OS_MAJOR="${OS_VERSION_ID%%.*}"
    case "$OS_MAJOR" in
        ''|*[!0-9]*) die "Could not parse a numeric major version from VERSION_ID='$OS_VERSION_ID'." ;;
    esac

    IS_STREAM=false
    echo "$REDHAT_RELEASE_CONTENT" | grep -qi "stream" && IS_STREAM=true

    CWP_TARGET=""
    DISTRO_LABEL=""
    PKGMGR=""

    case "$OS_ID" in
        almalinux)
            case "$OS_MAJOR" in
                8) CWP_TARGET="el8"; DISTRO_LABEL="AlmaLinux 8"; PKGMGR="dnf" ;;
                9) CWP_TARGET="el9"; DISTRO_LABEL="AlmaLinux 9"; PKGMGR="dnf" ;;
            esac
            ;;
        rocky)
            case "$OS_MAJOR" in
                8) CWP_TARGET="el8"; DISTRO_LABEL="Rocky Linux 8"; PKGMGR="dnf" ;;
                9) CWP_TARGET="el9"; DISTRO_LABEL="Rocky Linux 9"; PKGMGR="dnf" ;;
            esac
            ;;
        centos)
            case "$OS_MAJOR" in
                7) CWP_TARGET="el7"; DISTRO_LABEL="CentOS Linux 7"; PKGMGR="yum" ;;
                8) CWP_TARGET="el8"; DISTRO_LABEL="CentOS Linux 8$([ "$IS_STREAM" = true ] && echo ' Stream')"; PKGMGR="dnf" ;;
                9) CWP_TARGET="el9"; DISTRO_LABEL="CentOS Linux 9$([ "$IS_STREAM" = true ] && echo ' Stream')"; PKGMGR="dnf" ;;
            esac
            ;;
    esac

    [ -n "$CWP_TARGET" ] || die "Unsupported OS: $OS_PRETTY_NAME (ID=$OS_ID, VERSION_ID=$OS_VERSION_ID). Supported: AlmaLinux 8/9, CentOS Linux 7/8/9, Rocky Linux 8/9."

    ARCH="$(uname -m)"
    [ "$ARCH" = "x86_64" ] || die "Unsupported architecture '$ARCH'. CWP requires x86_64."

    command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) not found. This script requires a systemd-managed system."
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] || die "PID 1 is not systemd (container without systemd init?). Aborting."

    if grep -qa 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        die "This appears to be a container (Docker/LXC) rather than a dedicated/VM host. CWP requires a full systemd host. Aborting."
    fi

    log_ok "Detected: $DISTRO_LABEL ($OS_PRETTY_NAME) on $ARCH → CWP target: $CWP_TARGET (package manager: $PKGMGR)"
}

# ============================================================================
# Step: DNS resolver sanity check / automatic fallback
# (Always re-run - cheap, read-only unless it must intervene.)
# ============================================================================
ensure_dns_resolves() {
    log_step "Verifying DNS resolution"

    if getent hosts centos-webpanel.com >/dev/null 2>&1; then
        log_ok "DNS resolution is working."
        return
    fi

    log_warn "DNS resolution failed for centos-webpanel.com. Adding fallback resolvers to /etc/resolv.conf..."
    [ -f /etc/resolv.conf ] || touch /etc/resolv.conf
    grep -qx "nameserver 1.1.1.1" /etc/resolv.conf || echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    grep -qx "nameserver 8.8.8.8" /etc/resolv.conf || echo "nameserver 8.8.8.8" >> /etc/resolv.conf

    getent hosts centos-webpanel.com >/dev/null 2>&1 || die "DNS resolution still failing after adding fallback resolvers (1.1.1.1, 8.8.8.8). Check network/resolver configuration manually."
    log_ok "DNS resolution restored using fallback resolvers."
}

# ============================================================================
# Step: Accurate pre-flight checks
# (Always re-run on every invocation, including after resume - these are
#  read-only validations and later steps depend on the variables set here.)
# ============================================================================
preflight_checks() {
    log_step "Running pre-flight checks"

    local mem_kb mem_mb
    mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    mem_mb=$(( mem_kb / 1024 ))
    TOTAL_RAM_MB="$mem_mb"
    log_sub "RAM detected: ${mem_mb}MB"
    [ "$mem_mb" -ge 2048 ] || die "CWP requires at least 2048MB RAM. Detected ${mem_mb}MB."
    [ "$mem_mb" -ge 4096 ] || log_warn "Only ${mem_mb}MB RAM detected; 4096MB+ is recommended for full CWP feature support and reliable PHP compilation."

    local avail_gb
    avail_gb="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
    log_sub "Free space on /: ${avail_gb}GB"
    [ "$avail_gb" -ge 5 ] || die "At least 5GB free on / is required (CWP compiles Apache/PHP from source). Detected ${avail_gb}GB."
    [ "$avail_gb" -ge 10 ] || log_warn "Free space is below the recommended 10GB (${avail_gb}GB detected)."

    local cpu_count
    cpu_count="$(nproc)"
    log_sub "CPU cores detected: ${cpu_count}"
    [ "$cpu_count" -ge 1 ] || die "Could not detect any CPU cores."

    ensure_dns_resolves

    curl -fsS --max-time 10 -o /dev/null "https://centos-webpanel.com" || die "Cannot reach centos-webpanel.com over HTTPS. Check internet/firewall/proxy configuration."
    log_ok "Internet connectivity confirmed."

    local conflict=""
    [ -d /usr/local/cpanel ]       && conflict="cPanel"
    [ -d /usr/local/psa ]          && conflict="Plesk"
    [ -d /usr/local/directadmin ]  && conflict="DirectAdmin"
    [ -n "$conflict" ] && die "Detected an existing $conflict installation. CWP cannot coexist with another control panel."

    if [ -d /usr/local/cwpsrv ]; then
        CWP_ALREADY_INSTALLED=true
        log_warn "Existing CWP installation detected at /usr/local/cwpsrv - this run will reconfigure/harden it."
    else
        CWP_ALREADY_INSTALLED=false
    fi

    VIRT_TYPE="none"
    [ -f /proc/vz/veinfo ] && VIRT_TYPE="openvz"
    if [ "$VIRT_TYPE" = "none" ] && command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi
    log_sub "Virtualization: $VIRT_TYPE"

    log_ok "Pre-flight checks passed."
}

# ============================================================================
# Step: Ensure sufficient swap to prevent OOM during PHP compilation
# (Always re-run - idempotent, checks existing swap first.)
# ============================================================================
ensure_swap() {
    log_step "Verifying swap space"

    local swap_kb swap_mb
    swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
    swap_mb=$(( swap_kb / 1024 ))
    log_sub "Current swap: ${swap_mb}MB"

    if [ "$TOTAL_RAM_MB" -ge 4096 ]; then
        log_ok "RAM is 4096MB or higher - no additional swap required."
        return
    fi

    if [ "$swap_mb" -ge 2048 ]; then
        log_ok "Sufficient swap already present (${swap_mb}MB)."
        return
    fi

    log_warn "Low RAM (${TOTAL_RAM_MB}MB) with insufficient swap (${swap_mb}MB). Creating a 2GB swap file to prevent OOM during PHP compilation..."

    if [ -f /swapfile ]; then
        swapon /swapfile 2>/dev/null || true
    else
        if command -v fallocate >/dev/null 2>&1 && fallocate -l 2G /swapfile 2>/dev/null; then
            :
        else
            dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none || die "Failed to allocate /swapfile."
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null || die "mkswap failed on /swapfile."
        swapon /swapfile || die "swapon failed on /swapfile."
    fi

    grep -q "^/swapfile " /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

    swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
    swap_mb=$(( swap_kb / 1024 ))
    log_ok "Swap is now ${swap_mb}MB."
}

# ============================================================================
# Step: Collect ALL required input up front, then run fully unattended
# (Checkpointed: runs once. On resume, answers are loaded from disk
#  instead of prompting again.)
# ============================================================================
collect_user_input() {
    log_hdr "══════════════════════════════════════════════════════════════════"
    log_hdr "  CWP UNATTENDED INSTALLER — please answer the following, then"
    log_hdr "  the rest of the install (including any required reboots) runs"
    log_hdr "  automatically without further prompts."
    log_hdr "══════════════════════════════════════════════════════════════════"

    local current_hostname fqdn_regex="^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    current_hostname="$(hostname -f 2>/dev/null || hostname)"
    while true; do
        NEW_HOSTNAME="$(ask "FQDN hostname for this server (must NOT match any domain you will host, e.g. srv1.example.com)" "$current_hostname")"
        [[ "$NEW_HOSTNAME" =~ $fqdn_regex ]] && break
        log_warn "Not a valid FQDN (need host + domain, e.g. srv1.example.com)."
    done

    local default_tz
    default_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")"
    while true; do
        SERVER_TZ="$(ask "Server timezone (full list: timedatectl list-timezones)" "$default_tz")"
        timedatectl list-timezones | grep -qx "$SERVER_TZ" && break
        log_warn "'$SERVER_TZ' is not a recognized timezone."
    done

    while true; do
        CSF_ALERT_EMAIL="$(ask "Email address for CSF/LFD security alerts" "root@${NEW_HOSTNAME}")"
        [[ "$CSF_ALERT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
        log_warn "Not a valid email address."
    done

    log_hdr "Summary of what this script will do automatically:"
    cat <<SUMMARY
  Hostname               : $NEW_HOSTNAME
  Timezone                : $SERVER_TZ
  CSF alert email          : $CSF_ALERT_EMAIL
  SELinux                  : set to Permissive
  Swap                      : created automatically if RAM < 4096MB and swap < 2048MB
  DNS resolver              : fallback added automatically if resolution fails
  Firewall                  : all other firewalls removed, CSF+LFD installed & hardened
                               (ports restricted to the official CWP service list)
  PHP                       : hardened - dangerous functions disabled across every
                               discovered PHP version (switcher, alt/php*, alt/php-fpm*)
  MySQL/MariaDB             : tuned (buffer pool, connections) and security-hardened
  Postfix                   : verified healthy, IPv4+IPv6 enabled
  Amavisd                   : Bayes disabled to prevent known 100% CPU issue (if present)
  ClamAV real-time AV        : enabled automatically if RAM >= 4096MB (${TOTAL_RAM_MB}MB detected)
  CXS exploit scanner        : installed
  Policyd mail rate limit    : installed (250 msgs/hour/domain default)
  Journald log trimming      : daily cron at 22:30, 1-day retention
  Resume support             : any reboot at any step (planned or unexpected) resumes
                                automatically and picks up exactly where it left off
  Reboot                     : required after the OS update step (automatic, resumes
                                itself); a final reboot will be OFFERED (not forced)
                                once everything else finishes
SUMMARY
    confirm "Proceed with unattended installation using these settings?" "y" || die "Aborted by user."

    {
        echo "NEW_HOSTNAME=\"$NEW_HOSTNAME\""
        echo "SERVER_TZ=\"$SERVER_TZ\""
        echo "CSF_ALERT_EMAIL=\"$CSF_ALERT_EMAIL\""
    } > "$ANSWERS_FILE"
    chmod 600 "$ANSWERS_FILE"
    log_ok "Answers saved to $ANSWERS_FILE (used automatically on every resumed run)."
}

load_answers() {
    [ -f "$ANSWERS_FILE" ] || die "Answers file $ANSWERS_FILE not found - cannot resume. Delete $STATE_FILE to start over."
    # shellcheck disable=SC1090
    . "$ANSWERS_FILE"
    [ -n "${NEW_HOSTNAME:-}" ]    || die "NEW_HOSTNAME missing from answers file."
    [ -n "${SERVER_TZ:-}" ]       || die "SERVER_TZ missing from answers file."
    [ -n "${CSF_ALERT_EMAIL:-}" ] || die "CSF_ALERT_EMAIL missing from answers file."
}

# ============================================================================
# Step: Apply hostname, timezone, SELinux
# ============================================================================
apply_hostname_timezone() {
    log_step "Applying hostname, timezone and SELinux mode"

    hostnamectl set-hostname "$NEW_HOSTNAME"
    if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
        local primary_ip
        primary_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
        [ -n "$primary_ip" ] && echo "$primary_ip $NEW_HOSTNAME ${NEW_HOSTNAME%%.*}" >> /etc/hosts
    fi
    log_ok "Hostname set to $(hostname -f)"

    timedatectl set-timezone "$SERVER_TZ"
    log_ok "Timezone set to $SERVER_TZ"

    if command -v setenforce >/dev/null 2>&1; then
        setenforce 0 2>/dev/null || true
    fi
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    fi
    log_ok "SELinux set to permissive."
}

# ============================================================================
# Step: Prepare repos/packages exactly per official CWP quick-start guide
# ============================================================================
prepare_repos_and_packages() {
    log_step "Preparing repositories and base packages ($CWP_TARGET)"

    if [ "$CWP_TARGET" = "el7" ]; then
        log_sub "Applying CentOS 7 mirror-to-vault repository fix..."
        curl -fsS http://centos-webpanel.com/centos7_fix_repository | sh
        yum -y install wget curl || die "Failed to install wget/curl."
    else
        log_sub "Installing EPEL release package..."
        if ! rpm -q epel-release >/dev/null 2>&1; then
            dnf -y install epel-release || \
            dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" || \
            die "Failed to install epel-release."
        fi
        dnf -y install wget curl || die "Failed to install wget/curl."
    fi

    log_ok "Base packages ready."
}

# ============================================================================
# Step: Full system update, then required reboot
# This step marks ITSELF done before rebooting, so on resume it is
# skipped and execution continues with the next step (install_cwp).
# ============================================================================
system_update_and_reboot() {
    log_step "Performing full system update"

    if [ "$CWP_TARGET" = "el7" ]; then
        yum -y update || die "System update failed."
    else
        dnf -y update || die "System update failed."
    fi
    log_ok "System packages updated."

    mark_done "system_update_and_reboot"
    reboot_and_resume "required after full system update, as per the official CWP installation guide"
}

# ============================================================================
# Step: Install CWP
# ============================================================================
install_cwp() {
    if [ "$CWP_ALREADY_INSTALLED" = true ]; then
        log_step "Skipping CWP installer (already installed) - proceeding to configuration"
        return
    fi

    log_step "Downloading and running the official CWP installer for $CWP_TARGET"
    cd /usr/local/src

    local installer="cwp-${CWP_TARGET}-latest"
    rm -f "./$installer"
    wget -q "http://centos-webpanel.com/${installer}" -O "$installer" || die "Failed to download $installer."
    [ -s "$installer" ] || die "Downloaded CWP installer ($installer) is empty."
    chmod +x "$installer"

    log_warn "CWP compiles Apache and PHP from source. This can take 30+ minutes - do not interrupt."
    log_info "The installer is run with automatic restart disabled so this script keeps full control of reboots."
    sh "./$installer" -r no || die "CWP installer exited with an error."

    [ -d /usr/local/cwpsrv ] || die "CWP installation did not complete (/usr/local/cwpsrv missing)."
    log_ok "CWP core installation complete."
}

# ============================================================================
# Step: Firewall - remove all others, install & harden CSF
# ============================================================================
configure_firewall() {
    log_step "Removing other firewalls and deploying CSF (CWP-recommended firewall)"

    for svc in firewalld nftables ufw; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            log_sub "Disabling and masking $svc..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
        fi
    done
    if command -v firewall-cmd >/dev/null 2>&1; then
        if [ "$CWP_TARGET" = "el7" ]; then yum -y remove firewalld 2>/dev/null || true
        else dnf -y remove firewalld 2>/dev/null || true; fi
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw disable 2>/dev/null || true
        if [ "$CWP_TARGET" = "el7" ]; then yum -y remove ufw 2>/dev/null || true
        else dnf -y remove ufw 2>/dev/null || true; fi
    fi

    touch /etc/sysconfig/iptables /etc/sysconfig/ip6tables
    if [ "$CWP_TARGET" = "el7" ]; then
        yum -y install iptables-services wget perl unzip net-tools perl-libwww-perl perl-LWP-Protocol-https perl-GDGraph || die "Failed installing iptables-services/deps."
    else
        dnf -y install iptables-services wget perl unzip net-tools perl-libwww-perl perl-LWP-Protocol-https perl-GDGraph || die "Failed installing iptables-services/deps."
    fi
    systemctl enable --now iptables 2>/dev/null || true
    systemctl enable --now ip6tables 2>/dev/null || true

    if [ "$VIRT_TYPE" = "openvz" ] && echo "$REDHAT_RELEASE_CONTENT" | grep -qi "release 8"; then
        log_warn "OpenVZ + EL8 detected: pinning iptables to a CSF-compatible legacy version."
        dnf -y remove iptables iptables-services iptables-libs 2>/dev/null || true
        dnf -y install https://vault.centos.org/centos/7/os/x86_64/Packages/iptables-1.4.21-35.el7.x86_64.rpm 2>/dev/null || true
        dnf -y install yum-plugin-versionlock 2>/dev/null || true
        dnf versionlock iptables iptables-services iptables-libs 2>/dev/null || true
    fi

    if [ ! -d /etc/csf ]; then
        log_sub "Installing CSF (ConfigServer Security & Firewall)..."
        cd /root
        rm -f ./csf.tgz
        wget -q https://download.configserver.com/csf.tgz -O csf.tgz || die "Failed to download CSF."
        tar xfz csf.tgz
        cd ./csf
        sh ./install.sh || die "CSF install.sh failed."
    else
        log_sub "CSF already installed - reconfiguring."
    fi

    log_sub "Applying CSF hardening profile..."
    local conf=/etc/csf/csf.conf
    sed -i 's/^TESTING = .*/TESTING = "0"/' "$conf"
    sed -i 's/^ICMP_IN = .*/ICMP_IN = "1"/' "$conf"
    sed -i 's/^DENY_IP_LIMIT = .*/DENY_IP_LIMIT = "400"/' "$conf"
    sed -i 's/^SAFECHAINUPDATE = .*/SAFECHAINUPDATE = "1"/' "$conf"
    sed -i 's/^SMTP_BLOCK = .*/SMTP_BLOCK = "1"/' "$conf"
    sed -i 's/^SMTP_ALLOWGROUP = .*/SMTP_ALLOWGROUP = "mail,mailman,postfix"/' "$conf"
    sed -i 's/^LF_FTPD = .*/LF_FTPD = "30"/' "$conf"
    sed -i 's/^LF_SMTPAUTH = .*/LF_SMTPAUTH = "90"/' "$conf"
    sed -i 's/^LF_POP3D = .*/LF_POP3D = "100"/' "$conf"
    sed -i 's/^LF_IMAPD = .*/LF_IMAPD = "100"/' "$conf"
    sed -i 's/^LF_HTACCESS = .*/LF_HTACCESS = "40"/' "$conf"
    sed -i 's/^LF_CPANEL = .*/LF_CPANEL = "40"/' "$conf"
    sed -i 's/^LF_MODSEC = .*/LF_MODSEC = "100"/' "$conf"
    sed -i 's/^CT_SKIP_TIME_WAIT = .*/CT_SKIP_TIME_WAIT = "1"/' "$conf"
    sed -i 's/^CONNLIMIT = .*/CONNLIMIT = "80;70,110;50,993;50,143;50,25;30"/' "$conf"
    sed -i 's/^LF_PERMBLOCK_INTERVAL = .*/LF_PERMBLOCK_INTERVAL = "14400"/' "$conf"
    sed -i 's/^LF_INTERVAL = .*/LF_INTERVAL = "900"/' "$conf"
    sed -i 's/^PS_INTERVAL = .*/PS_INTERVAL = "60"/' "$conf"
    sed -i 's/^PS_LIMIT = .*/PS_LIMIT = "20"/' "$conf"
    sed -i "s/^LF_ALERT_TO = .*/LF_ALERT_TO = \"$CSF_ALERT_EMAIL\"/" "$conf" 2>/dev/null || true
    sed -i 's/^LF_EMAIL_ALERT = .*/LF_EMAIL_ALERT = "1"/' "$conf"
    sed -i 's/^LF_CPANEL_ALERT = .*/LF_CPANEL_ALERT = "1"/' "$conf"
    sed -i 's/^RT_RELAY_ALERT = .*/RT_RELAY_ALERT = "1"/' "$conf"
    sed -i 's/^RT_AUTHRELAY_ALERT = .*/RT_AUTHRELAY_ALERT = "1"/' "$conf"

    sed -i '/^#SPAMDROP/s/^#//' /etc/csf/csf.blocklists
    sed -i '/^#SPAMEDROP/s/^#//' /etc/csf/csf.blocklists
    sed -i '/^#DSHIELD/s/^#//' /etc/csf/csf.blocklists
    sed -i '/^#HONEYPOT/s/^#//' /etc/csf/csf.blocklists
    sed -i '/^#BDE|/s/^#//' /etc/csf/csf.blocklists
    sed -i '/^SPAMDROP/s/|0|/|300|/' /etc/csf/csf.blocklists
    sed -i '/^SPAMEDROP/s/|0|/|300|/' /etc/csf/csf.blocklists
    sed -i '/^DSHIELD/s/|0|/|300|/' /etc/csf/csf.blocklists
    sed -i '/^HONEYPOT/s/|0|/|300|/' /etc/csf/csf.blocklists
    sed -i '/^BDE|/s/|0|/|300|/' /etc/csf/csf.blocklists

    cat > /etc/csf/csf.rignore << 'EOF'
.cpanel.net
.googlebot.com
.crawl.yahoo.net
.search.msn.com
EOF

    # Explicit CWP service port list (per CWP "Mostly Used Ports" reference).
    # WHOIS(43), RSYNC(873) and MySQL(3306) are intentionally excluded from
    # inbound per CWP's own recommendation not to expose them publicly.
    local CWP_TCP_IN="20,21,22,25,26,53,80,110,143,443,465,993,995,2030,2031,2082,2083,2086,2087,2304"
    local CWP_TCP_OUT="20,21,22,25,26,37,43,53,80,110,113,443,465,587,873,993,995,2030,2031,2082,2083,2086,2087,2304"

    sed -i "s/^TCP_IN = .*/TCP_IN = \"${CWP_TCP_IN}\"/" "$conf"
    sed -i "s/^TCP_OUT = .*/TCP_OUT = \"${CWP_TCP_OUT}\"/" "$conf"

    sed -i 's/^IPV6 = .*/IPV6 = "1"/' "$conf"
    sed -i "s/^TCP6_IN = .*/TCP6_IN = \"${CWP_TCP_IN}\"/" "$conf"
    sed -i "s/^TCP6_OUT = .*/TCP6_OUT = \"${CWP_TCP_OUT}\"/" "$conf"

    /usr/sbin/csf -e || die "Failed to enable CSF."
    systemctl enable --now lfd || die "Failed to enable/start lfd."
    systemctl enable csf
    log_ok "CSF firewall installed, configured, and enabled."
}

# ============================================================================
# Step: Exhaustive PHP hardening across every discovered PHP version
# ============================================================================
DISABLE_FUNCTIONS_LIST="apache_get_modules,apache_get_version,apache_getenv,apache_note,apache_setenv,debug_zval_dump,dl,disk_free_space,diskfreespace,eval,exec,highlight_file,ini_alter,ini_restore,openlog,passthru,popen,proc_open,shell_exec,show_source,symlink,system"

restart_service_if_exists() {
    local svc="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl restart "$svc" && log_sub "Restarted ${svc}." || log_warn "Failed to restart ${svc} - review manually."
    elif command -v service >/dev/null 2>&1 && service "$svc" status >/dev/null 2>&1; then
        service "$svc" restart && log_sub "Restarted ${svc}." || log_warn "Failed to restart ${svc} - review manually."
    else
        log_sub "${svc} has no active service unit - skipped restart (not currently running)."
    fi
}

harden_php() {
    log_step "Hardening PHP configuration (exhaustive, all discovered versions)"

    local ini_files
    ini_files=$(find /usr/local/php /opt/alt -name "php.ini" 2>/dev/null || true)
    [ -n "$ini_files" ] || die "No php.ini files found after CWP installation - installation likely incomplete."

    log_sub "Applying baseline php.ini hardening to $(echo "$ini_files" | wc -l) file(s)..."
    while IFS= read -r ini; do
        sed -i 's/^memory_limit.*/memory_limit = 1024M/' "$ini"
        sed -i 's/^enable_dl.*/enable_dl = Off/' "$ini"
        sed -i 's/^expose_php.*/expose_php = Off/' "$ini"
        sed -i "s/^disable_functions.*/disable_functions = ${DISABLE_FUNCTIONS_LIST}/" "$ini"
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' "$ini"
        sed -i 's/^post_max_size.*/post_max_size = 72M/' "$ini"
        sed -i "s/^date.timezone.*/date.timezone = \"${SERVER_TZ}\"/" "$ini"
        sed -i 's/^allow_url_fopen.*/allow_url_fopen = On/' "$ini"
        sed -i 's/^max_execution_time.*/max_execution_time = 120/' "$ini"
        sed -i 's/^max_input_time.*/max_input_time = 120/' "$ini"
        sed -i 's/^max_input_vars.*/max_input_vars = 2000/' "$ini"
        sed -i 's/^;default_charset = "UTF-8"/default_charset = "UTF-8"/' "$ini"
        sed -i 's/^default_charset.*/default_charset = "UTF-8"/' "$ini"
        sed -i 's/^display_errors.*/display_errors = Off/' "$ini"
        sed -i 's/^log_errors.*/log_errors = On/' "$ini"
        sed -i 's/^error_reporting.*/error_reporting = E_ALL \& ~E_DEPRECATED \& ~E_STRICT \& ~E_NOTICE/' "$ini"
        sed -i 's/^session.cookie_httponly.*/session.cookie_httponly = 1/' "$ini"
    done <<< "$ini_files"
    log_ok "Baseline php.ini hardening applied."

    log_sub "Deploying disabled_function.ini drop-ins across every discovered PHP installation..."
    local dropins_written=0

    # PHP Switcher (main CWP-managed PHP)
    if [ -d /usr/local/php ]; then
        mkdir -p /usr/local/php/php.d
        echo "disable_functions = ${DISABLE_FUNCTIONS_LIST}" > /usr/local/php/php.d/disabled_function.ini
        dropins_written=$((dropins_written + 1))
    fi

    # PHP-CGI Selector: every /opt/alt/phpNN (excludes php-fpmNN, which starts with "php-")
    while IFS= read -r -d '' phpdir; do
        if [ -d "${phpdir}/usr/php" ]; then
            mkdir -p "${phpdir}/usr/php/php.d"
            echo "disable_functions = ${DISABLE_FUNCTIONS_LIST}" > "${phpdir}/usr/php/php.d/disabled_function.ini"
            dropins_written=$((dropins_written + 1))
        fi
    done < <(find /opt/alt -maxdepth 1 -type d -name 'php[0-9]*' -print0 2>/dev/null)

    # PHP-FPM Selector: every /opt/alt/php-fpmNN, restart matching fpm service
    while IFS= read -r -d '' fpmdir; do
        if [ -d "${fpmdir}/usr/php" ]; then
            mkdir -p "${fpmdir}/usr/php/php.d"
            echo "disable_functions = ${DISABLE_FUNCTIONS_LIST}" > "${fpmdir}/usr/php/php.d/disabled_function.ini"
            dropins_written=$((dropins_written + 1))
            restart_service_if_exists "$(basename "$fpmdir")"
        fi
    done < <(find /opt/alt -maxdepth 1 -type d -name 'php-fpm*' -print0 2>/dev/null)

    [ "$dropins_written" -gt 0 ] || die "No PHP installations were found to harden (expected at least the main CWP PHP switcher)."
    log_ok "Deployed disabled_function.ini to ${dropins_written} PHP installation(s)."

    [ -x /scripts/restart_httpd ] && { sh /scripts/restart_httpd || die "Failed to restart Apache/httpd after PHP hardening."; }
    [ -x /scripts/restart_cwpsrv ] && sh /scripts/restart_cwpsrv
    log_ok "Exhaustive PHP hardening complete."
}

# ============================================================================
# Step: MySQL/MariaDB tuning + hardening
# ============================================================================
tune_mysql() {
    log_step "Tuning and securing MySQL/MariaDB"

    command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1 || die "No MySQL/MariaDB daemon found after CWP installation."

    local mycnf="/etc/my.cnf"
    [ -f "$mycnf" ] || mycnf="/etc/mysql/my.cnf"
    [ -f "$mycnf" ] || die "Could not locate my.cnf."

    local version_string is_maria=false
    version_string=$(mysqld --version 2>/dev/null || mariadbd --version 2>/dev/null || echo "")
    echo "$version_string" | grep -qi "mariadb" && is_maria=true

    local buffer_pool_mb=$(( TOTAL_RAM_MB * 50 / 100 ))
    [ "$buffer_pool_mb" -lt 128 ] && buffer_pool_mb=128
    local max_conn=100
    [ "$TOTAL_RAM_MB" -ge 8192 ] && max_conn=200

    for setting in local-infile query_cache_type query_cache_size join_buffer_size tmp_table_size max_heap_table_size innodb_buffer_pool_size innodb_log_file_size innodb_flush_log_at_trx_commit innodb_file_per_table max_connections skip-networking bind-address symbolic-links; do
        sed -i "/^${setting}[[:space:]]*=.*/d" "$mycnf"
    done
    sed -i '/^# CWP-hardening-block-start/,/^# CWP-hardening-block-end/d' "$mycnf"

    local tmpblock
    tmpblock="$(mktemp)"
    {
        echo "# CWP-hardening-block-start"
        echo "local-infile=0"
        echo "symbolic-links=0"
        echo "max_connections=${max_conn}"
        echo "innodb_file_per_table=1"
        echo "innodb_buffer_pool_size=${buffer_pool_mb}M"
        echo "innodb_flush_log_at_trx_commit=1"
        echo "join_buffer_size=8M"
        echo "tmp_table_size=192M"
        echo "max_heap_table_size=256M"
        if [ "$is_maria" = true ]; then
            echo "query_cache_type=1"
            echo "query_cache_size=16M"
        fi
        echo "# CWP-hardening-block-end"
    } > "$tmpblock"

    if grep -q "^\[mysqld\]" "$mycnf"; then
        sed -i "/^\[mysqld\]/r ${tmpblock}" "$mycnf"
    else
        { echo "[mysqld]"; cat "$tmpblock"; cat "$mycnf"; } > "${mycnf}.new" && mv "${mycnf}.new" "$mycnf"
    fi
    rm -f "$tmpblock"

    systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null || systemctl restart mariadb 2>/dev/null || die "Failed to restart MySQL/MariaDB after tuning."

    [ -f /root/.my.cnf ] || die "/root/.my.cnf not found - cannot apply MySQL security hardening."
    mysql --defaults-file=/root/.my.cnf <<'SQL' || die "MySQL security hardening statements failed."
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
FLUSH PRIVILEGES;
SQL

    log_ok "MySQL/MariaDB tuned (buffer pool ${buffer_pool_mb}MB, max_connections ${max_conn}) and hardened."
}

# ============================================================================
# Step: Postfix health check
# ============================================================================
ensure_postfix_healthy() {
    log_step "Verifying Postfix mail service health"

    command -v postconf >/dev/null 2>&1 || die "Postfix not found after CWP installation."

    sed -i '/^inet_protocols.*/d' /etc/postfix/main.cf
    echo "inet_protocols = all" >> /etc/postfix/main.cf

    systemctl enable postfix >/dev/null 2>&1 || true
    systemctl restart postfix || die "Postfix failed to restart."

    sleep 2
    systemctl is-active --quiet postfix || die "Postfix is not active after restart. Check: journalctl -u postfix -n 50"
    log_ok "Postfix is active."

    if ss -tlnp 2>/dev/null | grep -q ":25 "; then
        log_ok "Postfix is listening on port 25."
    else
        die "Postfix is not listening on port 25."
    fi
}

# ============================================================================
# Step: Amavisd known 100% CPU issue mitigation
# ============================================================================
fix_amavisd_cpu_issue() {
    log_step "Applying Amavisd Bayes-related CPU fix (known CWP issue)"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "^amavisd\.service"; then
        log_sub "Amavisd not installed on this system - skipping."
        return
    fi

    local sa_conf="/etc/mail/spamassassin/local.cf"
    [ -f "$sa_conf" ] || die "Amavisd is present but $sa_conf was not found."

    grep -q "^use_bayes 0" "$sa_conf" || echo "use_bayes 0" >> "$sa_conf"
    grep -q "^bayes_auto_learn 0" "$sa_conf" || echo "bayes_auto_learn 0" >> "$sa_conf"

    systemctl restart amavisd || die "Failed to restart amavisd after applying the Bayes fix."
    log_ok "Amavisd Bayes learning disabled and service restarted."
}

# ============================================================================
# Step: ClamAV (enabled automatically based on detected RAM)
# ============================================================================
configure_clamav() {
    log_step "Configuring mail antivirus (ClamAV)"

    if [ "$TOTAL_RAM_MB" -ge 4096 ]; then
        if [ "$CWP_TARGET" = "el7" ]; then
            yum -y install clamav clamav-update clamd || die "Failed to install ClamAV."
        else
            dnf -y install clamav clamav-update clamd || die "Failed to install ClamAV."
        fi
        systemctl enable --now clamd@amavisd 2>/dev/null || systemctl enable --now clamd 2>/dev/null || die "Failed to enable ClamAV daemon."
        log_ok "ClamAV real-time scanning enabled (${TOTAL_RAM_MB}MB RAM detected)."
    else
        systemctl disable --now clamd 2>/dev/null || true
        systemctl disable --now clamd@amavisd 2>/dev/null || true
        log_warn "ClamAV real-time scanning left disabled - insufficient RAM (${TOTAL_RAM_MB}MB, 4096MB recommended)."
    fi
}

# ============================================================================
# Step: CXS (ConfigServer eXploit Scanner)
# ============================================================================
install_cxs() {
    log_step "Installing ConfigServer eXploit Scanner (CXS)"

    local server_ip
    server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
    [ -n "$server_ip" ] || die "Could not determine primary IPv4 address for CXS licensing."

    cd /usr/src
    rm -f cxs*
    wget -q https://download.configserver.com/cxsinstaller.tgz -O cxsinstaller.tgz || die "Failed to download CXS installer."
    tar -xzf cxsinstaller.tgz
    chattr -i -R /usr/local/cwpsrv/htdocs/admin/ 2>/dev/null || true
    perl cxsinstaller.pl "$server_ip" || die "CXS installation failed."
    rm -fv cxsinstaller.*

    if [ "$TOTAL_RAM_MB" -ge 4096 ] && [ -f /etc/cxs/cxs.defaults ]; then
        grep -q "^clamdsock=" /etc/cxs/cxs.defaults || echo "clamdsock=/var/run/clamd.amavisd/clamd.sock" >> /etc/cxs/cxs.defaults
        systemctl restart cxswatch 2>/dev/null || true
    fi
    log_ok "CXS installed. Finish onscreen setup later in CWP > ConfigServer Scripts > ConfigServer Exploit Scanner."
}

# ============================================================================
# Step: Policyd (mail rate limiting)
# ============================================================================
install_policyd() {
    log_step "Installing Policyd mail rate-limiting"

    [ -x /scripts/install_cbpolicyd ] || die "/scripts/install_cbpolicyd not found - CWP mail stack incomplete."
    sh /scripts/install_cbpolicyd || die "Policyd installation failed."
    /scripts/cwp_api account update_policyd_all 2>/dev/null || true
    systemctl enable --now cbpolicyd 2>/dev/null || die "Failed to enable cbpolicyd service."
    log_ok "Policyd installed (default limit: 250 messages/hour/domain)."
}

# ============================================================================
# Step: journald log cleanup cron
# ============================================================================
setup_journald_cleanup() {
    log_step "Scheduling daily systemd-journald log trimming"

    command -v journalctl >/dev/null 2>&1 || die "journalctl not found."

    cat > /etc/cron.d/clean_journal << 'EOF'
# Trim systemd-journald logs older than 1 day, daily at 22:30, to conserve disk space.
30 22 * * * root /usr/bin/journalctl --vacuum-time=1d > /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/clean_journal
    log_ok "Created /etc/cron.d/clean_journal (runs daily at 22:30)."
}

# ============================================================================
# Step: Final disk check
# ============================================================================
final_disk_check() {
    log_step "Final disk space check"
    local avail_gb
    avail_gb="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
    if [ "$avail_gb" -lt 3 ]; then
        log_warn "Only ${avail_gb}GB free on / after installation. Expand storage soon."
    else
        log_ok "${avail_gb}GB free on / after installation."
    fi
}

# ============================================================================
# Step: Final summary + optional reboot (asked, never forced)
# ============================================================================
final_summary() {
    local server_ip elapsed
    server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
    elapsed=$(( $(date +%s) - SCRIPT_START_TIME ))

    log_hdr "══════════════════════════════════════════════════════════════════"
    log_hdr "  CWP INSTALLATION AND HARDENING COMPLETE"
    log_hdr "══════════════════════════════════════════════════════════════════"
    cat <<SUMMARY
  Distro                  : $DISTRO_LABEL ($CWP_TARGET)
  Hostname                 : $(hostname -f)
  Timezone                 : $SERVER_TZ
  Server IP                : ${server_ip:-unknown}
  CWP Admin URL             : https://${server_ip:-YOUR-SERVER-IP}:2087
  CWP User Panel URL        : https://${server_ip:-YOUR-SERVER-IP}:2083
  Firewall                  : CSF/LFD (all other firewalls removed, CWP port list applied)
  SELinux                   : Permissive
  Swap                       : $(( $(awk '/SwapTotal/{print $2}' /proc/meminfo) / 1024 ))MB
  PHP hardening              : dangerous functions disabled on every discovered PHP version
  ClamAV real-time AV         : $([ "$TOTAL_RAM_MB" -ge 4096 ] && echo enabled || echo disabled)
  CXS exploit scanner         : installed
  Policyd mail limiting       : installed
  Journald cleanup cron       : /etc/cron.d/clean_journal (daily 22:30, 1-day retention)
  Full log file               : $LOGFILE
  Elapsed time (this run)     : $(( elapsed / 60 ))m $(( elapsed % 60 ))s

  NOTES:
   - Root MySQL credentials are stored in /root/.my.cnf — keep this file secure.
   - CWP root/admin credentials were printed earlier by the CWP installer;
     they are captured in $LOGFILE if you need them again.
   - A full reboot is recommended to finalize the kernel, CSF/iptables,
     MySQL, PHP-FPM and Postfix configuration on a clean boot.
SUMMARY

    mark_done "final_summary"
    remove_resume_unit
    rm -f "$STATE_FILE"

    if confirm "Reboot now?" "n"; then
        log_warn "Rebooting now..."
        sync
        systemctl reboot
    else
        log_warn "Reboot skipped. Please reboot manually as soon as convenient: systemctl reboot"
        log_ok "Full log available at: $LOGFILE"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    require_root

    # Always re-run these — cheap, read-only, idempotent, and later steps
    # depend on the variables they populate even on a resumed invocation.
    detect_os
    preflight_checks
    ensure_swap

    # Enable resume support BEFORE any mutating step runs, so that even
    # an unplanned reboot during the very first mutating step is covered.
    install_resume_unit

    if step_done "collect_user_input"; then
        log_sub "Using previously collected answers from $ANSWERS_FILE (resumed run)."
        load_answers
    else
        collect_user_input
        mark_done "collect_user_input"
    fi

    run_step "apply_hostname_timezone"
    run_step "prepare_repos_and_packages"
    run_step "system_update_and_reboot"   # reboots + exits internally if not yet done
    run_step "install_cwp"
    run_step "configure_firewall"
    run_step "harden_php"
    run_step "tune_mysql"
    run_step "ensure_postfix_healthy"
    run_step "fix_amavisd_cpu_issue"
    run_step "configure_clamav"
    run_step "install_cxs"
    run_step "install_policyd"
    run_step "setup_journald_cleanup"
    run_step "final_disk_check"
    run_step "final_summary"
}

main "$@"
