#!/bin/sh

wget https://bitcoincore.org/bin/bitcoin-core-29.0/bitcoin-29.0-x86_64-linux-gnu.tar.gz
wget https://bitcoincore.org/bin/bitcoin-core-29.0/SHA256SUMS
wget https://bitcoincore.org/bin/bitcoin-core-29.0/SHA256SUMS.asc

sha256sum --ignore-missing --check SHA256SUMS

git clone https://github.com/bitcoin-core/guix.sigs
gpg --import guix.sigs/builder-keys/*

gpg --verify SHA256SUMS.asc

tar xzvf bitcoin-29.0-x86_64-linux-gnu.tar.gz 
sudo install -m 0755 -o root -g root -t /usr/local/bin bitcoin-29.0/bin/*

mkdir .bitcoin

cat > .bitcoin/bitcoin.conf <<EOL
daemon=1  
blocksonly=1  
maxconnections=20  
maxuploadtarget=500  
txindex=1  
blockfilterindex=1

rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
rpcuser=username
rpcpassword=password
EOL

sudo  sh -c "cat > /etc/systemd/system/bitcoind.service <<EOL
[Unit]
Description=Bitcoin daemon
After=network.target

[Service]
User=bitcoin
Group=bitcoin
Type=forking
PIDFile=/home/bitcoin/.bitcoin/bitcoind.pid
ExecStart=/usr/local/bin/bitcoind -pid=/home/bitcoin/.bitcoin/bitcoind.pid
KillMode=process
Restart=always
TimeoutSec=120
RestartSec=30

[Install]
WantedBy=multi-user.target
EOL"

sudo systemctl enable bitcoind
sudo systemctl start bitcoind

systemctl status bitcoind
