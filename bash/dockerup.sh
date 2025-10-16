#!/usr/bin/env bash
# Spin up Docker, install Portainer CE, and configure unattended upgrades on Debian/Ubuntu.

set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run me as root or with sudo."
    exit 1
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_LIKE="${ID_LIKE:-}"
  else
    echo "Cannot detect OS. /etc/os-release not found."
    exit 1
  fi

  if [[ "${OS_ID}" != "ubuntu" && "${OS_ID}" != "debian" ]]; then
    # Some derivatives set ID to the derivative but ID_LIKE includes debian
    if [[ "${OS_LIKE}" != *"debian"* ]]; then
      echo "This script targets Debian or Ubuntu and their derivatives."
      exit 1
    fi
    # Best effort for derivatives: treat like Debian family
    [[ -z "${OS_CODENAME}" ]] && OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
    [[ -z "${OS_CODENAME}" ]] && { echo "Could not determine codename."; exit 1; }
  fi
  [[ -z "${OS_CODENAME}" ]] && { echo "Could not determine codename."; exit 1; }

  echo "Detected: ${OS_ID} ${OS_CODENAME}"
}

install_docker() {
  echo "Installing Docker Engine from the official repo..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  ARCH="$(dpkg --print-architecture)"
  echo \
"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "Docker installed and running."
}

add_user_to_docker_group() {
  # If invoked via sudo, prefer the invoking user. Otherwise, skip.
  local target_user="${SUDO_USER:-}"
  if [[ -n "${target_user}" && "${target_user}" != "root" ]]; then
    if getent group docker >/dev/null; then
      usermod -aG docker "${target_user}" || true
      echo "Added ${target_user} to the docker group. They may need to log out and in."
    fi
  fi
}

deploy_portainer() {
  echo "Deploying Portainer CE..."
  docker volume create portainer_data >/dev/null

  # Stop and remove any old container if present
  if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
    docker rm -f portainer >/dev/null 2>&1 || true
  fi

  # Expose 9443 for HTTPS UI and 8000 for the edge agent tunnel
  docker run -d \
    --name portainer \
    --restart=always \
    -p 8000:8000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest

  echo "Portainer is starting. UI will be at https://$(hostname -I | awk '{print $1}'):9443/"
}

configure_unattended_upgrades() {
  echo "Configuring unattended upgrades..."
  apt-get install -y unattended-upgrades

  # Enable periodic updates and unattended upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Let the package populate defaults for security updates
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure --priority=low unattended-upgrades

  # Enforce auto reboot at a predictable time
  cat >/etc/apt/apt.conf.d/51auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:30";
EOF

  systemctl restart unattended-upgrades || true
  echo "Unattended upgrades enabled with nightly auto reboot at 02:30."
}

maybe_open_firewall() {
  # If UFW is present and active, allow needed ports
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      echo "UFW detected. Opening 9443 and 8000."
      ufw allow 9443/tcp || true
      ufw allow 8000/tcp || true
    fi
  fi
}

main() {
  require_root
  detect_os
  install_docker
  add_user_to_docker_group
  deploy_portainer
  configure_unattended_upgrades
  maybe_open_firewall

  echo
  echo "Done."
  echo "Portainer URL: https://$(hostname -I | awk '{print $1}'):9443"
  echo "Default update policy: automatic security updates with nightly reboot at 02:30."
}

main "$@"
