#!/usr/bin/env bash
# Apply all DTN-paper demo patches to freshly cloned sub-repos.
# Run from the root of DTN-paper (where charon/, cspcl/, hardy/, ud3tn/ live).
#
# Usage:
#   cd /path/to/DTN-paper
#   bash patches/apply.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches"

die() { echo "ERROR: $*" >&2; exit 1; }
need_dir() { [ -d "$REPO_ROOT/$1" ] || die "Directory '$1' not found — clone it first"; }

need_dir charon
need_dir cspcl
need_dir hardy
need_dir ud3tn

echo "==> Applying charon patch"
patch -p1 -d "$REPO_ROOT/charon" < "$PATCH_DIR/charon.patch"

echo "==> Applying cspcl patch"
patch -p1 -d "$REPO_ROOT/cspcl" < "$PATCH_DIR/cspcl.patch"
# Recreate symlink for ud3tn integration header
mkdir -p "$REPO_ROOT/cspcl/ud3tn-integration/cla"
ln -sf ../src/cla_csp.h "$REPO_ROOT/cspcl/ud3tn-integration/cla/cla_csp.h"

echo "==> Applying hardy patch"
patch -p1 -d "$REPO_ROOT/hardy" < "$PATCH_DIR/hardy.patch"
# hardy needs a charon clone for its cspcl Rust bindings build
if [ ! -d "$REPO_ROOT/hardy/charon/.git" ]; then
    echo "    Cloning charon into hardy/charon ..."
    git clone https://github.com/dtn7/charon.git "$REPO_ROOT/hardy/charon"
fi

echo "==> Applying ud3tn tracked-changes patch"
patch -p1 -d "$REPO_ROOT/ud3tn" < "$PATCH_DIR/ud3tn.patch"

echo "==> Applying ud3tn new-files patch and fixing absolute paths"
# Fix hardcoded libcsp paths to match this machine's DTN-paper root
sed "s|/home/prnm691/Documents/DTN-paper|$REPO_ROOT|g" \
    "$PATCH_DIR/ud3tn_new_files.patch" | patch -p1 -d "$REPO_ROOT"

echo ""
echo "All patches applied."
echo ""
echo "NOTE: ud3tn/mk/build.mk and mk/posix.mk reference libcsp at:"
echo "  $REPO_ROOT/libcsp"
echo "Make sure you have built libcsp there (with RDP enabled) before"
echo "building ud3tn."
