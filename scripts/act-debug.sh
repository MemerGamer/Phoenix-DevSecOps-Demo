#!/usr/bin/env bash
# Local pipeline debugger using act.
# Run from the repo root: bash scripts/act-debug.sh [job]
# If no job is given, runs all jobs in order.
#
# IMPORTANT: what actually breaks deploy-gate under act, and what fixes it.
#
# CI run 35591276722 failed with "Unable to resolve action
# ... unable to find version v0.4.0" -- that is act failing to resolve the
# `uses: MemerGamer/devsecops-attestation/actions/...@v0.4.0` action
# *reference itself* (there is no v0.4.0 tag in that repository yet), before
# actions/setup.sh ever runs. That is exactly what act's --local-repository
# flag is for: it redirects a given "owner/repo@ref" (or full URL@ref) to a
# local folder instead of trying to fetch that ref, so action resolution
# succeeds against a local devsecops-attestation checkout regardless of
# whether v0.4.0 has been tagged upstream. This script passes it below,
# pointed at $ATTESTATION_SRC.
#
# --local-repository only fixes *resolving the action*, though. Once
# resolved, actions/setup's own setup.sh still runs, and with
# `version: 0.4.0` (as pinned in the workflow) it does a plain `curl` for a
# release archive from GitHub Releases / download-base-url -- which still
# 404s with no v0.4.0 release actually published, --local-repository or not.
# So deploy-gate additionally needs its actions/setup step's `version` input
# changed from `0.4.0` to `source` to exercise it locally: that makes
# setup.sh build the CLI binaries from the (now locally-resolved) checkout
# with `go build` instead of downloading a release archive, which requires a
# Go toolchain on PATH *inside the act job's runner image* (the default
# catthehacker/ubuntu images do not ship Go; either use an image that does,
# or add a `setup-go`-equivalent step ahead of it for local testing only).
# That workflow edit is for local debugging only -- do not commit it. Once
# v0.4.0 is released, the pinned `@v0.4.0` steps resolve normally both under
# act (via --local-repository, or without it once the tag exists) and on
# real GitHub Actions runners.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Path to a local devsecops-attestation checkout. Used both to build the
# keygen binary for local test key generation below, and as the
# --local-repository target so act can resolve the
# MemerGamer/devsecops-attestation/actions/...@v0.4.0 steps without that tag
# existing upstream (see the header comment). Override with the
# ATTESTATION_SRC environment variable if your checkout lives elsewhere.
ATTESTATION_SRC="${ATTESTATION_SRC:-$REPO_DIR/../devsecops-attestation}"

# Per-user cache directory, never a fixed shared /tmp path: a world-writable
# shared path (e.g. /tmp/act-bins) is a symlink/TOCTOU target for any other
# local user or process, which matters here because $BINS_DIR ends up
# holding an executable this script runs. XDG_CACHE_HOME (or ~/.cache as its
# default) is created with the current user's normal umask and is not
# shared across users.
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/act-debug"
BINS_DIR="$CACHE_ROOT/bin"
ARTIFACTS_DIR="$CACHE_ROOT/artifacts"
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

# ── Build keygen ─────────────────────────────────────────────────────────
# Only keygen is needed locally: the pipeline itself now calls
# devsecops-attestation's attest/verify/gate binaries via the composite
# actions (actions/setup, actions/normalize-sign, actions/gate), not via a
# direct install step in this repo.
#
# Always rebuilt, never reused from a prior run: this script never executes
# a pre-existing binary from a shared location, even a per-user cache one,
# so there is nothing here an earlier compromised or stale run could have
# planted for this run to trust. `go build` is fast enough that rebuilding
# every invocation is not a meaningful cost.
echo "Building devsecops-attestation keygen..."
mkdir -p "$BINS_DIR"
(cd "$ATTESTATION_SRC" && go build -o "$BINS_DIR/keygen" ./cmd/keygen)
echo "keygen built in $BINS_DIR"

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
  # A fresh, private-mode temp directory per run for the generated key
  # material: never a fixed shared path, and gone as soon as .secrets has
  # been written from it.
  KEYS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/act-debug-keys.XXXXXX")"
  trap 'rm -rf "$KEYS_DIR"' EXIT
  for check in sast sca config secret; do
    "$BINS_DIR/keygen" --out "$KEYS_DIR/$check" --force
  done
  # .secrets holds private signing keys in plaintext; restrict its
  # permissions to the current user from the moment it is created, not
  # after the fact (a window during which a shared-umask default could
  # leave it world- or group-readable).
  umask 077
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
  rm -rf "$KEYS_DIR"
  trap - EXIT
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
ACT_CMD=(
  act push
  -e "$PUSH_EVENT_FILE"
  --secret-file "$SECRETS_FILE"
  --artifact-server-path "$ARTIFACTS_DIR"
  # Resolves the MemerGamer/devsecops-attestation/actions/...@v0.4.0 steps
  # against the local checkout instead of a v0.4.0 git ref that does not
  # exist upstream yet (see the header comment). Syntax per `act --help`:
  # "owner/repo@ref=/local/path" matches that ref on any host/protocol.
  --local-repository "MemerGamer/devsecops-attestation@v0.4.0=$ATTESTATION_SRC"
)

# See the header comment: --local-repository above lets act resolve the
# deploy-gate action references at all, but actions/setup's `version: 0.4.0`
# input still downloads a release archive that does not exist yet, so the
# job still fails at that step unless it is temporarily changed to
# `version: source` (requires Go on the act runner image's PATH). That
# workflow edit is for local debugging only; do not commit it.
if [ -z "$JOB" ] || [ "$JOB" = "deploy-gate" ]; then
  echo "NOTE: --local-repository lets act resolve the deploy-gate action" >&2
  echo "references, but actions/setup's 'version: 0.4.0' input still" >&2
  echo "downloads a release archive that does not exist until v0.4.0 is" >&2
  echo "published. To exercise deploy-gate locally anyway, temporarily" >&2
  echo "change that step's 'version' input to 'source' in the workflow" >&2
  echo "(requires Go on the act runner image's PATH -- the default" >&2
  echo "catthehacker/ubuntu images do not ship Go) and revert the edit" >&2
  echo "before committing." >&2
fi

if [ -n "$JOB" ]; then
  ACT_CMD+=(-j "$JOB")
  echo "Running job: $JOB"
else
  echo "Running full pipeline..."
fi

"${ACT_CMD[@]}"
