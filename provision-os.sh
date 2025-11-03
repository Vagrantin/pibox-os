#!/bin/bash
set -e
set -x

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

hostnamectl set-hostname pibox
sed -i 's/raspberrypi/pibox/' /etc/hosts

# Unlimited bash history https://stackoverflow.com/a/19533853
sed -i 's/HISTSIZE=1000//' /home/pi/.bashrc
sed -i 's/HISTFILESIZE=2000//' /home/pi/.bashrc
cat <<EOF >> /home/pi/.bashrc
export HISTFILESIZE=
export HISTSIZE=
export HISTTIMEFORMAT="[%F %T] "
export HISTFILE=~/.bash_eternal_history
PROMPT_COMMAND="history -a; \$PROMPT_COMMAND"
EOF

cp /home/pi/.bashrc /root/.bashrc

apt-get update -yqq
apt-get full-upgrade -yqq
apt-get autoremove -yqq
apt-get autoclean -yqq
apt-get install -yqq vim lvm2 openssh-server raspberrypi-kernel-headers samba samba-common-bin tmate sysstat smartmontools whois git iptables
apt-get remove -yqq nftables
update-alternatives --set iptables /usr/sbin/iptables-legacy

# Kernel settings
grep -qxF 'cgroup_enable=memory cgroup_memory=1' /boot/cmdline.txt || sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' /boot/cmdline.txt
# Show text output during startup / shutdown (useful if reboot hangs)
sed -i 's/quiet splash plymouth.ignore-serial-consoles//' /boot/cmdline.txt
# Disable ASPM (low power PCIe mode) for our ASM1061 chip.
# It does not play nicely with the CM4 during heavy workloads
# and will flood system logs with AER warnings
sed -i 's/rootwait/pcie_aspm=off rootwait/' /boot/firmware/cmdline.txt

# Fully disable IPV6 - kubernetes does not play non-trivially with it
cat <<EOF > /etc/modprobe.d/ipv6.conf
alias net-pf-10 off
alias ipv6 off
options ipv6 disable_ipv6=1
EOF

if [ -f /var/run/reboot-required ]; then
  echo 'PLEASE REBOOT TO ACTIVATE NEW KERNEL'
  exit 0
fi

# Set up samba share
mkdir -p /var/log/samba/
mkdir -p /var/lib/pibox/storage
echo -e "pibox\npibox" | smbpasswd pi -a -s
cat <<EOF > /etc/samba/smb.conf
[volumes]
force user=root
force group=root
path = /var/lib/pibox/storage
writeable=Yes
create mask=0777
directory mask=0777
public=no
EOF

mkdir -p /opt/pibox
curl -sLo /opt/pibox/update-framebuffer.sh https://raw.githubusercontent.com/pibox/pibox-os/main/update-framebuffer.sh
chmod +x /opt/pibox/update-framebuffer.sh
/opt/pibox/update-framebuffer.sh

# Reduce logging and store in memory to reduce EMMC wear
sed -i 's/.MaxLevelStore.*/MaxLevelStore=info/' /etc/systemd/journald.conf
sed -i 's/.MaxLevelSyslog.*/MaxLevelSyslog=info/' /etc/systemd/journald.conf
sed -i "s/#Storage.*/Storage=volatile/" /etc/systemd/journald.conf
sed -i "s/#SystemMaxUse.*/SystemMaxUse=10M/" /etc/systemd/journald.conf
sed -i "s/#SystemMaxFileSize.*/SystemMaxFileSize=10M/" /etc/systemd/journald.conf
systemctl restart systemd-journald.service

# Add tmpfs at /tmp to reduce EMMC wear
echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=0755,size=64M 0 0" >> /etc/fstab

# Clone PiBox OS repo for building fan/display drivers
rm -rf pibox-os
git clone https://github.com/pibox/pibox-os.git
pushd pibox-os
echo "PIBOX_RELEASE=$(git rev-parse --short HEAD)" > /etc/pibox-release
popd

# Enable Fan Support
pushd pibox-os/pwm-fan
tar zxvf bcm2835-1.68.tar.gz
pushd bcm2835-1.68
./configure && make && make install
popd
make && make install
popd

# Enable Display Driver
pushd pibox-os/st7789_module
make
make install
popd
dtc --warning no-unit_address_vs_reg -I dts -O dtb -o /boot/overlays/drm-minipitft13.dtbo pibox-os/overlays/minipitft13-overlay.dts
cat <<EOF >> /boot/config.txt
dtoverlay=spi0-1cs
dtoverlay=dwc2,dr_mode=host
hdmi_force_hotplug=1
dtoverlay=drm-minipitft13,rotate=0,fps=60
EOF

# Remove PiBox repo
rm -rf pibox-os

# Sysctl & limits
echo "vm.swappiness=1" >> /etc/sysctl.conf
echo "fs.file-max=1024000" >> /etc/sysctl.conf
sysctl -p
echo "* soft nofile 8192" >> /etc/security/limits.conf

# Swap
swapoff -a
systemctl mask  "dev-*.swap"
dphys-swapfile swapoff
dphys-swapfile uninstall
update-rc.d dphys-swapfile remove
apt-get -yqq purge dphys-swapfile || true

# Pibox Disk Provisioner - Note, this script will potentially format attached disks. Careful!
mkdir -p /opt/pibox/
curl -sLo /opt/pibox/provision-disk.sh https://raw.githubusercontent.com/pibox/pibox-os/main/provision-disk.sh
chmod +x /opt/pibox/provision-disk.sh
# /opt/pibox/provision-disk.sh
# Run disk provisioner before K3s starts

# This happens with PiShrink. Only uncomment if using packer
# truncate -s-1 /boot/cmdline.txt
# echo -n " init=/usr/lib/raspi-config/init_resize.sh" >> /boot/cmdline.txt

# Disable SSH
#systemctl stop ssh
#systemctl disable ssh

cat <<EOF > /usr/local/bin/rgb
#!/bin/bash
# RED
echo "17" > /sys/class/gpio/export
echo "out" > /sys/class/gpio/gpio17/direction
# GREEN
echo "27" > /sys/class/gpio/export
echo "out" > /sys/class/gpio/gpio27/direction
# BLUE
echo "23" > /sys/class/gpio/export
echo "out" > /sys/class/gpio/gpio23/direction

while :
do
    echo "1" > /sys/class/gpio/gpio17/value
    sleep 0.2
    echo "0" > /sys/class/gpio/gpio17/value
    echo "1" > /sys/class/gpio/gpio27/value
    sleep 0.2
    echo "0" > /sys/class/gpio/gpio27/value
    echo "1" > /sys/class/gpio/gpio23/value
    sleep 0.2
    echo "0" > /sys/class/gpio/gpio23/value
done
EOF
chmod +x /usr/local/bin/rgb

# SSH Config
echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
touch /boot/ssh
touch /boot/refresh-ssh-certs
rm -vf /home/pi/.ssh/*
sed -i s/PasswordAuthentication\ no/PasswordAuthentication\ yes/ /etc/ssh/sshd_config
ssh-keygen -A
service ssh --full-restart

CURRENT_HOSTNAME="$(hostname)"
rm -rfv /var/lib/pibox/server
rm -rfv /var/lib/pibox/agent/client*
rm -rfv /var/lib/pibox/agent/etc
rm -rfv /var/lib/pibox/agent/*.kubeconfig
rm -rfv /var/lib/pibox/agent/pod-manifests/
rm -rfv /var/lib/pibox/agent/*.crt
rm -rfv /var/lib/pibox/agent/*.key

echo '' > /var/log/lastlog
echo '' > /var/log/kern.log
echo '' > /var/log/syslog
echo '' > /var/log/user.log
echo '' > /var/log/faillog
echo '' > /var/log/messages
echo '' > /var/log/auth.log

# Clean bash history
history -c && history -w
exit
