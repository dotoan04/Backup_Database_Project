#!/usr/bin/env bash
# Provision a server-like Ubuntu 24.04+ VM with private developer homes.
#
# WARNING: sudo access to Docker is root-equivalent. The home-directory
# permissions below prevent accidental access, not access through containers.
set -Eeuo pipefail

DEFAULT_USERS=(dev1 dev2 dev3)
DOCKER_OPERATORS_GROUP="docker-operators"
SUDOERS_FILE="/etc/sudoers.d/docker-operators"

usage() {
  cat <<'EOF'
Usage: sudo bash ./vm/provision-ubuntu-24.04.sh [username ...]

With no usernames, creates: dev1 dev2 dev3

Each user receives:
  - a private /home/<user> directory (0700)
  - a private /home/<user>/source directory (0700)
  - permission to run Docker through sudo only

New accounts start with locked passwords. Root must run `passwd <user>` or
install an SSH public key before the user can log in.
EOF
}

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root with sudo."
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] \
  || die "This script supports Ubuntu only (found ${PRETTY_NAME:-unknown})."
dpkg --compare-versions "${VERSION_ID:-0}" ge "24.04" \
  || die "Ubuntu 24.04 or newer is required (found ${PRETTY_NAME:-unknown})."

if [[ "$#" -eq 0 ]]; then
  USERS=("${DEFAULT_USERS[@]}")
else
  USERS=("$@")
fi

for user in "${USERS[@]}"; do
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "Invalid username: $user"
  [[ "$user" != "root" ]] || die "root cannot be a developer username."
done

say "Installing Docker and account-management packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker.io \
  docker-compose-v2 \
  sudo
systemctl enable --now docker

say "Creating private developer accounts"
groupadd --force "$DOCKER_OPERATORS_GROUP"

for user in "${USERS[@]}"; do
  if id "$user" >/dev/null 2>&1; then
    echo "$user already exists; keeping the account."
  else
    useradd --create-home --user-group --shell /bin/bash "$user"
    echo "Created $user with a locked password."
  fi

  home="$(getent passwd "$user" | cut -d: -f6)"
  primary_group="$(id -gn "$user")"
  [[ -n "$home" && "$home" == /home/* ]] \
    || die "Refusing unexpected home directory for $user: $home"

  chown "$user:$primary_group" "$home"
  chmod 0700 "$home"
  install -d -m 0700 -o "$user" -g "$primary_group" "$home/source"

  usermod --append --groups "$DOCKER_OPERATORS_GROUP" "$user"
  if getent group docker >/dev/null 2>&1; then
    gpasswd --delete "$user" docker >/dev/null 2>&1 || true
  fi
done

say "Restricting default permissions for future source files"
cat > /etc/profile.d/private-developer-umask.sh <<'EOF'
# Developer files are private unless their owner explicitly shares them.
umask 077
EOF
chmod 0644 /etc/profile.d/private-developer-umask.sh

say "Granting Docker access through sudo"
docker_bin="$(command -v docker)"
sudoers_tmp="$(mktemp)"
trap 'rm -f "$sudoers_tmp"' EXIT

cat > "$sudoers_tmp" <<EOF
# Docker is root-equivalent. Membership must be controlled by root.
Cmnd_Alias DOCKER_OPERATOR = ${docker_bin}
%${DOCKER_OPERATORS_GROUP} ALL=(root) DOCKER_OPERATOR
EOF

chmod 0440 "$sudoers_tmp"
visudo -cf "$sudoers_tmp" >/dev/null
install -m 0440 -o root -g root "$sudoers_tmp" "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"

# Do not expose the root-owned backup implementation to developer accounts.
for path in /opt/mbc-backup /var/backups/mbc /var/lib/mbc-backup; do
  if [[ -d "$path" ]]; then
    chown root:root "$path"
    chmod 0700 "$path"
  fi
done

say "Provisioning complete"
printf 'Developer accounts: %s\n' "${USERS[*]}"
cat <<EOF

Set one password per account (not stored by this script):
  passwd <username>

Validate the setup:
  sudo bash ./vm/verify-isolation.sh ${USERS[*]}

Expected usage as a developer:
  cd ~/source
  sudo docker ps

Security boundary warning:
  These users are root-equivalent because they can run arbitrary Docker
  containers through sudo. Directory mode 0700 only prevents accidental or
  non-Docker access between accounts.
EOF
