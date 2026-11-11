#!/usr/bin/env bash
# PC2, step 1 (as root): Docker, Nextflow, tools, user ngs, data layout. Needs internet (~1 GB).
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/f/pc2_kit/setup_ubuntu_pc2.sh
set -euo pipefail
NGS_USER=ngs
cat > /etc/wsl.conf <<CONF
[boot]
systemd=true
[user]
default=$NGS_USER
CONF
id "$NGS_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$NGS_USER"
echo "$NGS_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$NGS_USER
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git wget unzip tmux rsync openjdk-17-jre-headless samtools bcftools tabix
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
usermod -aG docker "$NGS_USER"
if [ ! -x /usr/local/bin/nextflow ]; then
  cd /tmp && curl -fsSL https://get.nextflow.io | bash && mv nextflow /usr/local/bin/ && chmod 755 /usr/local/bin/nextflow
fi
# no automatic apt upgrades: a Java update under a running Nextflow breaks process launch (jspawnhelper)
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
mkdir -p /data/raredisease/{references,samples,runs,tmp}
chown -R "$NGS_USER:$NGS_USER" /data/raredisease
echo "Шаг 1 готов. Теперь в PowerShell: wsl --shutdown, затем шаг 2 (kit_import.sh)."
