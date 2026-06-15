#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script using sudo or as root." >&2
    exit 1
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: sudo $0 <ssid> [password]" >&2
    echo "If password is omitted, the script prompts for it. Press Enter for an open network." >&2
    exit 1
fi

SSID="$1"
PASSWORD="${2-}"

if ! command -v nmcli >/dev/null 2>&1; then
    echo "Installing NetworkManager..."
    /usr/bin/apt update
    /usr/bin/apt install -y network-manager
fi

if [ "$#" -eq 1 ]; then
    read -r -s -p "WiFi password for '$SSID' (leave empty for open network): " PASSWORD
    echo
fi

echo "Enabling NetworkManager and WiFi radio..."
/usr/bin/systemctl enable --now NetworkManager.service
/usr/bin/nmcli radio wifi on

WIFI_DEVICE=$(/usr/bin/nmcli -t -f DEVICE,TYPE,STATE device status | /usr/bin/awk -F: '$2 == "wifi" { print $1; exit }')
if [ -z "$WIFI_DEVICE" ]; then
    echo "Error: no WiFi device found." >&2
    exit 1
fi

echo "Scanning for WiFi networks..."
/usr/bin/nmcli device wifi rescan ifname "$WIFI_DEVICE" || true

echo "Connecting '$WIFI_DEVICE' to '$SSID'..."
if [ -n "$PASSWORD" ]; then
    /usr/bin/nmcli device wifi connect "$SSID" password "$PASSWORD" ifname "$WIFI_DEVICE"
else
    /usr/bin/nmcli device wifi connect "$SSID" ifname "$WIFI_DEVICE"
fi

/usr/bin/nmcli connection modify "$SSID" connection.autoconnect yes

echo "WiFi configured:"
/usr/bin/nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP4.ADDRESS device show "$WIFI_DEVICE"
