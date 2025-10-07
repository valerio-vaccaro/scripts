#!/bin/sh

wget https://github.com/sparrowwallet/sparrow/releases/download/2.2.3/sparrowwallet_2.2.3-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.2.3/sparrow-2.2.3-manifest.txt
wget https://github.com/sparrowwallet/sparrow/releases/download/2.2.3/sparrow-2.2.3-manifest.txt.asc

sudo dpkg -i sparrowwallet_2.2.3-1_amd64.deb
