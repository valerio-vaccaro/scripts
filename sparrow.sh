#!/bin/sh

wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.1/sparrowwallet_2.3.1-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.1/sparrowserver_2.3.1-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.1/sparrow-2.3.1-manifest.txt
wget https://github.com/sparrowwallet/sparrow/releases/download/2.3.1/sparrow-2.3.1-manifest.txt.asc

sudo dpkg -i sparrowwallet_2.3.1-1_amd64.deb
sudo dpkg -i sparrowserver_2.3.1-1_amd64.deb

rm sparrowwallet_2.3.1-1_amd64.deb
rm sparrowserver_2.3.1-1_amd64.deb

rm sparrow-2.3.1-manifest.txt
rm sparrow-2.3.1-manifest.txt.asc