#!/bin/sh

wget https://api2.cursor.sh/updates/download/golden/linux-x64-deb/cursor/2.0
sudo dpkg -i 2.0
rm 2.0
