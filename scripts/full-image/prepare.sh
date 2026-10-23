#!/bin/bash
set -euo pipefail
sudo cloud-init status --wait
if [ -d /sys/firmware/efi ]; then
  echo 'Expected BIOS boot on the fresh t2 builder; refusing boot-loader changes.' >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -o DPkg::Lock::Timeout=300 update
sudo -E apt-get -o DPkg::Lock::Timeout=300 install -y linux-generic grub-pc-bin nginx sqlite3 curl qemu-guest-agent
sudo mkdir -p /opt/migration-proof /etc/migration-proof /var/lib/migration-proof
sudo env BUILD_VERSION="$BUILD_VERSION" python3 - <<'PY'
import json, os, sqlite3, pathlib, datetime
p=pathlib.Path('/opt/migration-proof')
origin={'origin_cloud':'AWS','build_version':os.environ['BUILD_VERSION'],'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'complete single boot disk image'}
(p/'origin.json').write_text(json.dumps(origin,indent=2)+'\n')
pathlib.Path('/etc/migration-proof/application.conf').write_text('application=portable-web-lab\ncreated_on=AWS\ndatabase=/var/lib/migration-proof/application.db\n')
with sqlite3.connect('/var/lib/migration-proof/application.db') as db:
    db.execute('CREATE TABLE IF NOT EXISTS records(id INTEGER PRIMARY KEY, message TEXT)')
    db.execute('INSERT INTO records(message) VALUES(?)',('This database was created in AWS before the disk image export.',))
pathlib.Path('/var/www/html/index.html').write_text('<!doctype html><html><head><title>AWS to OCI image migration</title></head><body><h1>Built in AWS. Booted from the same disk image in OCI.</h1><p>The OS, nginx, configuration and SQLite database were captured together.</p></body></html>\n')
PY
# Use a generic Ubuntu kernel with virtio drivers for both Xen and OCI KVM.
for driver in virtio_pci virtio_blk virtio_scsi virtio_net; do
  echo "$driver" | sudo tee -a /etc/initramfs-tools/modules >/dev/null
done
sudo update-initramfs -u -k all
kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*-generic' -printf '%f\n' | sort -V | tail -1)
test -n "$kernel"
kernel=${kernel#vmlinuz-}
sudo mkdir -p /etc/default/grub.d
printf 'GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux %s"\nGRUB_TIMEOUT=2\nGRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200n8"\n' "$kernel" | sudo tee /etc/default/grub.d/99-portable.cfg >/dev/null
# Remove the alternate EFI boot path from this disposable BIOS-only lab image.
# Do not alter the partition table or root filesystem.
if mountpoint -q /boot/efi; then
  sudo find /boot/efi -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  sudo umount /boot/efi
fi
sudo sed -i '\|[[:space:]]/boot/efi[[:space:]]|d' /etc/fstab
root_device=$(findmnt -n -o SOURCE /)
disk_name=$(lsblk -no PKNAME "$root_device" | head -1)
test -n "$disk_name"
sudo grub-install --target=i386-pc --recheck "/dev/$disk_name"
sudo update-grub
# Cloud-neutral DHCP and metadata selection; no stored AWS MAC/IP addresses.
sudo rm -f /etc/netplan/50-cloud-init.yaml
sudo tee /etc/netplan/99-portable.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    portable:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
EOF
sudo chmod 600 /etc/netplan/99-portable.yaml
sudo tee /etc/cloud/cloud.cfg.d/99-portable.cfg >/dev/null <<'EOF'
datasource_list: [ Oracle, Ec2, None ]
network: {config: disabled}
EOF
sudo systemctl enable nginx ssh
sudo systemctl start nginx
sudo sshd -t
curl --fail --silent http://127.0.0.1/ >/dev/null
sudo sync
