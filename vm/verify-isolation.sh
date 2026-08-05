#!/usr/bin/env bash
# Verify the account and Docker policy created by provision-ubuntu-24.04.sh.
set -Eeuo pipefail

DEFAULT_USERS=(dev1 dev2 dev3)
DOCKER_OPERATORS_GROUP="docker-operators"
FAILED=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

[[ "$(id -u)" -eq 0 ]] || { echo "Run this script as root with sudo." >&2; exit 1; }

if [[ "$#" -eq 0 ]]; then
  USERS=("${DEFAULT_USERS[@]}")
else
  USERS=("$@")
fi

if visudo -cf /etc/sudoers.d/docker-operators >/dev/null; then
  pass "Docker sudoers policy parses cleanly"
else
  fail "Docker sudoers policy is invalid"
fi

if systemctl is-active --quiet docker; then
  pass "Docker service is active"
else
  fail "Docker service is not active"
fi

for user in "${USERS[@]}"; do
  if ! id "$user" >/dev/null 2>&1; then
    fail "Account $user does not exist"
    continue
  fi

  home="$(getent passwd "$user" | cut -d: -f6)"
  mode="$(stat --format='%a' "$home")"
  [[ "$mode" == "700" ]] \
    && pass "$home is mode 0700" \
    || fail "$home is mode $mode instead of 0700"

  [[ -d "$home/source" && "$(stat --format='%U:%G:%a' "$home/source")" == "$user:$(id -gn "$user"):700" ]] \
    && pass "$home/source is private and owned by $user" \
    || fail "$home/source ownership or mode is incorrect"

  id -nG "$user" | tr ' ' '\n' | grep -Fxq "$DOCKER_OPERATORS_GROUP" \
    && pass "$user belongs to $DOCKER_OPERATORS_GROUP" \
    || fail "$user does not belong to $DOCKER_OPERATORS_GROUP"

  if id -nG "$user" | tr ' ' '\n' | grep -Fxq docker; then
    fail "$user belongs to docker and can bypass sudo"
  else
    pass "$user is not in the docker group"
  fi

  if runuser --user "$user" -- docker info >/dev/null 2>&1; then
    fail "$user can access Docker without sudo"
  else
    pass "$user cannot access Docker without sudo"
  fi

  sudo --list --user "$user" | grep -Fq "$(command -v docker)" \
    && pass "$user has the sudo Docker policy" \
    || fail "$user is missing the sudo Docker policy"
done

for source_user in "${USERS[@]}"; do
  id "$source_user" >/dev/null 2>&1 || continue
  for target_user in "${USERS[@]}"; do
    [[ "$source_user" != "$target_user" ]] || continue
    id "$target_user" >/dev/null 2>&1 || continue

    target_home="$(getent passwd "$target_user" | cut -d: -f6)"
    if runuser --user "$source_user" -- test -r "$target_home/source"; then
      fail "$source_user can read $target_user's source directory"
    else
      pass "$source_user cannot read $target_user's source directory"
    fi
  done
done

exit "$FAILED"
