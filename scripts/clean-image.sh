#!/usr/bin/env bash
set -euo pipefail
# Packer's communicator finishes before capture. cloud-init regenerates host keys
# and instance identity on the next launch. Preserve each provider's cloud agent.
sudo cloud-init clean --logs --machine-id
sudo rm -f /etc/ssh/ssh_host_* /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
sudo truncate -s 0 /var/log/wtmp /var/log/btmp /var/log/lastlog
sudo sync
