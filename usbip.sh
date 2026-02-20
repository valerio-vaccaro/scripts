#!/bin/sh

sudo apt-get install usbip -y
sudo modprobe usbip_core
sudo modprobe usbip_host
sudo modprobe vhci-hcd

sudo bash -c 'echo "usbip_core" >> /etc/modules' # both client
sudo bash -c 'echo "usbip_host" >> /etc/modules' # sharing a local device
sudo bash -c 'echo "vhci-hcd" >> /etc/modules' # using a remote device

sudo  sh -c "cat > /etc/systemd/system/usbipd.service <<EOL
[Unit]
Description=Usbipd
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/usbipd -D

[Install]
WantedBy=multi-user.target
EOL"

sudo systemctl enable usbipd --now

# --- Connect to a remote USB ---

# On the USB-connected device:
#  - list available device with 
#       usbip list -l 
#    and take note on the busid (e.g X-Y)
#  - bind this device with
#       usbip bind --busid=X-Y
# Re-start the USBIP daemon 

# On the user side:
# - List available remote devices using
#      usbip list -r server
# - Attach the device using
#      usbip attach -r server -b X-Y
# - Detach device using
#      usbip port
#      usbip detach -p Z
#   where Z is the port shown in the previous command
