#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    echo "Usage: sudo $0 <url>" >&2
    exit 1
fi

KIOSK_URL="$1"

echo "============================================="
echo " Starting Debian 13 Wayland Kiosk Installer"
echo "============================================="

# 1. Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: Please run this script using sudo or as root."
  exit 1
fi

# 2. Update packages and install dependencies
echo "📦 Updating package lists and installing Cage, Chromium & drivers..."
/usr/bin/apt update
/usr/bin/apt install -y --no-install-recommends \
    cage \
    chromium \
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

# Dynamically pull the Kiosk UID to configure XDG_RUNTIME_DIR correctly
KIOSK_UID=$(/usr/bin/id -u kiosk)

# Ensure user belongs to the correct hardware access groups (including render)
echo "🔑 Assigning hardware and rendering permissions to 'kiosk' user..."
/usr/sbin/usermod -aG video,input,render kiosk

# 4. Create the Kiosk Startup Script
echo "📝 Writing kiosk startup script..."
/usr/bin/cat << 'EOF' > /usr/local/bin/kiosk-start.sh
#!/bin/bash

# Force Chromium and Electron to use native Wayland
export OZONE_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland

# Replace the URL placeholder with the actual variable during installation
TARGET_URL="KIOSK_URL_PLACEHOLDER"

# Execute Chromium in restricted Kiosk mode
exec /usr/bin/chromium \
    --kiosk \
    --no-first-run \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --enable-features=UseOzonePlatform \
    --ozone-platform=wayland \
    "$TARGET_URL"
EOF

# Inject the configured URL into the script
/usr/bin/sed -i "s|KIOSK_URL_PLACEHOLDER|$KIOSK_URL|g" /usr/local/bin/kiosk-start.sh

# Make the startup script executable
/usr/bin/chmod +x /usr/local/bin/kiosk-start.sh

# 5. Create the Systemd Service File
echo "⚙️  Creating systemd kiosk service..."
/usr/bin/cat << EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Wayland Kiosk Service
After=systemd-user-sessions.service network.target sound.target systemd-udev-settle.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=kiosk
PAMName=login
WorkingDirectory=/home/kiosk
Environment=XDG_RUNTIME_DIR=/run/user/$KIOSK_UID
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpLevel=user

# Launch Cage compositor targeting our startup script
ExecStart=/usr/bin/cage -s -- /usr/local/bin/kiosk-start.sh

Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# 6. Enable system services
echo "🔄 Reloading systemd and enabling kiosk mode..."
/usr/bin/systemctl set-default graphical.target
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable kiosk.service

echo "============================================="
echo " 🎉 Setup complete!"
echo " The system will now boot directly into Cage (Wayland)."
echo "============================================="

# 7. Prompt user for immediate reboot
read -p "Would you like to reboot now to launch the kiosk? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🔄 Rebooting system..."
    /usr/sbin/reboot
else
    echo "⚠️  Please remember to manually reboot later using 'sudo reboot'."
fi
