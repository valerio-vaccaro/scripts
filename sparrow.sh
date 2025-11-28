#!/bin/sh

VERSION=2.3.1

wget https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrowwallet_$VERSION-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrowserver_$VERSION-1_amd64.deb
wget https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrow-$VERSION-manifest.txt
wget https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrow-$VERSION-manifest.txt.asc

sudo dpkg -i sparrowwallet_$VERSION-1_amd64.deb
sudo dpkg -i sparrowserver_$VERSION-1_amd64.deb

rm sparrowwallet_$VERSION-1_amd64.deb
rm sparrowserver_$VERSION-1_amd64.deb

rm sparrow-$VERSION-manifest.txt
rm sparrow-$VERSION-manifest.txt.asc
