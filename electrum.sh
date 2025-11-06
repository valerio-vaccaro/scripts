#!/bin/sh

wget https://download.electrum.org/4.5.8/electrum-4.5.8-x86_64.AppImage
wget https://download.electrum.org/4.5.8/electrum-4.5.8-x86_64.AppImage.asc

gpg --verify electrum-4.5.8-x86_64.AppImage.asc
