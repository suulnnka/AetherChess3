#!/bin/bash
# 构建 wasm 并部署到 web 布局(wasm/chess.wasm,与 AetherChess 项目同构)
set -euo pipefail
cd "$(dirname "$0")/.."
zig build-exe src/wasm.zig -O ReleaseFast -target wasm32-freestanding \
  -fstrip -fno-entry -rdynamic -femit-bin=wasm/chess.wasm
echo "wasm/chess.wasm: $(stat -c%s wasm/chess.wasm)B raw, $(gzip -9 -c wasm/chess.wasm | wc -c)B gzip"
