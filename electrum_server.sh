#!/bin/sh

sudo apt update
sudo apt install clang cmake build-essential -y

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"    

VERSION="0.10.9"
git clone --branch v$VERSION https://github.com/romanz/electrs.git
cd electrs

curl https://romanzey.de/pgp.txt | gpg --import
git verify-tag v$VERSION

cargo build --locked --release

sudo install -m 0755 -o root -g root -t /usr/local/bin ./target/release/electrs

cd ..

cat > ~/electrs_config.toml <<EOL
# bitcoin core configuration
auth = "username:password"
daemon_rpc_addr = "127.0.0.1:8332"
daemon_p2p_addr = "127.0.0.1:8333"

# electrs configuration
db_dir = "/home/bitcoin/.electrum"
network = "bitcoin"
electrum_rpc_addr = "127.0.0.1:50001"
log_filters = "INFO"
EOL

sudo  sh -c "cat > /etc/systemd/system/electrs.service <<EOL
[Unit]
Description=Electrs daemon
After=bitcoind.target

[Service]
User=bitcoin
Group=bitcoin
Type=forking
ExecStart=/usr/local/bin/electrs --conf /home/bitcoin/electrs_config.toml
KillMode=process
Restart=always
TimeoutSec=120
RestartSec=30

[Install]
WantedBy=multi-user.target
EOL"

sudo systemctl enable electrs
sudo systemctl start electrs

systemctl status electrs
