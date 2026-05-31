#!/bin/sh

set -eu

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v apt-get >/dev/null 2>&1; then
  printf '%s\n' "This bootstrap script expects Ubuntu/Debian with apt-get." >&2
  exit 69
fi

$SUDO apt-get update
$SUDO apt-get install -y ca-certificates curl gnupg openssl

$SUDO install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
  printf '%s\n' "Cannot detect Ubuntu codename." >&2
  exit 69
fi

printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

$SUDO apt-get update
$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if [ -n "$SUDO" ]; then
  $SUDO usermod -aG docker "$USER" || true
fi

docker --version
docker compose version

printf '%s\n' "Docker installed. If you were added to the docker group, log out and back in before running docker without sudo."
