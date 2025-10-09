#!/usr/bin/env bash
set -euo pipefail

UserName="${1:-root}"

# Create user if requested and missing
if [[ "$UserName" != "root" ]]; then
  if ! id -u "$UserName" >/dev/null 2>&1; then
    echo "Creating user: $UserName"
    if ! useradd -m -s /bin/bash "$UserName" 2>/dev/null; then
      # allow non-POSIX usernames if you really need them
      useradd --badname -m -s /bin/bash "$UserName"
    fi
    # Optional: grant sudo (wheel) on Alma/RHEL-like
    if getent group wheel >/dev/null 2>&1; then
      usermod -aG wheel "$UserName" || true
    fi
  fi
fi

# Normalize /etc/wsl.conf and set default user
touch /etc/wsl.conf
sed -i 's/\r$//' /etc/wsl.conf 2>/dev/null || true

if grep -q '^\[user\]' /etc/wsl.conf; then
  if grep -q '^default=' /etc/wsl.conf; then
    sed -i "s/^default=.*/default=$UserName/" /etc/wsl.conf
  else
    awk '1; /^\[user\]$/ { print "default='"'"$UserName"'"' }' /etc/wsl.conf \
      > /etc/wsl.conf.new && mv /etc/wsl.conf.new /etc/wsl.conf
  fi
else
  printf '\n[user]\ndefault=%s\n' "$UserName" >> /etc/wsl.conf
fi

# Make sure the user systemd instance can start without a TTY/PAM login
if [[ "$UserName" != "root" ]]; then
  loginctl enable-linger "$UserName" || true
fi

echo "Set default user to: $UserName"
