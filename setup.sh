#!/bin/bash

# Install PiBox first boot script
cat <<'EOF' > /opt/pibox/pibox-first-boot.sh
#!/bin/bash
PATH_REFRESH_SSH_CERTS=/boot/refresh-ssh-certs

ethtool --set-eee eth0 eee off

if [[ -f $PATH_GITHUB_USERNAME ]]; then
    set -e
    mkdir -p /home/pi/.ssh
    GITHUB_USERNAME=$(cat $PATH_GITHUB_USERNAME)
    echo "Installing public SSH keys for GitHub user: $GITHUB_USERNAME"
    curl -sS https://github.com/${GITHUB_USERNAME}.keys -o /tmp/authorized_keys.tmp
    mv /tmp/authorized_keys.tmp /home/pi/.ssh/authorized_keys
    curl https://github.com/${GITHUB_USERNAME}.keys > /home/pi/.ssh/authorized_keys
    sed -i -e s/#PasswordAuthentication\ yes/PasswordAuthentication\ no/g /etc/ssh/sshd_config
    rm $PATH_GITHUB_USERNAME
    chown -R pi:pi /home/pi/.ssh
    set +e
  else
    echo "Skipping GitHub SSH key installation, $PATH_GITHUB_USERNAME does not exist or is blank"
fi

if [[ -f $PATH_REFRESH_SSH_CERTS ]]; then
    echo "Generating new SSH host certs"
    rm /etc/ssh/ssh_host_*
    dpkg-reconfigure openssh-server
    rm $PATH_REFRESH_SSH_CERTS
fi
EOF
chmod +x /opt/pibox/pibox-first-boot.sh


# Install PiBox first boot service
cat <<'EOF' > /etc/systemd/system/pibox-first-boot.service
[Service]
Restart=on-failure
RestartSec=5
ExecStart=/opt/pibox/pibox-first-boot.sh
[Unit]
After=network-online.target
Wants=network-online.target
Before=sshd.service
[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl enable pibox-first-boot.service
