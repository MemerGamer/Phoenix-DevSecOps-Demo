#!/usr/bin/env bash
# Local pipeline debugger using act.
# Run from the repo root: bash scripts/act-debug.sh [job]
# If no job is given, runs all jobs in order.
#
# IMPORTANT: the deploy-gate job cannot run under act until a
# devsecops-attestation v0.4.0 GitHub release actually exists. Its
# `uses: MemerGamer/devsecops-attestation/actions/...@v0.4.0` steps call
# actions/setup, which downloads a release archive from GitHub Releases;
# with no v0.4.0 release published, that download 404s no matter what act
# flags are passed. `--local-repository` only redirects where the *action
# definition* (action.yml) is resolved from -- it does not change what
# actions/setup itself downloads at runtime, since that is a plain `curl`
# inside setup.sh pointed at download-base-url / the release tag. So
# `--local-repository` alone does NOT make deploy-gate work under act.
#
# The only way to exercise deploy-gate locally today is to temporarily edit
# the workflow so the setup step uses `version: source` instead of
# `version: 0.4.0` (see actions/setup/action.yml in devsecops-attestation),
# which builds the CLI binaries from the local checkout with `go build`
# instead of downloading a release archive. That requires Go on the
# runner's PATH. Do not commit that workflow edit; revert it once you are
# done debugging. Once v0.4.0 is released, the pinned `@v0.4.0` steps will
# resolve normally.
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
#
# .secrets is gitignored. A missing file fails loudly by default instead of
# silently generating one, since a missing file usually means secrets were
# never set up rather than that a keyless run was intended. Set
# ALLOW_NO_SECRETS=1 to opt in explicitly; that generates fresh
# per-check-type test signing keys into .secrets.
if [ ! -f "$SECRETS_FILE" ]; then
  if [ "${ALLOW_NO_SECRETS:-0}" != "1" ]; then
    echo "ERROR: $SECRETS_FILE not found." >&2
    echo "Set ALLOW_NO_SECRETS=1 to generate per-check-type test signing" >&2
    echo "keys automatically and proceed." >&2
    exit 1
  fi
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

# ── Generate a minimal push event payload if missing ────────────────────────
# push.json is gitignored (it is a local act input, not workflow config).
# act needs an event payload for `act push`; a minimal push event with just
# a ref is enough to satisfy the workflow's `on.push.branches` filter.
PUSH_EVENT_FILE="$REPO_DIR/push.json"
if [ ! -f "$PUSH_EVENT_FILE" ]; then
  echo "Generating minimal push event payload at $PUSH_EVENT_FILE..."
  printf '{"ref":"refs/heads/main"}\n' > "$PUSH_EVENT_FILE"
fi

# ── Run act ───────────────────────────────────────────────────────────────
JOB="${1:-}"
ACT_CMD=(act push -e "$PUSH_EVENT_FILE" --secret-file "$SECRETS_FILE" --artifact-server-path "$ARTIFACTS_DIR")

# See the header comment: deploy-gate cannot run under act until
# devsecops-attestation v0.4.0 is released, no matter which act flags are
# passed, because actions/setup downloads a release archive that does not
# exist yet. --local-repository only changes where the action *definition*
# resolves from, not what actions/setup fetches at runtime.
if [ -z "$JOB" ] || [ "$JOB" = "deploy-gate" ]; then
  echo "NOTE: deploy-gate cannot run under act until devsecops-attestation" >&2
  echo "v0.4.0 is released (actions/setup would 404 downloading the release" >&2
  echo "archive). To exercise it locally anyway, temporarily change its" >&2
  echo "actions/setup step to 'version: source' in the workflow (requires Go" >&2
  echo "on the runner's PATH) and revert that change before committing." >&2
fi

if [ -n "$JOB" ]; then
  ACT_CMD+=(-j "$JOB")
  echo "Running job: $JOB"
else
  echo "Running full pipeline..."
fi

"${ACT_CMD[@]}"
