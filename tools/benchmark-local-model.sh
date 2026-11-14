#!/bin/bash
set -euo pipefail

# Build the app first with xcodebuild -derivedDataPath "$1".
# Usage: bash tools/benchmark-local-model.sh DERIVED_DATA MODEL.gguf OUTPUT.json
if [[ $# != 3 ]]; then
  echo "Usage: $0 DERIVED_DATA MODEL.gguf OUTPUT.json" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="$1/Build/Products/Debug"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/translator-benchmark.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
  -I "$PRODUCTS" -F "$PRODUCTS" -framework llama \
  -Xlinker -rpath -Xlinker "$PRODUCTS" \
  "$ROOT/AITranslator/Services/LlamaInference.swift" \
  "$ROOT/AITranslator/Services/LocalTranslationPrompt.swift" \
  "$ROOT/AITranslator/Services/AppLogger.swift" \
  "$ROOT/tools/TranslationBenchmark.swift" \
  -o "$WORK/translation-benchmark"

"$WORK/translation-benchmark" "$2" "$ROOT/tools/translation-samples.json" "$3"
