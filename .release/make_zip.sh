#!/usr/bin/env bash
# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
# Builds the Asset Library zip: <repo>-<version>/addons/<folder>/..., the tracked files without tests/, .release/,
# native/ (the library ships built, in bin/) and the git files. The version is plugin.cfg's. Output:
# .release/dist/<repo>-<version>.zip.
#   .release/make_zip.sh
set -euo pipefail
REPO=godot-wuifwoud
# The oldest glibc the shipped Linux library may need: a library built on a newer system asks for symbols an older one
# lacks, and then never loads there (native/build_linux_portable.sh builds it on an old one).
GLIBC_FLOOR=2.31
ADDON=$(cd "$(dirname "$0")/.." && pwd)
for so in "$ADDON"/bin/*.so; do
	[ -f "$so" ] || continue
	need=$(objdump -T "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
	if [ "$(printf '%s\n%s\n' "$need" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
		echo "refused: $(basename "$so") needs glibc $need, above $GLIBC_FLOOR (build it with native/build_linux_portable.sh)" >&2
		exit 1
	fi
done
# The folder the addon must sit in, whatever this checkout is called: its scripts name res://addons/wuifwoud/.
FOLDER=wuifwoud
VERSION=$(sed -n 's/^version="\(.*\)"$/\1/p' "$ADDON/plugin.cfg")
OUT="$ADDON/.release/dist/$REPO-$VERSION.zip"
mkdir -p "$ADDON/.release/dist"
rm -f "$OUT"
cd "$ADDON"
git ls-files | grep -vE '^(tests/|\.release/|native/|\.gitignore$|\.gitattributes$)' | python3 -c '
import sys, zipfile
out, prefix = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sys.stdin.read().splitlines():
        z.write(f, prefix + f)
' "$OUT" "$REPO-$VERSION/addons/$FOLDER/"
echo "$OUT"
