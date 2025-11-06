#!/bin/sh

sudo apt install mariadb-server mariadb-client -y

git clone https://github.com/mempool/mempool
cd mempool
latestrelease=$(curl -s https://api.github.com/repos/mempool/mempool/releases/latest|grep tag_name|head -1|cut -d '"' -f4)
git checkout $latestrelease

sudo mysql -e "drop database mempool;"
sudo mysql -e "create database mempool;"
sudo mysql -e "grant all privileges on mempool.* to 'mempool'@'%' identified by 'mempool';"
sudo mysql -e "flush privileges;"

# use node 20
sudo npm i -g npm
sudo npm i -g node@20

cd backend
npm install --no-install-links # npm@9.4.2 and later can omit the --no-install-links
npm run build


cp mempool-config.sample.json mempool-config.json # modify if needed
# fix for debiam myslq socket

# npm run start

# or use pm2 to start
pm2 start "npm run start"
pm2 save


cd ..

cd frontend
npm install
# npm run serve:local-prod

# or use pm2 to start
pm2 start "npm run serve:local-prod"
pm2 save
