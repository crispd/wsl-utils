#!/usr/bin/env bash
set -euo pipefail

# run-ci-locally.sh
# Install nvm if missing, install/use Node 20.17.0, upgrade npm to 11.6.2,
# install project deps and run the manifest validator script that CI uses.
# Designed for WSL / Linux / macOS interactive shells.

NODE_VERSION="20.17.0"
NPM_VERSION="11.6.2"
# Pin NVM_VERSION to a known stable release. You can override by setting the
# environment variable NVM_VERSION before running the script, e.g.:
#   NVM_VERSION="v0.39.6" ./scripts/run-ci-locally.sh
NVM_VERSION="${NVM_VERSION:-v0.39.6}"

echo "== run-ci-locally: ensure nvm, node $NODE_VERSION, npm $NPM_VERSION, then run validator =="

command_exists() { command -v "$1" >/dev/null 2>&1; }

install_nvm() {
  if [ -d "$HOME/.nvm" ] && [ -s "$HOME/.nvm/nvm.sh" ]; then
    echo "nvm already installed at $HOME/.nvm"
    return 0
  fi

  echo "Installing nvm $NVM_VERSION..."
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash
  # The install script writes to ~/.nvm and to shell profile files; we'll source directly below.
}

load_nvm() {
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
  else
    echo "ERROR: nvm not found after install. Check $NVM_DIR" >&2
    exit 1
  fi
}

ensure_node_and_npm() {
  echo "Ensuring Node $NODE_VERSION is installed via nvm..."
  nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION"
  nvm alias default "$NODE_VERSION" || true

  echo "Node: $(node --version)"
  echo "Bundled npm: $(npm --version)"

  # Upgrade npm to the requested version if necessary
  if [ "$(npm --version)" != "$NPM_VERSION" ]; then
    echo "Installing npm@$NPM_VERSION (global)..."
    npm install -g "npm@$NPM_VERSION"
  fi
  echo "npm: $(npm --version)"
}

run_validator() {
  echo "Installing project dependencies (using package-lock.json if present)..."
  if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
    npm ci --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi

  echo "Running validator: npm run validate:manifest"
  npm run validate:manifest
}

main() {
  if ! command_exists curl; then
    echo "curl is required to install nvm. Please install curl." >&2
    exit 1
  fi

  if ! command_exists nvm; then
    install_nvm
    load_nvm
  else
    # If nvm is available as a function/command, ensure it's loaded
    if [ -z "$(command -v nvm)" ]; then
      load_nvm
    fi
  fi

  # Ensure node and npm versions
  ensure_node_and_npm

  # Run install + validator
  run_validator

  echo "== run-ci-locally: success =="
}

main "$@"
