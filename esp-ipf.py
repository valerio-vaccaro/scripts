#!/bin/sh

sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0

mkdir -p ~/esp
cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
git checkout v5.5.2
git submodule update --init --recursive

cd ~/esp/esp-idf
./install.sh
