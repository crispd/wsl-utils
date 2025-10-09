#!/usr/bin/env bash
# pre-export-clean.sh
# Safe(ish) cache/log cleanup to shrink export size before WSL backup.
# Supports: RHEL/Alma/Rocky (dnf|yum), Debian/Ubuntu (apt), Arch (pacman)
# Usage: pre-clean-wsl.sh [--dry-run] [--keep-journal-days N]
set -euo pipefail

DRY_RUN=0
KEEP_DAYS="${KEEP_DAYS:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep-journal-days) KEEP_DAYS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

run() {
  if (( DRY_RUN )); then
    echo "[DRY-RUN] $*"
  else
    echo "+ $*"
    bash -c "$*"
  fi
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "sudo"
    else
      echo ""
    fi
  else
    echo ""
  fi
}

SUDO="$(need_root)"
if [[ -z "$SUDO" && $EUID -ne 0 ]]; then
  echo "Warning: not running as root and sudo not available; some steps may be skipped." >&2
fi

ID="$(. /etc/os-release; echo "${ID:-unknown}")"
LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"

is_like() { grep -qiE "(^|[[:space:]])$1([[:space:]]|$)" <<<"$LIKE"; }

echo "Detected distro: ID='$ID' LIKE='$LIKE'"

# --- Package cache cleanup ---
if [[ "$ID" =~ (rhel|almalinux|rocky|centos) || $(is_like rhel) ]]; then
  if command -v dnf >/dev/null 2>&1; then
    run "$SUDO dnf -y clean all"
    run "$SUDO rm -rf /var/cache/dnf/* /var/tmp/*"
  elif command -v yum >/dev/null 2>&1; then
    run "$SUDO yum -y clean all"
    run "$SUDO rm -rf /var/cache/yum/* /var/tmp/*"
  fi
elif [[ "$ID" =~ (debian|ubuntu) || $(is_like debian) ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    run "$SUDO apt-get clean"
    # avoid autoremove here to stay conservative
    run "$SUDO rm -rf /var/cache/apt/archives/*.deb /var/tmp/*"
  fi
elif [[ "$ID" =~ (arch|manjaro) || $(is_like arch) ]]; then
  if command -v pacman >/dev/null 2>&1; then
    # keep last 3 versions; requires pacman-contrib for paccache—skip if absent
    if command -v paccache >/dev/null 2>&1; then
      run "$SUDO paccache -rk3"
      run "$SUDO paccache -ruk3"
    fi
    run "$SUDO pacman -Scc --noconfirm"
  fi
fi

# --- Journal & logs ---
if command -v journalctl >/dev/null 2>&1; then
  run "$SUDO journalctl --vacuum-time=${KEEP_DAYS}d"
fi

# Truncate (not delete) common logs
truncate_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    run "$SUDO sh -c '> \"$f\"'"
  fi
}

# Rotate/compress leftovers are often fine to remove
run "$SUDO find /var/log -type f -name '*.gz' -delete 2>/dev/null || true"
run "$SUDO find /var/log -type f -name '*.1' -delete 2>/dev/null || true"

# Truncate top-level text logs
while IFS= read -r f; do truncate_if_exists "$f"; done < <(find /var/log -maxdepth 1 -type f 2>/dev/null || true)

# --- Temporary files ---
run "$SUDO rm -rf /tmp/* /var/tmp/*"

# --- Docker images/containers (optional) ---
# Uncomment if you want to prune Docker to save lots of space
# if command -v docker >/dev/null 2>&1; then
#   run "$SUDO docker system prune -af"
# fi

echo "Pre-clean complete."
