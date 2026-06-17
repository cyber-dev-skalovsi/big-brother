#!/bin/sh

is_freebsd() {
  [ "$(uname -s)" = "FreeBSD" ]
}

# Function to ensure the proxy URL ends with a /
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

# Generate FreeBSD rc service content
generate_freebsd_rc_service() {
  cat <<'EOF'
#!/bin/sh

# PROVIDE: bigbrother_hub
# REQUIRE: DAEMON NETWORKING
# BEFORE: LOGIN
# KEYWORD: shutdown

# Add the following lines to /etc/rc.conf to configure Big Brother Hub:
#
# bigbrother_hub_enable (bool):   Set to YES to enable Big Brother Hub
#                             Default: YES
# bigbrother_hub_port (str):      Port to listen on
#                             Default: 8090
# bigbrother_hub_user (str):      Big Brother Hub daemon user
#                             Default: bigbrother
# bigbrother_hub_bin (str):       Path to the bigbrother binary
#                             Default: /usr/local/sbin/bigbrother
# bigbrother_hub_data (str):      Path to the bigbrother data directory
#                             Default: /usr/local/etc/bigbrother/bigbrother_data
# bigbrother_hub_flags (str):     Extra flags passed to bigbrother command invocation
#                             Default:

. /etc/rc.subr

name="bigbrother_hub"
rcvar=bigbrother_hub_enable

load_rc_config $name
: ${bigbrother_hub_enable:="YES"}
: ${bigbrother_hub_port:="8090"}
: ${bigbrother_hub_user:="bigbrother"}
: ${bigbrother_hub_flags:=""}
: ${bigbrother_hub_bin:="/usr/local/sbin/bigbrother"}
: ${bigbrother_hub_data:="/usr/local/etc/bigbrother/bigbrother_data"}

logfile="/var/log/${name}.log"
pidfile="/var/run/${name}.pid"

procname="/usr/sbin/daemon"
start_precmd="${name}_prestart"
start_cmd="${name}_start"
stop_cmd="${name}_stop"

extra_commands="upgrade"
upgrade_cmd="bigbrother_hub_upgrade"

bigbrother_hub_prestart()
{
    if [ ! -d "${bigbrother_hub_data}" ]; then
        echo "Creating data directory ${bigbrother_hub_data}"
        mkdir -p "${bigbrother_hub_data}"
        chown "${bigbrother_hub_user}:${bigbrother_hub_user}" "${bigbrother_hub_data}"
    fi
}

bigbrother_hub_start()
{
    echo "Starting ${name}"
    cd "$(dirname "${bigbrother_hub_data}")" || exit 1
    /usr/sbin/daemon -f \
            -P "${pidfile}" \
            -o "${logfile}" \
            -u "${bigbrother_hub_user}" \
            "${bigbrother_hub_bin}" serve --http "0.0.0.0:${bigbrother_hub_port}" ${bigbrother_hub_flags}
}

bigbrother_hub_stop()
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

bigbrother_hub_upgrade()
{
    echo "Upgrading ${name}"
    if command -v sudo >/dev/null; then
        sudo -u "${bigbrother_hub_user}" -- "${bigbrother_hub_bin}" update
    else
        su -m "${bigbrother_hub_user}" -c "${bigbrother_hub_bin} update"
    fi
}

run_rc_command "$1"
EOF
}

# Detect system architecture
detect_architecture() {
  arch=$(uname -m)
  case "$arch" in
    x86_64)
      arch="amd64"
      ;;
    armv7l)
      arch="arm"
      ;;
    aarch64)
      arch="arm64"
      ;;
  esac
  echo "$arch"
}

# Build sudo args by properly quoting everything
build_sudo_args() {
  QUOTED_ARGS=""
  while [ $# -gt 0 ]; do
    if [ -n "$QUOTED_ARGS" ]; then
      QUOTED_ARGS="$QUOTED_ARGS "
    fi
    QUOTED_ARGS="$QUOTED_ARGS'$(echo "$1" | sed "s/'/'\\\\''/g")'"
    shift
  done
  echo "$QUOTED_ARGS"
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

# Define default values
PORT=8090
GITHUB_URL="https://github.com"
AUTO_UPDATE_FLAG="false"
UNINSTALL=false

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -u)
      UNINSTALL=true
      shift
      ;;
    -h|--help)
      printf "Big Brother Hub installation script\n\n"
      printf "Usage: ./install-hub.sh [options]\n\n"
      printf "Options: \n"
      printf "  -u           : Uninstall the Big Brother Hub\n"
      printf "  -p <port>    : Specify a port number (default: 8090)\n"
      printf "  -c, --mirror [URL] : Use a GitHub mirror/proxy URL (default: https://github.com/cyber-dev-skalovsi/big-brother)\n"
      printf "  --auto-update : Enable automatic daily updates (disabled by default)\n"
      printf "  -h, --help   : Display this help message\n"
      exit 0
      ;;
    -p)
      shift
      PORT="$1"
      shift
      ;;
    -c | --mirror)
      shift
      if [ -n "$1" ] && ! echo "$1" | grep -q '^-'; then
        GITHUB_URL="$(ensure_trailing_slash "$1")https://github.com"
        shift
      else
        GITHUB_URL="https://github.com/cyber-dev-skalovsi/big-brother"
      fi
      ;;
    --auto-update)
      AUTO_UPDATE_FLAG="true"
      shift
      ;;
    *)
      echo "Invalid option: $1" >&2
      exit 1
      ;;
  esac
done

# Set paths based on operating system
if is_freebsd; then
  HUB_DIR="/usr/local/etc/bigbrother"
  BIN_PATH="/usr/local/sbin/bigbrother"
else
  HUB_DIR="/opt/bigbrother"
  BIN_PATH="/opt/bigbrother/bigbrother"
fi

# Uninstall process
if [ "$UNINSTALL" = true ]; then
  if is_freebsd; then
    echo "Stopping and disabling the Big Brother Hub service..."
    service bigbrother-hub stop 2>/dev/null
    sysrc bigbrother_hub_enable="NO" 2>/dev/null

    echo "Removing the FreeBSD service files..."
    rm -f /usr/local/etc/rc.d/bigbrother-hub

    echo "Removing the daily update cron job..."
    rm -f /etc/cron.d/bigbrother-hub

    echo "Removing log files..."
    rm -f /var/log/bigbrother_hub.log

    echo "Removing the Big Brother Hub binary and data..."
    rm -f "$BIN_PATH"
    rm -rf "$HUB_DIR"

    echo "Removing the dedicated user..."
    pw user del bigbrother 2>/dev/null

    echo "The Big Brother Hub has been uninstalled successfully!"
    exit 0
  else
    # Stop and disable the Big Brother Hub service
    echo "Stopping and disabling the Big Brother Hub service..."
    systemctl stop bigbrother-hub.service
    systemctl disable bigbrother-hub.service

    # Remove the systemd service file
    echo "Removing the systemd service file..."
    rm -f /etc/systemd/system/bigbrother-hub.service

    # Remove the update timer and service if they exist
    echo "Removing the daily update service and timer..."
    systemctl stop bigbrother-hub-update.timer 2>/dev/null
    systemctl disable bigbrother-hub-update.timer 2>/dev/null
    rm -f /etc/systemd/system/bigbrother-hub-update.service
    rm -f /etc/systemd/system/bigbrother-hub-update.timer

    # Reload the systemd daemon
    echo "Reloading the systemd daemon..."
    systemctl daemon-reload

    # Remove the Big Brother Hub binary and data
    echo "Removing the Big Brother Hub binary and data..."
    rm -rf "$HUB_DIR"

    # Remove the dedicated user
    echo "Removing the dedicated user..."
    userdel bigbrother 2>/dev/null

    echo "The Big Brother Hub has been uninstalled successfully!"
    exit 0
  fi
fi

# Function to check if a package is installed
package_installed() {
  command -v "$1" >/dev/null 2>&1
}

# Check for package manager and install necessary packages if not installed
if package_installed pkg && is_freebsd; then
  if ! package_installed tar || ! package_installed curl; then
    pkg update
    pkg install -y gtar curl
  fi
elif package_installed apt-get; then
  if ! package_installed tar || ! package_installed curl; then
    apt-get update
    apt-get install -y tar curl
  fi
elif package_installed yum; then
  if ! package_installed tar || ! package_installed curl; then
    yum install -y tar curl
  fi
elif package_installed pacman; then
  if ! package_installed tar || ! package_installed curl; then
    pacman -Sy --noconfirm tar curl
  fi
else
  echo "Warning: Please ensure 'tar' and 'curl' are installed."
fi

# Create a dedicated user for the service if it doesn't exist
echo "Creating a dedicated user for the Big Brother Hub service..."
if is_freebsd; then
  if ! id -u bigbrother >/dev/null 2>&1; then
    pw user add bigbrother -d /nonexistent -s /usr/sbin/nologin -c "bigbrother user"
  fi
else
  if ! id -u bigbrother >/dev/null 2>&1; then
    useradd -M -s /bin/false bigbrother
  fi
fi

# Create the directory for the Big Brother Hub
echo "Creating the directory for the Big Brother Hub..."
mkdir -p "$HUB_DIR/bigbrother_data"
chown -R bigbrother:bigbrother "$HUB_DIR"
chmod 755 "$HUB_DIR"

# Download and install the Big Brother Hub
echo "Downloading and installing the Big Brother Hub..."

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(detect_architecture)
FILE_NAME="bigbrother_${OS}_${ARCH}.tar.gz"

TEMP_DIR=$(mktemp -d)
ARCHIVE_PATH="$TEMP_DIR/$FILE_NAME"
DOWNLOAD_URL="$GITHUB_URL/cyber-dev-skalovsi/big-brother/releases/latest/download/$FILE_NAME"

if ! curl -fL# --retry 3 --retry-delay 2 --connect-timeout 10 "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"; then
  echo "Failed to download the Big Brother Hub from:"
  echo "$DOWNLOAD_URL"
  echo "Try again with --mirror (or --mirror <url>) if GitHub is not reachable."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
  echo "Downloaded archive is invalid or incomplete (possible network/proxy issue)."
  echo "Try again with --mirror (or --mirror <url>) if the download path is unstable."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if ! tar -xzf "$ARCHIVE_PATH" -C "$TEMP_DIR" bigbrother; then
  echo "Failed to extract bigbrother from archive."
  rm -rf "$TEMP_DIR"
  exit 1
fi

if [ ! -s "$TEMP_DIR/bigbrother" ]; then
  echo "Downloaded binary is missing or empty."
  rm -rf "$TEMP_DIR"
  exit 1
fi

chmod +x "$TEMP_DIR/bigbrother"
mv "$TEMP_DIR/bigbrother" "$BIN_PATH"
chown bigbrother:bigbrother "$BIN_PATH"
rm -rf "$TEMP_DIR"

if is_freebsd; then
  echo "Creating FreeBSD rc service..."

  # Create the rc service file
  generate_freebsd_rc_service > /usr/local/etc/rc.d/bigbrother-hub

  # Set proper permissions for the rc script
  chmod 755 /usr/local/etc/rc.d/bigbrother-hub

  # Configure the port
  sysrc bigbrother_hub_port="$PORT"

  # Enable and start the service
  echo "Enabling and starting the Big Brother Hub service..."
  sysrc bigbrother_hub_enable="YES"
  service bigbrother-hub restart

  # Check if service started successfully
  sleep 2
  if ! service bigbrother-hub status | grep -q "is running"; then
    echo "Error: The Big Brother Hub service failed to start. Checking logs..."
    tail -n 20 /var/log/bigbrother_hub.log
    exit 1
  fi

  # Auto-update service for FreeBSD
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    echo "Setting up daily automatic updates for bigbrother-hub..."

    # Create cron job in /etc/cron.d
    cat >/etc/cron.d/bigbrother-hub <<EOF
# Big Brother Hub daily update job
12 8 * * * root $BIN_PATH update >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/bigbrother-hub
    printf "\nDaily updates have been enabled via /etc/cron.d.\n"
  fi

  # Check service status
  if ! service bigbrother-hub status >/dev/null 2>&1; then
    echo "Error: The Big Brother Hub service is not running."
    service bigbrother-hub status
    exit 1
  fi

else
  # Original systemd service installation code
  printf "Creating the systemd service for the Big Brother Hub...\n"
  cat >/etc/systemd/system/bigbrother-hub.service <<EOF
[Unit]
Description=Big Brother Hub Service
After=network.target

[Service]
ExecStart=$BIN_PATH serve --http "0.0.0.0:$PORT"
WorkingDirectory=$HUB_DIR
User=bigbrother
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # Load and start the service
  printf "Loading and starting the Big Brother Hub service...\n"
  systemctl daemon-reload
  systemctl enable --quiet bigbrother-hub.service
  systemctl start --quiet bigbrother-hub.service

  # Wait for the service to start or fail
  sleep 2

  # Check if the service is running
  if [ "$(systemctl is-active bigbrother-hub.service)" != "active" ]; then
    echo "Error: The Big Brother Hub service is not running."
    echo "$(systemctl status bigbrother-hub.service)"
    exit 1
  fi

  # Enable auto-update if flag is set to true
  if [ "$AUTO_UPDATE_FLAG" = "true" ]; then
    echo "Setting up daily automatic updates for bigbrother-hub..."

    # Create systemd service for the daily update
    cat >/etc/systemd/system/bigbrother-hub-update.service <<EOF
[Unit]
Description=Update bigbrother-hub if needed
Wants=bigbrother-hub.service

[Service]
Type=oneshot
ExecStart=$BIN_PATH update
EOF

    # Create systemd timer for the daily update
    cat >/etc/systemd/system/bigbrother-hub-update.timer <<EOF
[Unit]
Description=Run bigbrother-hub update daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=4h

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now bigbrother-hub-update.timer

    printf "\nDaily updates have been enabled.\n"
  fi
fi

printf "\n\033[32mBig Brother Hub has been installed successfully! It is now accessible on port $PORT.\033[0m\n"
