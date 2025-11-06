#!/bin/sh

sudo apt install r-base r-base-dev
sudo apt install libssl-dev libclang-dev

wget https://download1.rstudio.org/electron/jammy/amd64/rstudio-2025.09.2-418-amd64.deb
sudo dpkg -i rstudio-2025.09.2-418-amd64.deb
