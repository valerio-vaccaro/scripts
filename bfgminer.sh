#!/bin/sh

sudo apt update
sudo apt install -y build-essential autoconf libtool libjansson-dev libcurl4-gnutls-dev libncurses5-dev libudev-dev libusb-1.0-0-dev
sudo apt install -y uthash-dev

cd ~
git clone https://github.com/valerio-vaccaro/bfgminer.git
# fix
cd bfgminer 
./autogen.sh
./configure
make

sudo make install
sudo echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf  
sudo ldconfig

# bfgminer -o public-pool.io:21496 -u bc1q79qgpy5sc7n3fkmmc2920ycrhrt7e2fm6t7rw4 -p x --scan-serial erupter:all
