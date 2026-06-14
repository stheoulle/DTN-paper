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
need_dir() { [ -d "$REPO_ROOT/$1" ] || die "Directory '$1' not found — clone it first (see README.md)"; }

need_dir charon
need_dir cspcl
need_dir hardy
need_dir ud3tn

echo "==> Applying charon patch"
git -C "$REPO_ROOT/charon" apply "$PATCH_DIR/charon.patch"

echo "==> Applying cspcl patch"
git -C "$REPO_ROOT/cspcl" apply \
    <(sed "s|__DTN_ROOT__|$REPO_ROOT|g" "$PATCH_DIR/cspcl.patch")

echo "==> Applying hardy patch"
git -C "$REPO_ROOT/hardy" apply "$PATCH_DIR/hardy.patch"

echo "==> Cloning charon into hardy/charon (needed for cspcl Rust bindings)"
if [ ! -d "$REPO_ROOT/hardy/charon/.git" ]; then
    git clone https://github.com/dtn7/charon.git "$REPO_ROOT/hardy/charon"
fi

echo "==> Applying ud3tn tracked-changes patch"
git -C "$REPO_ROOT/ud3tn" apply \
    <(sed "s|__DTN_ROOT__|$REPO_ROOT|g" "$PATCH_DIR/ud3tn.patch")

echo "==> Applying ud3tn new-files patch"
patch -p1 -d "$REPO_ROOT/ud3tn" < "$PATCH_DIR/ud3tn_new_files.patch"

echo "==> Creating cspcl symlink for ud3tn integration header"
mkdir -p "$REPO_ROOT/cspcl/ud3tn-integration/cla"
ln -sf ../src/cla_csp.h "$REPO_ROOT/cspcl/ud3tn-integration/cla/cla_csp.h"

echo ""
echo "All patches applied successfully."
echo ""
echo "NOTE: ud3tn Makefiles reference libcsp at: $REPO_ROOT/libcsp"
echo "Make sure you have built libcsp there (with --enable-rdp) before running 'make posix' in ud3tn."
