#!/usr/bin/env bash
# Local pipeline debugger using act.
# Run from the repo root: bash scripts/act-debug.sh [job]
# If no job is given, runs all jobs in order.
#
# The deploy-gate job's `uses: MemerGamer/devsecops-attestation/actions/...`
# steps download a release archive from GitHub Releases. Until v0.4.0 is
# published there is nothing to download, so a plain `act` run of
# deploy-gate will fail at the setup action. Point act at a local checkout
# of devsecops-attestation instead, with (recent act versions only):
#
#   act push -e push.json \
#     --local-repository MemerGamer/devsecops-attestation@v0.4.0="$ATTESTATION_SRC"
#
# Check `act --help` for `--local-repository` / `-l` support in your
# installed version; older act releases do not have it, in which case the
# composite actions must be exercised directly (see
# devsecops-attestation/actions/test/run-local.sh) rather than through act.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Path to a local devsecops-attestation checkout, used to build the keygen
# binary for local test key generation below. Override with the
# ATTESTATION_SRC environment variable if your checkout lives elsewhere.
ATTESTATION_SRC="${ATTESTATION_SRC:-$REPO_DIR/../devsecops-attestation}"
BINS_DIR="/tmp/act-bins"
KEYS_DIR="/tmp/act-keys"
ARTIFACTS_DIR="/tmp/act-artifacts"
SECRETS_FILE="$REPO_DIR/.secrets"

cd "$REPO_DIR"

if [ ! -d "$ATTESTATION_SRC" ]; then
  echo "ERROR: devsecops-attestation checkout not found at $ATTESTATION_SRC" >&2
  echo "Set ATTESTATION_SRC to point at a local checkout." >&2
  exit 1
fi

# ── Detect Docker socket ───────────────────────────────────────────────────
if [ -n "${DOCKER_HOST:-}" ]; then
  echo "Using existing DOCKER_HOST: $DOCKER_HOST"
elif [ -S "${XDG_RUNTIME_DIR:-}/docker.sock" ]; then
  export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
elif [ -S "$HOME/.docker/desktop/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.docker/desktop/docker.sock"
elif [ -S /var/run/docker.sock ]; then
  export DOCKER_HOST="unix:///var/run/docker.sock"
else
  echo "ERROR: No Docker socket found. Is Docker running?" >&2
  exit 1
fi
echo "Using Docker: $DOCKER_HOST"

# ── Build keygen if missing ─────────────────────────────────────────────────
# Only keygen is needed locally: the pipeline itself now calls
# devsecops-attestation's attest/verify/gate binaries via the composite
# actions (actions/setup, actions/normalize-sign, actions/gate), not via a
# direct install step in this repo.
if [ ! -f "$BINS_DIR/keygen" ]; then
  echo "Building devsecops-attestation keygen..."
  mkdir -p "$BINS_DIR"
  (cd "$ATTESTATION_SRC" && go build -o "$BINS_DIR/keygen" ./cmd/keygen)
  echo "keygen built in $BINS_DIR"
fi

# ── Generate per-check-type test keys if .secrets is missing ────────────────
# act reads secrets from a --secret-file (the .secrets file below), one
# NAME=value pair per line, corresponding to the repository secrets the
# workflow expects (SAST_SIGNING_KEY, SCA_SIGNING_KEY, CONFIG_SIGNING_KEY,
# SECRET_SCANNING_SIGNING_KEY, and their *_PUBLIC_KEY counterparts).
if [ ! -f "$SECRETS_FILE" ]; then
  echo "Generating per-check-type signing keys..."
  mkdir -p "$KEYS_DIR"
  for check in sast sca config secret; do
    "$BINS_DIR/keygen" --out "$KEYS_DIR/$check" --force
  done
  {
    echo "SAST_SIGNING_KEY=$(cat "$KEYS_DIR/sast/private.hex")"
    echo "SCA_SIGNING_KEY=$(cat "$KEYS_DIR/sca/private.hex")"
    echo "CONFIG_SIGNING_KEY=$(cat "$KEYS_DIR/config/private.hex")"
    echo "SECRET_SCANNING_SIGNING_KEY=$(cat "$KEYS_DIR/secret/private.hex")"
    echo "SAST_PUBLIC_KEY=$(cat "$KEYS_DIR/sast/public.hex")"
    echo "SCA_PUBLIC_KEY=$(cat "$KEYS_DIR/sca/public.hex")"
    echo "CONFIG_PUBLIC_KEY=$(cat "$KEYS_DIR/config/public.hex")"
    echo "SECRET_SCANNING_PUBLIC_KEY=$(cat "$KEYS_DIR/secret/public.hex")"
  } > "$SECRETS_FILE"
  echo "Keys written to $SECRETS_FILE"
fi

mkdir -p "$ARTIFACTS_DIR"

# ── Run act ───────────────────────────────────────────────────────────────
JOB="${1:-}"
ACT_CMD=(act push -e push.json --secret-file "$SECRETS_FILE")

if command -v act >/dev/null 2>&1 && act --help 2>&1 | grep -q -- '--local-repository'; then
  ACT_CMD+=(--local-repository "MemerGamer/devsecops-attestation@v0.4.0=$ATTESTATION_SRC")
else
  echo "NOTE: installed act has no --local-repository support (or act is not" >&2
  echo "installed); the deploy-gate job's setup/normalize-sign/gate steps will" >&2
  echo "fail to resolve until v0.4.0 is published, unless you add that flag" >&2
  echo "manually. See the comment at the top of this script." >&2
fi

if [ -n "$JOB" ]; then
  ACT_CMD+=(-j "$JOB")
  echo "Running job: $JOB"
else
  echo "Running full pipeline..."
fi

"${ACT_CMD[@]}"
