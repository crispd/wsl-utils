# wsl-utils

Development notes and local CI validation

## Local CI / validator

This repository includes a small local CI helper to make validator runs reproducible locally.

- `scripts/run-ci-locally.sh` — WSL/Linux/macOS helper. It will install `nvm` if missing, install Node 20.17.0 via nvm, upgrade to `npm@11.6.2`, install project dependencies, and run the manifest validator.

Usage:

```bash
# make executable if needed
chmod +x scripts/run-ci-locally.sh

# Run with defaults (nvm v0.39.6, Node 20.17.0, npm 11.6.2)
./scripts/run-ci-locally.sh

# Override the nvm version used by the script
NVM_VERSION="v0.39.6" ./scripts/run-ci-locally.sh
```

## Editor validation

- The JSON schema for `manifest.json` is at `schema/manifest.schema.json`.
- VS Code settings map `manifest.json` to this local schema (`.vscode/settings.json`) and map the local draft meta-schema copy at `schema/draft2020-12.json` so the editor won't fetch the remote meta-schema.

## CI

- A GitHub Actions workflow `.github/workflows/validate-manifest.yml` runs the validator on push and PRs. It uses Node 20 to match local CI settings.
