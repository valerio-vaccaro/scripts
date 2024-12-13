#!/bin/sh

sudo apt install r-base r-base-dev
sudo apt install libssl-dev libclang-d

wget https://download1.rstudio.org/electron/jammy/amd64/rstudio-2024.09.1-394-amd64.deb
sudo dpkg -i rstudio-2024.09.1-394-amd64.deb