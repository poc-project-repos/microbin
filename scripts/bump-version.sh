#!/usr/bin/env bash
# ==============================================================================
# MicroBin Automated Version Bumper
# Usage:
#   ./scripts/bump-version.sh 2.2.0
#   ./scripts/bump-version.sh v2.2.0
# ==============================================================================
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version> (e.g. $0 2.2.0 or $0 v2.2.0)"
    exit 1
fi

RAW_VERSION="$1"
# Strip leading 'v' if present
SEMVER="${RAW_VERSION#v}"

# Validate semantic version format (X.Y.Z)
if [[ ! "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Error: '$SEMVER' is not a valid Semantic Version (expected X.Y.Z or X.Y.Z-rc1)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CARGO_TOML="$ROOT_DIR/Cargo.toml"

CURRENT_VERSION=$(grep '^version =' "$CARGO_TOML" | head -n1 | cut -d '"' -f2)
echo "Current version in Cargo.toml: $CURRENT_VERSION"
echo "Target version:               $SEMVER"

if [ "$CURRENT_VERSION" = "$SEMVER" ]; then
    echo "Cargo.toml is already at version $SEMVER. Nothing to do."
    exit 0
fi

# Update Cargo.toml version field
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^version = \".*\"/version = \"$SEMVER\"/" "$CARGO_TOML"
else
    sed -i "s/^version = \".*\"/version = \"$SEMVER\"/" "$CARGO_TOML"
fi

echo "Updated Cargo.toml to version $SEMVER."
echo "Running cargo check to update Cargo.lock..."
(cd "$ROOT_DIR" && cargo check --quiet)

echo "Successfully synchronized Cargo.toml and Cargo.lock to version $SEMVER."
