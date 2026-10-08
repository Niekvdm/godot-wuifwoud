#!/usr/bin/env bash
# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
# Builds the Linux library on an old glibc (Ubuntu 20.04: glibc 2.31), so it loads on every distribution from there
# on: a library built on a newer system asks for symbols an older glibc lacks, and fails to load there. Needs podman or
# docker, and godot-cpp at native/godot-cpp. The sources and godot-cpp are copied into a temporary folder first, so the
# build leaves no objects in a godot-cpp checkout other builds share.
#   native/build_linux_portable.sh <extension_api.json>
# Output: native/bin/libwuifwoud_core.linux.template_{debug,release}.x86_64.so; install them into ../bin by rename.
set -euo pipefail
API=$(readlink -f "${1:?usage: build_linux_portable.sh <extension_api.json>}")
HERE=$(cd "$(dirname "$0")" && pwd)
RUN=$(command -v podman || command -v docker) || { echo "needs podman or docker" >&2; exit 1; }
CPP=$(readlink -f "$HERE/godot-cpp")
[ -f "$CPP/SConstruct" ] || { echo "no godot-cpp at $HERE/godot-cpp" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$HERE/src" "$HERE/SConstruct" "$WORK/"
mkdir "$WORK/godot-cpp"
if git -C "$CPP" rev-parse --git-dir > /dev/null 2>&1; then
	(cd "$CPP" && git archive HEAD) | tar -x -C "$WORK/godot-cpp"    # its tracked files only: no other build's objects
else
	cp -r "$CPP/." "$WORK/godot-cpp/"
	rm -rf "$WORK/godot-cpp/bin" "$WORK/godot-cpp/gen"
fi
cp "$API" "$WORK/extension_api.json"
"$RUN" run --rm -v "$WORK:/w" -w /w docker.io/library/ubuntu:20.04 bash -euc '
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq g++-10 python3-pip > /dev/null
	ln -sf /usr/bin/g++-10 /usr/local/bin/g++
	ln -sf /usr/bin/gcc-10 /usr/local/bin/gcc
	pip3 install -q scons
	for t in template_debug template_release; do
		scons -j"$(nproc)" target=$t custom_api_file=/w/extension_api.json
	done'
mkdir -p "$HERE/bin"
for t in template_debug template_release; do
	so="libwuifwoud_core.linux.$t.x86_64.so"
	cp "$WORK/bin/$so" "$HERE/bin/$so"
	echo "$so: needs glibc $(objdump -T "$HERE/bin/$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
done
