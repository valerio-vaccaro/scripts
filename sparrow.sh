#!/bin/sh

wget https://github.com/sparrowwallet/sparrow/releases/download/2.0.0/sparrow_2.0.0-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.0.0/sparrow-2.0.0-manifest.txt
wget https://github.com/sparrowwallet/sparrow/releases/download/2.0.0/sparrow-2.0.0-manifest.txt.asc

sudo dpkg -i sparrow_2.0.0-1_amd64.deb
