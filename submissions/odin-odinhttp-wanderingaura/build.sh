#!/usr/bin/env bash
# Clones odin http into the directory as a build dep and builds the server.
set -euo pipefail
cd "$(dirname "$0")"

ODIN_HTTP_REV=fac113fbd828aad3d71479a534b5de4358b6a07b
DEPS=.deps/odin-http

if [ ! -d "$DEPS/.git" ]; then
    rm -rf "$DEPS"
    mkdir -p "$(dirname "$DEPS")"
    git clone --quiet https://github.com/laytan/odin-http.git "$DEPS"
fi
git -C "$DEPS" fetch --quiet origin "$ODIN_HTTP_REV" 2>/dev/null || true
git -C "$DEPS" checkout --quiet --force "$ODIN_HTTP_REV"

mkdir -p bin
odin build . -collection:http="$DEPS" -o:speed -disable-assert -no-bounds-check -out:bin/server
