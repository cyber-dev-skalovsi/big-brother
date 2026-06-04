#!/bin/sh

is_alpine() {
  [ -f /etc/alpine-release ]
}

is_openwrt() {
  [ -f /etc/os-release ] && grep -qi "OpenWrt" /etc/os-release
}

is_freebsd() {
  [ "$(uname -s)" = "FreeBSD" ]
}

is_opnsense() {
  [ -f /usr/local/sbin/opnsense-version ] || [ -f /usr/local/etc/opnsense-version ] || [ -f /etc/opnsense-release ]
}

is_pfsense() {
  [ -f /etc/rc.bootup ] && grep -qi "pfSense" /etc/rc.bootup
}

is_glibc() {
  # Prefer glibc-enabled agent (NVML via purego) on linux/amd64 glibc systems.
  # Check common dynamic loader paths first (fast + reliable).
  for p in \
    /lib64/ld-linux-x86-64.so.2 \
    /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    /lib/ld-linux-x86-64.so.2; do
    [ -e "$p" ] && return 0
  done

  # Fallback to ldd output if available.
  if command -v ldd >/dev/null 2>&1; then
    ldd --version 2>&1 | grep -qiE 'gnu libc|glibc' && return 0
  fi

  return 1
}


# If SELinux is enabled, set the context of the binary
set_selinux_context() {
  # Check if SELinux is enabled and in enforcing or permissive mode
  if command -v getenforce >/dev/null 2>&1; then
    SELINUX_MODE=$(getenforce)
    if [ "$SELINUX_MODE" != "Disabled" ]; then
      echo "SELinux is enabled (${SELINUX_MODE} mode). Setting appropriate context..."

      # First try to set persistent context if semanage is available
      if command -v semanage >/dev/null 2>&1; then
        echo "Attempting to set persistent SELinux context..."
        if semanage fcontext -a -t bin_t "$BIN_PATH" >/dev/null 2>&1; then
          restorecon -v "$BIN_PATH" >/dev/null 2>&1
        else
          echo "Warning: Failed to set persistent context, falling back to temporary context."
        fi
      fi

      # Fall back to chcon if semanage failed or isn't available
      if command -v chcon >/dev/null 2>&1; then
        # Set context for both the directory and binary
        chcon -t bin_t "$BIN_PATH" || echo "Warning: Failed to set SELinux context for binary."
        chcon -R -t bin_t "$AGENT_DIR" || echo "Warning: Failed to set SELinux context for directory."
      else
        if [ "$SELINUX_MODE" = "Enforcing" ]; then
          echo "Warning: SELinux is in enforcing mode but chcon command not found. The service may fail to start."
          echo "Consider installing the policycoreutils package or temporarily setting SELinux to permissive mode."
        else
          echo "Warning: SELinux is in permissive mode but chcon command not found."
        fi
      fi
    fi
  fi
}

# Clean up SELinux contexts if they were set
cleanup_selinux_context() {
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Cleaning up SELinux contexts..."
    # Remove persistent context if semanage is available
    if command -v semanage >/dev/null 2>&1; then
      semanage fcontext -d "$BIN_PATH" 2>/dev/null || true
    fi
  fi
}

# Ensure the proxy URL ends with a /
ensure_trailing_slash() {
  if [ -n "$1" ]; then
    case "$1" in
    */) echo "$1" ;;
    *) echo "$1/" ;;
    esac
  else
    echo "$1"
  fi
}

# Read the listen address from the active service configuration. Existing
# service files are kept as they are, so the configured address can differ from
# $PORT, which falls back to the default when -p is not passed. LISTEN is
# checked before PORT to match the agent's own precedence, and the value is read
# as text so host:port and unix socket paths survive.
configured_address() {
  if is_alpine || is_openwrt; then
    address_file=/etc/init.d/bigbrother-agent
  elif is_freebsd; then
    address_file="$AGENT_DIR/env"
  else
    address_file=/etc/systemd/system/bigbrother-agent.service
  fi

  [ -f "$address_file" ] || return 0

  address_value=$(sed -n 's/.*LISTEN="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$address_file" | head -n 1)
  if [ -z "$address_value" ]; then
    address_value=$(sed -n 's/.*PORT="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$address_file" | head -n 1)
  fi

  printf '%s\n' "$address_value"
}

# Escape text for use in the replacement portion of a sed s command whose
# delimiter is |. This only escapes sed replacement metacharacters; quoting
# for the destination configuration syntax is handled separately.
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# Generate FreeBSD rc service content
generate_freebsd_rc_service() {
  cat <<'EOF'
#!/bin/sh

# PROVIDE: bigbrother_agent
# REQUIRE: DAEMON NETWORKING
# BEFORE: LOGIN
# KEYWORD: shutdown

# Add the following lines to /etc/rc.conf to configure Big Brother Agent:
#
# bigbrother_agent_enable (bool):   Set to YES to enable Big Brother Agent
#                               Default: YES
# bigbrother_agent_env_file (str):  Big Brother Agent env configuration file
#                               Default: /usr/local/etc/bigbrother-agent/env
# bigbrother_agent_user (str):      Big Brother Agent daemon user
#                               Default: bigbrother
# bigbrother_agent_bin (str):       Path to the bigbrother-agent binary
#                               Default: /usr/local/sbin/bigbrother-agent
# bigbrother_agent_flags (str):     Extra flags passed to bigbrother-agent command invocation
#                               Default:

. /etc/rc.subr

name="bigbrother_agent"
rcvar=bigbrother_agent_enable

load_rc_config $name
: ${bigbrother_agent_enable:="YES"}
: ${bigbrother_agent_user:="bigbrother"}
: ${bigbrother_agent_flags:=""}
: ${bigbrother_agent_env_file:="/usr/local/etc/bigbrother-agent/env"}
: ${bigbrother_agent_bin:="/usr/local/sbin/bigbrother-agent"}

logfile="/var/log/${name}.log"
pidfile="/var/run/${name}.pid"

procname="/usr/sbin/daemon"
start_precmd="${name}_prestart"
start_cmd="${name}_start"
stop_cmd="${name}_stop"

extra_commands="upgrade"
upgrade_cmd="bigbrother_agent_upgrade"

bigbrother_agent_prestart()
{
    if [ ! -f "${bigbrother_agent_env_file}" ]; then
        echo WARNING: missing "${bigbrother_agent_env_file}" env file. Start aborted.
        exit 1
    fi
}

bigbrother_agent_start()
{
    echo "Starting ${name}"
    /usr/sbin/daemon -fc \
            -P "${pidfile}" \
            -o "${logfile}" \
            -u "${bigbrother_agent_user}" \
            "${bigbrother_agent_bin}" ${bigbrother_agent_flags}
}

bigbrother_agent_stop()
{
    pid="$(check_pidfile "${pidfile}" "${procname}")"
    if [ -n "${pid}" ]; then
        echo "Stopping ${name} (pid=${pid})"
        kill -- "-${pid}"
        wait_for_pids "${pid}"
    else
        echo "${name} isn't running"
    fi
}

bigbrother_agent_upgrade()
{
    echo "Upgrading ${name}"
    if command -v sudo >/dev/null; then
        sudo -u "${bigbrother_agent_user}" -- "${bigbrother_agent_bin}" update
    else
        su -m "${bigbrother_agent_user}" -c "${bigbrother_agent_bin} update"
    fi
}

run_rc_command "$1"
EOF
}

# Generate the boot hook used by the firewall appliances, neither of which
# starts an enabled rc.d service at boot. The script body is identical for
# both; only the install path differs (see the boot hook installation below).
# The running-check guards against a double start, since pfSense may also run
# the hook again during network events.
generate_appliance_boot_script() {
  cat <<'EOF'
#!/bin/sh

if ! /usr/sbin/service bigbrother-agent status >/dev/null 2>&1; then
    /usr/sbin/service bigbrother-agent onestart
fi
EOF
}

# Detect system architecture
detect_architecture() {
  local arch=$(uname -m)

  if [ "$arch" = "mips" ]; then
    detect_mips_endianness
    return $?
  fi

  case "$arch" in
    x86_64)
      arch="amd64"
      ;;
    armv5*)
      arch="armv5"
      ;;
    armv6l)
      arch="arm"
      ;;
    armv7l)
      arch="armv7"
      ;;
    aarch64)
      arch="arm64"
      ;;
  esac

  echo "$arch"
}

# Detect MIPS endianness using ELF header
detect_mips_endianness() {
  local bins="/bin/sh /bin/ls /usr/bin/env"
  local bin_to_check endian
  
  for bin_to_check in $bins; do
    if [ -f "$bin_to_check" ]; then
      # The 6th byte in ELF header: 01 = little, 02 = big
      endian=$(hexdump -n 1 -s 5 -e '1/1 "%02x"' "$bin_to_check" 2>/dev/null)
      if [ "$endian" = "01" ]; then
        echo "mipsle"
        return
      elif [ "$endian" = "02" ]; then
        echo "mips" 
        return
      fi
    fi
  done
  
  # Final fallback
  echo "mips"
}

# Default values
PORT=45876
UNINSTALL=false
GITHUB_URL="https://github.com"
GITHUB_PROXY_URL=""
KEY=""
TOKEN=""
HUB_URL=""
AUTO_UPDATE_FLAG="" # empty string means prompt, "true" means auto-enable, "false" means skip
# Track which of the reconfigurable values were explicitly passed as arguments,
# so a reinstall only overwrites the fields the caller actually asked to change.
KEY_PROVIDED=false
PORT_PROVIDED=false
TOKEN_PROVIDED=false
HUB_URL_PROVIDED=false
VERSION="latest"

# Check for help flag
case "$1" in
-h | --help)
  printf "Big Brother Agent installation script\n\n"
  printf "Usage: ./install-agent.sh [options]\n\n"
  printf "Options: \n"
  printf "  -k                    : SSH key (required, or interactive if not provided)\n"
  printf "  -p                    : Port (default: $PORT)\n"
  printf "  -t                    : Token (optional for backwards compatibility)\n"
  printf "  -url                  : Hub URL (optional for backwards compatibility)\n"
  printf "  -v, --version         : Version to install (default: latest)\n"
  printf "  -u                    : Uninstall Big Brother Agent\n"
  printf "  --auto-update [VALUE] : Control automatic daily updates\n"
  printf "                          VALUE can be true (enable) or false (disable). If not specified, will prompt.\n"
  printf "  --mirror [URL]        : Use GitHub proxy to resolve network timeout issues in mainland China\n"
  printf "                          URL: optional custom proxy URL (default: https://github.com/cyber-dev-skalovsi/big-brother)\n"
  printf "  -h, --help            : Display this help message\n"
  exit 0
  ;;
esac

# Build sudo args by properly quoting everything
build_sudo_args() {
  QUOTED_ARGS=""
  while [ $# -gt 0 ]; do
    if [ -n "$QUOTED_ARGS" ]; then
      QUOTED_ARGS="$QUOTED_ARGS "
    fi
    QUOTED_ARGS="$QUOTED_ARGS'$(printf '%s' "$1" | sed "s/'/'\\\\''/g")'"
    shift
  done
  printf '%s\n' "$QUOTED_ARGS"
}

# Check if running as root and re-execute with sudo if needed
if [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO_ARGS=$(build_sudo_args "$@")
    eval "exec sudo $0 $SUDO_ARGS"
  else
    echo "This script must be run as root. Please either:"
    echo "1. Run this script as root (su root)"
    echo "2. Install sudo and run with sudo"
    exit 1
  fi
fi

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
  -k)
    shift
    KEY="$1"
    KEY_PROVIDED=true
    ;;
  -p)
    shift
    PORT="$1"
    PORT_PROVIDED=true
    ;;
  -t)
    shift
    TOKEN="$1"
    TOKEN_PROVIDED=true
    ;;
  -url)
    shift
    HUB_URL="$1"
    HUB_URL_PROVIDED=true
    ;;
  -v | --version)
    shift
    VERSION="$1"
    ;;
  -u)
    UNINSTALL=true
    ;;
  --mirror* | --china-mirrors*)
    # Check if there's a value after the = sign
    if echo "$1" | grep -q "="; then
      # Extract the value after =
      CUSTOM_PROXY=$(echo "$1" | cut -d'=' -f2)
      if [ -n "$CUSTOM_PROXY" ]; then
        GITHUB_PROXY_URL="$CUSTOM_PROXY"
        GITHUB_URL="$(ensure_trailing_slash "$CUSTOM_PROXY")https://github.com"
      else
        GITHUB_PROXY_URL="https://github.com/cyber-dev-skalovsi/big-brother"
        GITHUB_URL="$GITHUB_PROXY_URL"
      fi
    elif [ "$2" != "" ] && ! echo "$2" | grep -q '^-'; then
      # use custom proxy URL provided as next argument
      GITHUB_PROXY_URL="$2"
      GITHUB_URL="$(ensure_trailing_slash "$2")https://github.com"
      shift
    else
      # No value specified, use default
      GITHUB_PROXY_URL="https://github.com/cyber-dev-skalovsi/big-brother"
      GITHUB_URL="$GITHUB_PROXY_URL"
    fi
    ;;
  --auto-update*)
    # Check if there's a value after the = sign
    if echo "$1" | grep -q "="; then
      # Extract the value after =
      AUTO_UPDATE_VALUE=$(echo "$1" | cut -d'=' -f2)
      if [ "$AUTO_UPDATE_VALUE" = "true" ]; then
        AUTO_UPDATE_FLAG="true"
      elif [ "$AUTO_UPDATE_VALUE" = "false" ]; then
        AUTO_UPDATE_FLAG="false"
      else
        echo "Invalid value for --auto-update flag: $AUTO_UPDATE_VALUE. Using default (prompt)."
      fi
    elif [ "$2" = "true" ] || [ "$2" = "false" ]; then
      # Value provided as next argument
      AUTO_UPDATE_FLAG="$2"
      shift
    else
      # No value specified, use true
      AUTO_UPDATE_FLAG="true"
    fi
    ;;
  *)
    echo "Invalid option: $1" >&2
    exit 1
    ;;
  esac
  shift
done

# Set paths based on operating system
if is_freebsd; then
  AGENT_DIR="/usr/local/etc/bigbrother-agent"
  BIN_DIR="/usr/local/sbin"
  BIN_PATH="/usr/local/sbin/bigbrother-agent"
else
  AGENT_DIR="/opt/bigbrother-agent"
  BIN_DIR="/opt/bigbrother-agent"
  BIN_PATH="/opt/bigbrother-agent/bigbrother-agent"
fi

# Stop existing service if it exists (for upgrades)
if [ "$UNINSTALL" != true ] && [ -f "$BIN_PATH" ]; then
  echo "Existing installation detected. Stopping service for upgrade..."
  if is_alpine; then
    rc-service bigbrother-agent stop 2>/dev/null || true
  elif is_openwrt; then
    /etc/init.d/bigbrother-agent stop 2>/dev/null || true
  elif is_freebsd; then
    service bigbrother-agent stop 2>/dev/null || true
  else
    systemctl stop bigbrother-agent.service 2>/dev/null || true
  fi
fi

# Uninstall process
if [ "$UNINSTALL" = true ]; then
  # Clean up SELinux contexts before removing files
  cleanup_selinux_context

  if is_alpine; then
    echo "Stopping and disabling the agent service..."
    rc-service bigbrother-agent stop
    rc-update del bigbrother-agent default

    echo "Removing the OpenRC service files..."
    rm -f /etc/init.d/bigbrother-agent

    # Remove the daily update cron job if it exists
    echo "Removing the daily update cron job..."
    if crontab -u root -l 2>/dev/null | grep -q "bigbrother-agent.*update"; then
      crontab -u root -l 2>/dev/null | grep -v "bigbrother-agent.*update" | crontab -u root -
    fi

    # Remove log files
    echo "Removing log files..."
    rm -f /var/log/bigbrother-agent.log /var/log/bigbrother-agent.err
  elif is_openwrt; then
    echo "Stopping and disabling the agent service..."
    /etc/init.d/bigbrother-agent stop
    /etc/init.d/bigbrother-agent disable

    echo "Removing the OpenWRT service files..."
    rm -f /etc/init.d/bigbrother-agent

    # Remove the update service if it exists
    echo "Removing the daily update service..."
    # Remove legacy bigbrother account based crontab file
    rm -f /etc/crontabs/bigbrother
    # Install root crontab job
    if crontab -u root -l 2>/dev/null | grep -q "bigbrother-agent.*update"; then
      crontab -u root -l 2>/dev/null | grep -v "bigbrother-agent.*update" | crontab -u root -
    fi

  elif is_freebsd; then
    echo "Stopping and disabling the agent service..."
    service bigbrother-agent stop
    sysrc bigbrother_agent_enable="NO"

    echo "Removing the FreeBSD service files..."
    rm -f /usr/local/etc/rc.d/bigbrother-agent
    rm -f /usr/local/etc/rc.d/bigbrother-agent-start.sh

    # Remove the OPNsense boot hook if it exists
    rm -f /usr/local/etc/rc.syshook.d/start/99-bigbrother-agent

    # Remove the daily update cron job if it exists
    echo "Removing the daily update cron job..."
    rm -f /etc/cron.d/bigbrother-agent

    # Remove log files. The rc script derives its logfile from $name
    # (bigbrother_agent), not from the script filename (bigbrother-agent).
    echo "Removing log files..."
    rm -f /var/log/bigbrother_agent.log

    # Remove env file and directories
    echo "Removing environment configuration file..."
    rm -f "$AGENT_DIR/env"
    rm -f "$BIN_PATH"
    rmdir "$AGENT_DIR" 2>/dev/null || true

  else
    echo "Stopping and disabling the agent service..."
    systemctl stop bigbrother-agent.service
    systemctl disable bigbrother-agent.service >/dev/null 2>&1

    echo "Removing the systemd service file..."
    rm /etc/systemd/system/bigbrother-agent.service

    # Remove the update timer and service if they exist
    echo "Removing the daily update service and timer..."
    systemctl stop bigbrother-agent-update.timer 2>/dev/null
    systemctl disable bigbrother-agent-update.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/bigbrother-agent-update.service
    rm -f /etc/systemd/system/bigbrother-agent-update.timer

    systemctl daemon-reload
  fi

  echo "Removing the Big Brother Agent directory..."
  rm -rf "$AGENT_DIR"

  echo "Removing the dedicated user for the agent service..."
  killall bigbrother-agent 2>/dev/null
  if is_alpine || is_openwrt; then
    deluser bigbrother 2>/dev/null
  elif is_freebsd; then
    pw user del bigbrother 2>/dev/null
  else
    userdel bigbrother 2>/dev/null
  fi

  echo "Big Brother Agent has been uninstalled successfully!"
  exit 0
fi

# Check if a package is installed
package_installed() {
  command -v "$1" >/dev/null 2>&1
}

# Check for package manager and install necessary packages if not installed
if package_installed apk; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    apk update
    apk add tar curl coreutils shadow
  fi
elif package_installed opkg; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    opkg update
    opkg install tar curl coreutils
  fi
elif package_installed pkg && is_freebsd; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    pkg update
    pkg install -y gtar curl coreutils
  fi
elif package_installed apt-get; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    apt-get update
    apt-get install -y tar curl coreutils
  fi
elif package_installed yum; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    yum install -y tar curl coreutils
  fi
elif package_installed pacman; then
  if ! package_installed tar || ! package_installed curl || ! package_installed sha256sum; then
    pacman -Sy --noconfirm tar curl coreutils
  fi
else
  echo "Warning: Please ensure 'tar' and 'curl' and 'sha256sum (coreutils)' are installed."
fi

# If no SSH key is provided, ask for the SSH key interactively (skip if upgrading)
if [ -z "$KEY" ]; then
  if [ -f "$BIN_PATH" ]; then
    echo "Upgrading existing installation. Using existing service configuration."
  else
    printf "Enter your SSH key: "
    read KEY
  fi
fi

# Remove newlines from KEY
KEY=$(printf '%s' "$KEY" | tr -d '\n')

# TOKEN and HUB_URL are optional for backwards compatibility - no interactive prompts
# They will be set as empty environment variables if not provided

# Verify checksum
if command -v sha256sum >/dev/null; then
  CHECK_CMD="sha256sum"
elif command -v sha256 >/dev/null; then
  # FreeBSD uses 'sha256' instead of 'sha256sum', with different output format
  CHECK_CMD="sha256 -q"
else
  echo "No SHA256 checksum utility found"
  exit 1
fi

# Create a dedicated user for the service if it doesn't exist
AGENT_USER="bigbrother"
echo "Configuring the dedicated user for the Big Brother Agent service..."
if is_alpine; then
  if ! id -u bigbrother >/dev/null 2>&1; then
    addgroup bigbrother
    adduser -S -D -H -s /sbin/nologin -G bigbrother bigbrother
  fi
  # Add the user to the docker group to allow access to the Docker socket if group docker exists
  if getent group docker >/dev/null 2>&1; then
    echo "Adding bigbrother to docker group"
    addgroup bigbrother docker
  fi
  
elif is_openwrt; then
  # Create bigbrother group first if it doesn't exist (check /etc/group directly)
  if ! grep -q "^bigbrother:" /etc/group >/dev/null 2>&1; then
    echo "bigbrother:x:999:" >> /etc/group
  fi
  
  # Create bigbrother user if it doesn't exist (double-check to prevent duplicates)
  if ! id -u bigbrother >/dev/null 2>&1 && ! grep -q "^bigbrother:" /etc/passwd >/dev/null 2>&1; then
    echo "bigbrother:x:999:999::/nonexistent:/bin/false" >> /etc/passwd
  fi
  
  # Add the user to the docker group if docker group exists and user is not already in it
  if grep -q "^docker:" /etc/group >/dev/null 2>&1; then
    echo "Adding bigbrother to docker group"
    # Check if bigbrother is already in docker group
    if ! grep "^docker:" /etc/group | grep -q "bigbrother"; then
      # Add bigbrother to docker group by modifying /etc/group
      # Handle both cases: group with existing members and group without members
      if grep "^docker:" /etc/group | grep -q ":.*:.*$"; then
        # Group has existing members, append with comma
        sed -i 's/^docker:\([^:]*:[^:]*:\)\(.*\)$/docker:\1\2,bigbrother/' /etc/group
      else
        # Group has no members, just append
        sed -i 's/^docker:\([^:]*:[^:]*:\)$/docker:\1bigbrother/' /etc/group
      fi
    fi
  fi

elif is_freebsd; then
  if is_opnsense || is_pfsense; then
    echo "Firewall appliance detected: skipping user creation (using daemon user instead)"
    AGENT_USER="daemon"
  else
    if ! id -u bigbrother >/dev/null 2>&1; then
      pw user add bigbrother -d /nonexistent -s /usr/sbin/nologin -c "bigbrother user"
    fi
    # Add the user to the wheel group to allow self-updates
    if pw group show wheel >/dev/null 2>&1; then
      echo "Adding bigbrother to wheel group for self-updates"
      pw group mod wheel -m bigbrother
    fi
  fi

else
  if ! id -u bigbrother >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /bin/false bigbrother
  fi
  # Add the user to the docker group to allow access to the Docker socket if group docker exists
  if getent group docker >/dev/null 2>&1; then
    echo "Adding bigbrother to docker group"
    usermod -aG docker bigbrother
  fi
  # Add the user to the disk group to allow access to disk devices if group disk exists
  if getent group disk >/dev/null 2>&1; then
    echo "Adding bigbrother to disk group"
    usermod -aG disk bigbrother
  fi
fi

# Create the directory for the Big Brother Agent

if [ ! -d "$AGENT_DIR" ]; then
  echo "Creating the directory for the Big Brother Agent..."
  mkdir -p "$AGENT_DIR"
  chown "${AGENT_USER}:${AGENT_USER}" "$AGENT_DIR"
  chmod 755 "$AGENT_DIR"
fi

if [ ! -d "$BIN_DIR" ]; then
  mkdir -p "$BIN_DIR"
fi

# Download and install the Big Brother Agent

OS=$(uname -s | sed -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/')
ARCH=$(detect_architecture)
FILE_NAME="bigbrother-agent_${OS}_${ARCH}.tar.gz"
if [ "$OS" = "linux" ] && [ "$ARCH" = "amd64" ] && is_glibc; then
  FILE_NAME="bigbrother-agent_${OS}_${ARCH}_glibc.tar.gz"
fi

# Determine version to install
if [ "$VERSION" = "latest" ]; then
  INSTALL_VERSION=$(curl -s "https://get.github.com/cyber-dev-skalovsi/big-brother/latest-version")
  if [ -z "$INSTALL_VERSION" ]; then
    # Fallback to GitHub API
    API_RELEASE_URL="https://api.github.com/repos/cyber-dev-skalovsi/big-brother/releases/latest"
    INSTALL_VERSION=$(curl -s "$API_RELEASE_URL" | grep -o '"tag_name": "v[^"]*"' | cut -d'"' -f4 | tr -d 'v')
  fi
  if [ -z "$INSTALL_VERSION" ]; then
    echo "Failed to get latest version"
    exit 1
  fi
else
  INSTALL_VERSION="$VERSION"
  # Remove 'v' prefix if present
  INSTALL_VERSION=$(echo "$INSTALL_VERSION" | sed 's/^v//')
fi

echo "Downloading bigbrother-agent v${INSTALL_VERSION}..."

# Download checksums file
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || exit 1
CHECKSUM=$(curl -fsSL "$GITHUB_URL/cyber-dev-skalovsi/big-brother/releases/download/v${INSTALL_VERSION}/bigbrother_${INSTALL_VERSION}_checksums.txt" | grep "$FILE_NAME" | cut -d' ' -f1)
if [ -z "$CHECKSUM" ] || ! echo "$CHECKSUM" | grep -qE "^[a-fA-F0-9]{64}$"; then
  echo "Failed to get checksum or invalid checksum format"
  echo "Try again with --mirror (or --mirror <url>) if GitHub is not reachable."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! curl -fL# --retry 3 --retry-delay 2 --connect-timeout 10 "$GITHUB_URL/cyber-dev-skalovsi/big-brother/releases/download/v${INSTALL_VERSION}/$FILE_NAME" -o "$FILE_NAME"; then
  echo "Failed to download the agent from $GITHUB_URL/cyber-dev-skalovsi/big-brother/releases/download/v${INSTALL_VERSION}/$FILE_NAME"
  echo "Try again with --mirror (or --mirror <url>) if GitHub is not reachable."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! tar -tzf "$FILE_NAME" >/dev/null 2>&1; then
  echo "Downloaded archive is invalid or incomplete (possible network/proxy issue)."
  echo "Try again with --mirror (or --mirror <url>) if the download path is unstable."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if [ "$($CHECK_CMD "$FILE_NAME" | cut -d' ' -f1)" != "$CHECKSUM" ]; then
  echo "Checksum verification failed: $($CHECK_CMD "$FILE_NAME" | cut -d' ' -f1) & $CHECKSUM"
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! tar -xzf "$FILE_NAME" bigbrother-agent; then
  echo "Failed to extract the agent"
  rm -rf "$TEMP_DIR"
  exit 1
fi

if [ ! -s "$TEMP_DIR/bigbrother-agent" ]; then
  echo "Downloaded binary is missing or empty."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if [ -f "$BIN_PATH" ]; then
  echo "Backing up existing binary..."
  cp "$BIN_PATH" "$BIN_PATH.bak"
fi

mv bigbrother-agent "$BIN_PATH"
chown "${AGENT_USER}:${AGENT_USER}" "$BIN_PATH"
chmod 755 "$BIN_PATH"

# Set SELinux context if needed
set_selinux_context

# Cleanup
rm -rf "$TEMP_DIR"

# Make sure /etc/machine-id exists for persistent fingerprint
if [ ! -f /etc/machine-id ]; then
  cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id
fi

# Check for NVIDIA GPUs and grant device permissions for systemd service
detect_nvidia_devices() {
  local devices=""
  for i in /dev/nvidia*; do
    if [ -e "$i" ]; then
      devices="${devices}DeviceAllow=$i rw\n"
    fi
  done
  echo "$devices"
}

# Modify service installation part, add Alpine check before systemd service creation
if is_alpine; then
  if [ ! -f /etc/init.d/bigbrother-agent ]; then
    echo "Creating OpenRC service for Alpine Linux..."
    cat >/etc/init.d/bigbrother-agent <<EOF
#!/sbin/openrc-run

name="bigbrother-agent"
description="Big Brother Agent Service"
command="$BIN_PATH"
command_user="bigbrother"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/bigbrother-agent.log"
error_log="/var/log/bigbrother-agent.err"

start_pre() {
    checkpath -f -m 0644 -o bigbrother:bigbrother "\$output_log" "\$error_log"
}

export PORT="$PORT"
export KEY="$KEY"
export TOKEN="$TOKEN"
export HUB_URL="$HUB_URL"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/bigbrother-agent
    rc-update add bigbrother-agent default
  else
    echo "Alpine OpenRC service file already exists. Updating environment variables..."
    SED_PORT=$(escape_sed_replacement "$PORT")
    SED_KEY=$(escape_sed_replacement "$KEY")
    SED_TOKEN=$(escape_sed_replacement "$TOKEN")
    SED_HUB_URL=$(escape_sed_replacement "$HUB_URL")
    [ "$PORT_PROVIDED" = "true" ] && sed -i "s|^export PORT=.*|export PORT=\"$SED_PORT\"|" /etc/init.d/bigbrother-agent
    [ "$KEY_PROVIDED" = "true" ] && sed -i "s|^export KEY=.*|export KEY=\"$SED_KEY\"|" /etc/init.d/bigbrother-agent
    [ "$TOKEN_PROVIDED" = "true" ] && sed -i "s|^export TOKEN=.*|export TOKEN=\"$SED_TOKEN\"|" /etc/init.d/bigbrother-agent
    [ "$HUB_URL_PROVIDED" = "true" ] && sed -i "s|^export HUB_URL=.*|export HUB_URL=\"$SED_HUB_URL\"|" /etc/init.d/bigbrother-agent
  fi

  # Create log files with proper permissions
  touch /var/log/bigbrother-agent.log /var/log/bigbrother-agent.err
  chown "${AGENT_USER}:${AGENT_USER}" /var/log/bigbrother-agent.log /var/log/bigbrother-agent.err

  # Start the service
  rc-service bigbrother-agent restart

  # Check if service started successfully
  sleep 2
  if ! rc-service bigbrother-agent status | grep -q "started"; then
    echo "Error: The Big Brother Agent service failed to start. Checking logs..."
    tail -n 20 /var/log/bigbrother-agent.err
    exit 1
  fi

  # Auto-update service for Alpine
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    AUTO_UPDATE="y"
  elif [ "$AUTO_UPDATE_FLAG" = "false" ]; then
    AUTO_UPDATE="n"
  else
    printf "\nEnable automatic daily updates for bigbrother-agent? (y/n): "
    read AUTO_UPDATE
  fi
  case "$AUTO_UPDATE" in
  [Yy]*)
    echo "Setting up daily automatic updates for bigbrother-agent..."

    # Create cron job to run bigbrother-agent update command daily at midnight
    if ! crontab -u root -l 2>/dev/null | grep -q "bigbrother-agent.*update"; then
      (crontab -u root -l 2>/dev/null; echo "12 0 * * * $BIN_PATH update >/dev/null 2>&1") | crontab -u root -
    fi

    printf "\nDaily updates have been enabled via cron job.\n"
    ;;
  esac

  # Check service status
  if ! rc-service bigbrother-agent status >/dev/null 2>&1; then
    echo "Error: The Big Brother Agent service is not running."
    rc-service bigbrother-agent status
    exit 1
  fi

elif is_openwrt; then
  if [ ! -f /etc/init.d/bigbrother-agent ]; then
    echo "Creating procd init script service for OpenWRT..."
    cat >/etc/init.d/bigbrother-agent <<EOF
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

start_service() {
    procd_open_instance
    procd_set_param command $BIN_PATH
    procd_set_param user bigbrother
    procd_set_param pidfile /var/run/bigbrother-agent.pid
    procd_set_param env PORT="$PORT" KEY="$KEY" TOKEN="$TOKEN" HUB_URL="$HUB_URL"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

# Extra command to trigger agent update
EXTRA_COMMANDS="update restart"
EXTRA_HELP="        update          Update the Big Brother agent
        restart         Restart the Big Brother agent"

update() {
    $BIN_PATH update
}

EOF
    # Enable the service
    chmod +x /etc/init.d/bigbrother-agent
    /etc/init.d/bigbrother-agent enable
  else
    echo "OpenWRT init script already exists. Updating environment variables..."
    # The env vars live on a single procd_set_param line, so merge any values
    # that weren't explicitly provided in from the existing line before rewriting it.
    CUR_ENV_LINE=$(sed -n '/^[[:space:]]*procd_set_param env PORT=/{p;q;}' /etc/init.d/bigbrother-agent)
    if [ -z "$CUR_ENV_LINE" ] || ! printf '%s\n' "$CUR_ENV_LINE" | grep -q 'PORT="[^"]*" KEY="[^"]*" TOKEN="[^"]*" HUB_URL="[^"]*"'; then
      echo "Error: Could not parse the existing environment configuration in /etc/init.d/bigbrother-agent."
      echo "Expected a procd_set_param env line containing PORT, KEY, TOKEN, and HUB_URL."
      exit 1
    fi
    [ "$PORT_PROVIDED" = "true" ] || PORT=$(printf '%s\n' "$CUR_ENV_LINE" | sed -n 's/.*PORT="\([^"]*\)".*/\1/p')
    [ "$KEY_PROVIDED" = "true" ] || KEY=$(printf '%s\n' "$CUR_ENV_LINE" | sed -n 's/.*KEY="\([^"]*\)".*/\1/p')
    [ "$TOKEN_PROVIDED" = "true" ] || TOKEN=$(printf '%s\n' "$CUR_ENV_LINE" | sed -n 's/.*TOKEN="\([^"]*\)".*/\1/p')
    [ "$HUB_URL_PROVIDED" = "true" ] || HUB_URL=$(printf '%s\n' "$CUR_ENV_LINE" | sed -n 's/.*HUB_URL="\([^"]*\)".*/\1/p')
    SED_PORT=$(escape_sed_replacement "$PORT")
    SED_KEY=$(escape_sed_replacement "$KEY")
    SED_TOKEN=$(escape_sed_replacement "$TOKEN")
    SED_HUB_URL=$(escape_sed_replacement "$HUB_URL")
    sed -i "s|procd_set_param env PORT=.*|procd_set_param env PORT=\"$SED_PORT\" KEY=\"$SED_KEY\" TOKEN=\"$SED_TOKEN\" HUB_URL=\"$SED_HUB_URL\"|" /etc/init.d/bigbrother-agent
  fi

  # Start the service
  /etc/init.d/bigbrother-agent restart

  # Auto-update service for OpenWRT using a crontab job
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    AUTO_UPDATE="y"
    sleep 1 # give time for the service to start
  elif [ "$AUTO_UPDATE_FLAG" = "false" ]; then
    AUTO_UPDATE="n"
    sleep 1 # give time for the service to start
  else
    printf "\nEnable automatic daily updates for bigbrother-agent? (y/n): "
    read AUTO_UPDATE
  fi
  case "$AUTO_UPDATE" in
  [Yy]*)
    echo "Setting up daily automatic updates for bigbrother-agent..."

    if ! crontab -u root -l 2>/dev/null | grep -q "bigbrother-agent.*update"; then
      (crontab -u root -l 2>/dev/null; echo "12 0 * * * /etc/init.d/bigbrother-agent update") | crontab -u root -
    fi

    /etc/init.d/cron restart

    printf "\nDaily updates have been enabled.\n"
    ;;
  esac

  # Check service status
  if ! /etc/init.d/bigbrother-agent running >/dev/null 2>&1; then
    echo "Error: The Big Brother Agent service is not running."
    /etc/init.d/bigbrother-agent status
    exit 1
  fi

elif is_freebsd; then
  echo "Checking for existing FreeBSD service configuration..."
  # Ensure rc.d directory exists on minimal FreeBSD installs
  mkdir -p /usr/local/etc/rc.d
  
  # Create or update environment configuration file
  if [ -f "$AGENT_DIR/env" ]; then
    echo "Environment configuration file already exists. Updating environment variables..."
    SED_PORT=$(escape_sed_replacement "$PORT")
    SED_KEY=$(escape_sed_replacement "$KEY")
    SED_TOKEN=$(escape_sed_replacement "$TOKEN")
    SED_HUB_URL=$(escape_sed_replacement "$HUB_URL")
    [ "$PORT_PROVIDED" = "true" ] && sed -i '' -e "s|^LISTEN=.*|LISTEN=$SED_PORT|" "$AGENT_DIR/env"
    [ "$KEY_PROVIDED" = "true" ] && sed -i '' -e "s|^KEY=.*|KEY=\"$SED_KEY\"|" "$AGENT_DIR/env"
    [ "$TOKEN_PROVIDED" = "true" ] && sed -i '' -e "s|^TOKEN=.*|TOKEN=$SED_TOKEN|" "$AGENT_DIR/env"
    [ "$HUB_URL_PROVIDED" = "true" ] && sed -i '' -e "s|^HUB_URL=.*|HUB_URL=$SED_HUB_URL|" "$AGENT_DIR/env"
  else
    echo "Writing environment configuration file..."
    cat >"$AGENT_DIR/env" <<EOF
LISTEN=$PORT
KEY="$KEY"
TOKEN=$TOKEN
HUB_URL=$HUB_URL
EOF
  fi
  chmod 640 "$AGENT_DIR/env"
  chown "root:${AGENT_USER}" "$AGENT_DIR/env"
  
  # Create the rc service file if it doesn't exist
  if [ ! -f /usr/local/etc/rc.d/bigbrother-agent ]; then
    echo "Creating FreeBSD rc service..."
    generate_freebsd_rc_service > /usr/local/etc/rc.d/bigbrother-agent
    # Set proper permissions for the rc script
    chmod 755 /usr/local/etc/rc.d/bigbrother-agent
  else
    echo "FreeBSD rc service file already exists. Skipping creation."
  fi

  if is_pfsense; then
    echo "Creating pfSense boot script..."
    generate_appliance_boot_script > /usr/local/etc/rc.d/bigbrother-agent-start.sh
    chmod 755 /usr/local/etc/rc.d/bigbrother-agent-start.sh
  elif is_opnsense; then
    # OPNsense does not execute /usr/local/etc/rc.d/*.sh at boot, so the
    # pfSense hook above would never run. Install the same script as a syshook.
    echo "Creating OPNsense boot script..."
    mkdir -p /usr/local/etc/rc.syshook.d/start
    generate_appliance_boot_script > /usr/local/etc/rc.syshook.d/start/99-bigbrother-agent
    chmod 755 /usr/local/etc/rc.syshook.d/start/99-bigbrother-agent
  fi

  # Enable and start the service
  echo "Enabling and starting the agent service..."
  sysrc bigbrother_agent_enable="YES"
  sysrc bigbrother_agent_user="${AGENT_USER}"

  # sysrc writes to /etc/rc.conf, but rc.subr sources /etc/rc.conf.d/bigbrother_agent
  # afterwards, so a stale or third-party file there silently overrides the value
  # we just set. The service then refuses to start, and rc.subr's own error points
  # at /etc/rc.conf, which looks correct. Verify the flag actually took effect.
  # An empty value means this rc.subr does not support "rcvar"; skip the check.
  rcvar_value=$(service bigbrother-agent rcvar 2>/dev/null | sed -n 's/^bigbrother_agent_enable="\(.*\)"$/\1/p')
  if [ -n "$rcvar_value" ]; then
    case "$rcvar_value" in
    [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee] | [Oo][Nn] | 1) ;;
    *)
      echo "Error: bigbrother_agent_enable resolves to \"${rcvar_value}\" even though it was just set to YES in /etc/rc.conf."
      echo "Another rc configuration file is overriding it. The most likely cause is a leftover:"
      echo "  /etc/rc.conf.d/bigbrother_agent"
      echo "Remove or correct that file, then re-run this installer."
      exit 1
      ;;
    esac
  fi

  service bigbrother-agent restart
  
  # Check if service started successfully
  sleep 2
  if ! service bigbrother-agent status | grep -q "is running"; then
    echo "Error: The Big Brother Agent service failed to start. Checking logs..."
    tail -n 20 /var/log/bigbrother_agent.log
    exit 1
  fi

  # Auto-update service for FreeBSD
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    AUTO_UPDATE="y"
  elif [ "$AUTO_UPDATE_FLAG" = "false" ]; then
    AUTO_UPDATE="n"
  else
    printf "\nEnable automatic daily updates for bigbrother-agent? (y/n): "
    read AUTO_UPDATE
  fi
  case "$AUTO_UPDATE" in
  [Yy]*)
    echo "Setting up daily automatic updates for bigbrother-agent..."

    # Create cron job in /etc/cron.d 
    cat >/etc/cron.d/bigbrother-agent <<EOF
# Big Brother Agent daily update job
12 0 * * * root $BIN_PATH update >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/bigbrother-agent
    printf "\nDaily updates have been enabled via /etc/cron.d.\n"
    ;;
  esac

  # Check service status
  if ! service bigbrother-agent status >/dev/null 2>&1; then
    echo "Error: The Big Brother Agent service is not running."
    service bigbrother-agent status
    exit 1
  fi

else
  # Original systemd service installation code
  if [ ! -f /etc/systemd/system/bigbrother-agent.service ]; then
    echo "Creating the systemd service for the agent..."

    # Detect NVIDIA devices and grant device permissions
    NVIDIA_DEVICES=$(detect_nvidia_devices)

    cat >/etc/systemd/system/bigbrother-agent.service <<EOF
[Unit]
Description=Big Brother Agent Service
Wants=network-online.target
After=network-online.target

[Service]
Environment="PORT=$PORT"
Environment="KEY=$KEY"
Environment="TOKEN=$TOKEN"
Environment="HUB_URL=$HUB_URL"
# Environment="EXTRA_FILESYSTEMS=sdb"
ExecStart=$BIN_PATH
User=bigbrother
Restart=on-failure
RestartSec=5
StateDirectory=bigbrother-agent

# Security/sandboxing settings
KeyringMode=private
LockPersonality=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
RemoveIPC=yes
RestrictSUIDSGID=true

$(if [ -n "$NVIDIA_DEVICES" ]; then printf "%b" "# NVIDIA device permissions\n${NVIDIA_DEVICES}"; fi)

[Install]
WantedBy=multi-user.target
EOF
  else
    echo "Systemd service file already exists. Updating environment variables..."
    SED_PORT=$(escape_sed_replacement "$PORT")
    SED_KEY=$(escape_sed_replacement "$KEY")
    SED_TOKEN=$(escape_sed_replacement "$TOKEN")
    SED_HUB_URL=$(escape_sed_replacement "$HUB_URL")
    [ "$PORT_PROVIDED" = "true" ] && sed -i "s|^Environment=\"PORT=.*\"|Environment=\"PORT=$SED_PORT\"|" /etc/systemd/system/bigbrother-agent.service
    [ "$KEY_PROVIDED" = "true" ] && sed -i "s|^Environment=\"KEY=.*\"|Environment=\"KEY=$SED_KEY\"|" /etc/systemd/system/bigbrother-agent.service
    [ "$TOKEN_PROVIDED" = "true" ] && sed -i "s|^Environment=\"TOKEN=.*\"|Environment=\"TOKEN=$SED_TOKEN\"|" /etc/systemd/system/bigbrother-agent.service
    [ "$HUB_URL_PROVIDED" = "true" ] && sed -i "s|^Environment=\"HUB_URL=.*\"|Environment=\"HUB_URL=$SED_HUB_URL\"|" /etc/systemd/system/bigbrother-agent.service
  fi

  # Load and start the service
  printf "\nLoading and starting the agent service...\n"
  systemctl daemon-reload
  systemctl enable bigbrother-agent.service >/dev/null 2>&1
  systemctl restart bigbrother-agent.service



  # Prompt for auto-update setup
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    AUTO_UPDATE="y"
    sleep 1 # give time for the service to start
  elif [ "$AUTO_UPDATE_FLAG" = "false" ]; then
    AUTO_UPDATE="n"
    sleep 1 # give time for the service to start
  else
    printf "\nEnable automatic daily updates for bigbrother-agent? (y/n): "
    read AUTO_UPDATE
  fi
  case "$AUTO_UPDATE" in
  [Yy]*)
    echo "Setting up daily automatic updates for bigbrother-agent..."

    # Create systemd service for the daily update
    cat >/etc/systemd/system/bigbrother-agent-update.service <<EOF
[Unit]
Description=Update bigbrother-agent if needed
Wants=bigbrother-agent.service

[Service]
Type=oneshot
ExecStart=$BIN_PATH update
EOF

    # Create systemd timer for the daily update
    cat >/etc/systemd/system/bigbrother-agent-update.timer <<EOF
[Unit]
Description=Run bigbrother-agent update daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=4h

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now bigbrother-agent-update.timer >/dev/null 2>&1

    printf "\nDaily updates have been enabled.\n"
    ;;
  esac

  # Wait for the service to start or fail
  if [ "$(systemctl is-active bigbrother-agent.service)" != "active" ]; then
    echo "Error: The Big Brother Agent service is not running."
    echo "$(systemctl status bigbrother-agent.service)"
    exit 1
  fi
fi

RUNNING_ADDRESS=$(configured_address)
[ -n "$RUNNING_ADDRESS" ] || RUNNING_ADDRESS=$PORT

printf "\n\033[32mBig Brother Agent has been installed successfully! It is now running on $RUNNING_ADDRESS.\033[0m\n"
