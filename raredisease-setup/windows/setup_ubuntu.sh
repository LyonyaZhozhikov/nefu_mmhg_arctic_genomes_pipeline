#!/usr/bin/env bash
# One-time setup of the WSL2 Ubuntu 24.04 distro for nf-core/raredisease.
# Run as root:  wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/NGS_pipeline/raredisease-setup/windows/setup_ubuntu.sh
set -euo pipefail
NGS_USER=${NGS_USER:-ngs}

# systemd (needed for the docker service) and a default non-root user
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true
[user]
default=$NGS_USER
EOF
id "$NGS_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$NGS_USER"
echo "$NGS_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$NGS_USER

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git wget unzip tmux openjdk-17-jre-headless \
    samtools bcftools tabix

# Docker Engine from Docker's apt repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
usermod -aG docker "$NGS_USER"

# Nextflow
if [ ! -x /usr/local/bin/nextflow ]; then
  cd /tmp && curl -fsSL https://get.nextflow.io | bash && mv nextflow /usr/local/bin/ && chmod 755 /usr/local/bin/nextflow
fi

# Data layout used by params_grch38_wgs.yaml and conf/local.config
mkdir -p /data/raredisease/{references/grch38,runs,tmp}
chown -R "$NGS_USER:$NGS_USER" /data/raredisease
ln -sfn /mnt/c/NGS_pipeline/raredisease-setup /home/$NGS_USER/raredisease-setup
echo "setup done"
