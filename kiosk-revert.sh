#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script using sudo or as root." >&2
    exit 1
fi

echo "============================================="
echo " Reverting Debian kiosk configuration"
echo "============================================="

echo "Stopping and disabling the kiosk service..."
/usr/bin/systemctl disable --now kiosk.service 2>/dev/null || true

echo "Removing kiosk service and startup files..."
/usr/bin/rm -f \
    /etc/systemd/system/kiosk.service \
    /usr/local/bin/kiosk-start.sh \
    /etc/sway/kiosk.conf \
    /etc/kiosk/name \
    /etc/kiosk/installed-at \
    /etc/kiosk/ip-address.sh \
    /etc/kiosk/waybar.json \
    /etc/kiosk/waybar.css
/usr/bin/rmdir /etc/kiosk 2>/dev/null || true

echo "Restoring the normal graphical boot target..."
/usr/bin/systemctl set-default graphical.target
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl reset-failed kiosk.service 2>/dev/null || true
/usr/bin/systemctl unmask getty@tty1.service

echo "============================================="
echo " Kiosk configuration removed."
echo " Installed packages and the 'kiosk' user were preserved."
echo "============================================="

read -r -p "Would you like to reboot now? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    /usr/sbin/reboot
else
    echo "Reboot later with: sudo reboot"
fi
