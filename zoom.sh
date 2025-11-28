#!/bin/sh

wget https://zoom.us/client/6.2.11.5069/zoom_amd64.deb
sudo dpkg -i zoom_amd64.deb
rm zoom_amd64.deb
