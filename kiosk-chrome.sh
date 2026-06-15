#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    echo "Usage: sudo $0 <url> [kiosk-name] [--bitcoin|--navy]" >&2
    exit 1
fi

KIOSK_URL="$1"
KIOSK_NAME=""
BAR_BACKGROUND="#111111"
BAR_COLOR="#ffffff"
BAR_THEME=""

shifted_args=("${@:2}")
for arg in "${shifted_args[@]}"; do
    case "$arg" in
        --bitcoin)
            if [ -n "$BAR_THEME" ]; then
                echo "Error: Theme was specified more than once." >&2
                exit 1
            fi
            BAR_THEME="bitcoin"
            BAR_BACKGROUND="#f7931a"
            BAR_COLOR="#ffffff"
            ;;
        --navy)
            if [ -n "$BAR_THEME" ]; then
                echo "Error: Theme was specified more than once." >&2
                exit 1
            fi
            BAR_THEME="navy"
            BAR_BACKGROUND="#001f3f"
            BAR_COLOR="#ffffff"
            ;;
        -*)
            echo "Error: Unknown option '$arg'." >&2
            echo "Usage: sudo $0 <url> [kiosk-name] [--bitcoin|--navy]" >&2
            exit 1
            ;;
        *)
            if [ -n "$KIOSK_NAME" ]; then
                echo "Error: Kiosk name was specified more than once." >&2
                exit 1
            fi
            KIOSK_NAME="$arg"
            ;;
    esac
done

KIOSK_NAME="${KIOSK_NAME:-$(/usr/bin/hostname)}"
printf -v KIOSK_URL_COMMAND '%q' "$KIOSK_URL"

echo "============================================="
echo " Starting Debian 13 Wayland Kiosk Installer"
echo "============================================="

# 1. Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: Please run this script using sudo or as root."
  exit 1
fi

# 2. Update packages and install dependencies
echo "📦 Updating package lists and installing Sway, Waybar, Chromium & drivers..."
/usr/bin/apt update
/usr/bin/apt install -y --no-install-recommends \
    sway \
    waybar \
    chromium \
    xwayland \
    dbus-daemon \
    network-manager \
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
/usr/bin/cat << EOF > /usr/local/bin/kiosk-start.sh
#!/bin/bash

# Force Chromium and Electron to use native Wayland
export OZONE_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland

TARGET_URL=$KIOSK_URL_COMMAND

# Run Chromium as a borderless app window. Sway keeps it tiled below Waybar.
exec /usr/bin/chromium \
    --app="\$TARGET_URL" \
    --start-maximized \
    --no-first-run \
    --noerrdialogs \
    --password-store=basic \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --enable-features=UseOzonePlatform \
    --ozone-platform=wayland
EOF

# Make the startup script executable
/usr/bin/chmod +x /usr/local/bin/kiosk-start.sh

# 5. Configure Sway and the battery status bar
echo "📝 Configuring Sway and Waybar..."
/usr/bin/install -d -m 0755 /etc/kiosk /etc/sway
/usr/bin/printf '%s\n' "$KIOSK_NAME" > /etc/kiosk/name

/usr/bin/cat << 'EOF' > /etc/kiosk/ip-address.sh
#!/bin/bash

IP=$(/usr/bin/hostname -I 2>/dev/null | /usr/bin/awk '{ print $1 }')
if [ -z "$IP" ]; then
    IP="offline"
fi

/usr/bin/printf 'IP %s\n' "$IP"
EOF
/usr/bin/chmod +x /etc/kiosk/ip-address.sh

/usr/bin/cat << 'EOF' > /etc/kiosk/wifi-status.sh
#!/bin/bash

if ! command -v nmcli >/dev/null 2>&1; then
    /usr/bin/printf 'WiFi unavailable\n'
    exit 0
fi

STATUS=$(/usr/bin/nmcli -t -f WIFI general 2>/dev/null | /usr/bin/head -n 1)
if [ "$STATUS" != "enabled" ]; then
    /usr/bin/printf 'WiFi off\n'
    exit 0
fi

ACTIVE=$(/usr/bin/nmcli -t -f ACTIVE,SSID,SIGNAL device wifi 2>/dev/null | /usr/bin/awk -F: '$1 == "yes" { print $2 ":" $3; exit }')
if [ -z "$ACTIVE" ]; then
    /usr/bin/printf 'WiFi disconnected\n'
    exit 0
fi

SSID=${ACTIVE%:*}
SIGNAL=${ACTIVE##*:}
/usr/bin/printf 'WiFi %s %s%%\n' "$SSID" "$SIGNAL"
EOF
/usr/bin/chmod +x /etc/kiosk/wifi-status.sh

/usr/bin/cat << 'EOF' > /etc/sway/kiosk.conf
xwayland enable

output * bg #000000 solid_color
input * {
    tap enabled
}

default_border none
default_floating_border none
gaps inner 0
gaps outer 0
focus_follows_mouse no

for_window [app_id=".*"] border none
for_window [class=".*"] border none

exec /usr/bin/waybar --config /etc/kiosk/waybar.json --style /etc/kiosk/waybar.css
exec /usr/local/bin/kiosk-start.sh
EOF

/usr/bin/cat << 'EOF' > /etc/kiosk/waybar.json
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "exclusive": true,
    "passthrough": false,
    "modules-left": ["custom/name"],
    "modules-right": ["custom/wifi", "custom/ip", "battery"],
    "custom/name": {
        "exec": "/usr/bin/sed -n '1p' /etc/kiosk/name",
        "interval": 3600,
        "return-type": "text",
        "tooltip": false
    },
    "custom/ip": {
        "exec": "/etc/kiosk/ip-address.sh",
        "interval": 10,
        "return-type": "text",
        "tooltip": false
    },
    "custom/wifi": {
        "exec": "/etc/kiosk/wifi-status.sh",
        "interval": 10,
        "return-type": "text",
        "tooltip": false
    },
    "battery": {
        "interval": 10,
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "BAT {capacity}%",
        "format-charging": "AC {capacity}%",
        "format-plugged": "AC {capacity}%",
        "tooltip": false
    }
}
EOF

/usr/bin/cat << EOF > /etc/kiosk/waybar.css
* {
    border: none;
    border-radius: 0;
    font-family: sans-serif;
    font-size: 16px;
    min-height: 0;
}

window#waybar {
    background: $BAR_BACKGROUND;
    color: $BAR_COLOR;
}

#custom-name,
#custom-wifi,
#custom-ip,
#battery {
    padding: 0 12px;
}

#battery.warning {
    background: #d97706;
}

#battery.critical {
    background: #b91c1c;
}
EOF

# 6. Create the systemd service
echo "⚙️  Creating systemd kiosk service..."
/usr/bin/cat << EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Sway Chromium Kiosk Service
After=systemd-user-sessions.service systemd-logind.service network.target
Conflicts=display-manager.service getty@tty1.service

[Service]
Type=simple
User=kiosk
PAMName=login
WorkingDirectory=/home/kiosk
Environment=XDG_RUNTIME_DIR=/run/user/$KIOSK_UID
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SEAT=seat0
Environment=XDG_VTNR=1
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-force
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpLevel=user

# Launch Sway with a private D-Bus session
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/sway --config /etc/sway/kiosk.conf

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 7. Enable system services
echo "🔄 Reloading systemd and enabling kiosk mode..."
/usr/bin/systemctl enable --now NetworkManager.service
/usr/bin/systemctl set-default multi-user.target
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable kiosk.service

echo "============================================="
echo " 🎉 Setup complete!"
echo " The system will now boot directly into Sway with a battery bar."
echo "============================================="

# 8. Prompt user for immediate reboot
read -p "Would you like to reboot now to launch the kiosk? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🔄 Rebooting system..."
    /usr/sbin/reboot
else
    echo "⚠️  Please remember to manually reboot later using 'sudo reboot'."
fi
