#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script using sudo or as root." >&2
    exit 1
fi

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: sudo $0 <kiosk-name>" >&2
    exit 1
fi

/usr/bin/install -d -m 0755 /etc/kiosk
/usr/bin/printf '%s\n' "$1" > /etc/kiosk/name

echo "Kiosk name set to: $1"
echo "Restart kiosk.service or reboot to refresh the topbar immediately."
