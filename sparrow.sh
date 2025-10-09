#!/bin/sh

wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.0/sparrowwallet_2.3.0-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.0/sparrowserver_2.3.0-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.0/sparrow-2.3.0-manifest.txt
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.0/sparrow-2.3.0-manifest.txt.asc

sudo dpkg -i sparrowwallet_2.3.0-1_amd64.deb
sudo dpkg -i sparrowserver_2.3.0-1_amd64.deb

