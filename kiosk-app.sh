#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    echo "Error: No application specified." >&2
    echo "Usage: sudo $0 <application-or-path>" >&2
    exit 1
fi

if [[ "$1" == */* ]]; then
    APP_PATH=$(/usr/bin/readlink -f -- "$1" || true)
else
    APP_PATH=$(type -P -- "$1" || true)
fi

if [ -z "$APP_PATH" ] || [ ! -f "$APP_PATH" ] || [ ! -x "$APP_PATH" ]; then
    echo "Error: Application '$1' does not exist or is not executable." >&2
    exit 1
fi

printf -v APP_COMMAND '%q' "$APP_PATH"

echo "============================================="
echo " Starting Debian 13 Application Kiosk Installer"
echo "============================================="

# 1. Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: Please run this script using sudo or as root."
  exit 1
fi

# 2. Update packages and install core Wayland infrastructure
echo "📦 Installing Cage compositor and graphics dependencies..."
/usr/bin/apt update
/usr/bin/apt install -y --no-install-recommends \
    cage \
    xwayland \
    libpam-systemd \
    firmware-linux \
    mesa-va-drivers \
    mesa-vdpau-drivers

# 3. Create the dedicated kiosk user if it doesn't exist
if /usr/bin/id "kiosk" &>/dev/null; then
    echo "👤 User 'kiosk' already exists. Skipping creation."
else
    echo "👤 Creating 'kiosk' user account..."
    /usr/sbin/useradd -m -s /bin/bash kiosk
fi

# Dynamically pull the Kiosk UID to configure runtime paths correctly
KIOSK_UID=$(/usr/bin/id -u kiosk)

# Elevate unprivileged system groups so kiosk user can interact with raw hardware, displays and keys
echo "🔑 Mapping permissions to 'kiosk' user..."
/usr/sbin/usermod -aG video,input,render,tty kiosk

# 4. Create the Kiosk Startup Script
echo "📝 Creating application runner..."
/usr/bin/cat << EOF > /usr/local/bin/kiosk-start.sh
#!/bin/bash

# Configure graphical applications for the kiosk session
export GDK_BACKEND=x11
export XDG_SESSION_TYPE=wayland

# Execute the configured application
exec $APP_COMMAND
EOF

# Make the wrapper execution script executable
/usr/bin/chmod +x /usr/local/bin/kiosk-start.sh

# 5. Create the Systemd Service File with direct frame buffer rendering defaults
echo "⚙️  Building direct-boot systemd kiosk target..."
/usr/bin/cat << EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Wayland Application Kiosk Service
After=systemd-user-sessions.service network.target sound.target systemd-udev-settle.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=kiosk
PAMName=login
WorkingDirectory=/home/kiosk
Environment=XDG_RUNTIME_DIR=/run/user/$KIOSK_UID
Environment=WLR_BACKENDS=drm
Environment=WLR_RENDERER=pixman
Environment=XDG_SESSION_TYPE=wayland
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpLevel=user

# Launch Cage targeting the application startup script
ExecStart=/usr/bin/cage -s -- /usr/local/bin/kiosk-start.sh

Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# 6. Enable system target structures
echo "🔄 Reloading system controllers..."
/usr/bin/systemctl set-default graphical.target
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable kiosk.service

echo "============================================="
echo " 🎉 Application kiosk setup complete!"
echo " The system will now boot directly into $APP_PATH."
echo "============================================="

# 7. Prompt user for immediate reboot
read -p "Would you like to reboot now to launch the kiosk? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🔄 Rebooting system..."
    /usr/sbin/reboot
else
    echo "⚠️  Please remember to manually reboot later using 'sudo reboot'."
fi
