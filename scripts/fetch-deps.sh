#!/bin/sh
# Fetches the sherpa-onnx static library and the ReazonSpeech model at pinned versions.
# The library must match Sources/CSherpaOnnx/include/c-api.h (same release), or the C structs drift.
set -eu
cd "$(dirname "$0")/.."
SHERPA_VERSION=v1.13.8
MODEL=sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01
MODEL_JA_EN=sherpa-onnx-zipformer-ja-en-reazonspeech-2025-01-17
WHISPER_BUILD=b5454
WHISPER_SHA256=e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
KOTOBA=models/kotoba-whisper-v2.0/ggml-kotoba-whisper-v2.0-q5_0.bin
KOTOBA_SHA256=4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658
BASE=https://github.com/k2-fsa/sherpa-onnx/releases/download

# Everything is fetched into temp paths and moved into place only once verified, so an existing
# install survives a failed run. mktmp drops the previous temp dir and the trap removes the last on
# any exit. TMP is always quoted (TMPDIR may contain spaces), and mktmp is not called via $(...)
# so TMP is set in this shell.
TMP=""
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM
mktmp() { [ -n "$TMP" ] && rm -rf "$TMP"; TMP=$(mktemp -d "${1:-${TMPDIR:-/tmp}}/.unazc-fetch.XXXXXX"); }

if [ ! -f vendor/sherpa-onnx/VERSION ] || [ "$(cat vendor/sherpa-onnx/VERSION)" != "$SHERPA_VERSION" ]; then
  mkdir -p vendor
  NAME=sherpa-onnx-$SHERPA_VERSION-osx-arm64-static-no-tts-lib
  mktmp vendor
  curl -fsSL "$BASE/$SHERPA_VERSION/$NAME.tar.bz2" | tar xjf - -C "$TMP"
  echo "$SHERPA_VERSION" > "$TMP/$NAME/VERSION"
  rm -rf vendor/sherpa-onnx
  mv "$TMP/$NAME" vendor/sherpa-onnx
fi
curl -fsSL "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$SHERPA_VERSION/sherpa-onnx/c-api/c-api.h" \
  | cmp -s - Sources/CSherpaOnnx/include/c-api.h \
  || { echo "error: c-api.h does not match sherpa-onnx $SHERPA_VERSION" >&2; exit 1; }

if [ "$(cat vendor/whisper.xcframework/VERSION 2>/dev/null)" != "$WHISPER_BUILD" ]; then
  mktmp
  curl -fsSL -o "$TMP/w.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_BUILD/whisper-$WHISPER_BUILD-xcframework.zip"
  [ "$(shasum -a 256 "$TMP/w.zip" | cut -d' ' -f1)" = "$WHISPER_SHA256" ] || { echo "error: whisper xcframework checksum mismatch" >&2; exit 1; }
  unzip -q "$TMP/w.zip" -d "$TMP"
  rm -rf vendor/whisper.xcframework && mkdir -p vendor
  mv "$TMP/build-apple/whisper.xcframework" vendor/whisper.xcframework
  echo "$WHISPER_BUILD" > vendor/whisper.xcframework/VERSION
fi

# A sherpa-onnx model dir is complete when tokens.txt and the int8 encoder/decoder/joiner exist.
model_ok() {
  [ -s "$1/tokens.txt" ] || return 1
  for part in encoder decoder joiner; do
    ls "$1"/$part-*.int8.onnx >/dev/null 2>&1 || return 1
  done
}
fetch_model() {
  model_ok "models/$1" && return 0
  # Extract into a temp dir and move into place only when complete, so a failed download is retried.
  mkdir -p models
  mktmp models
  curl -fsSL "$BASE/asr-models/$1.tar.bz2" | tar xjf - -C "$TMP"
  model_ok "$TMP/$1" || { echo "error: downloaded model $1 is incomplete" >&2; exit 1; }
  rm -rf "models/$1"
  mv "$TMP/$1" "models/$1"
}
fetch_model "$MODEL"
fetch_model "$MODEL_JA_EN"

if [ ! -f "$KOTOBA" ] || [ "$(shasum -a 256 "$KOTOBA" | cut -d' ' -f1)" != "$KOTOBA_SHA256" ]; then
  mkdir -p "$(dirname "$KOTOBA")"
  mktmp "$(dirname "$KOTOBA")"
  curl -fsSL -o "$TMP/model.bin" "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/$(basename "$KOTOBA")"
  [ "$(shasum -a 256 "$TMP/model.bin" | cut -d' ' -f1)" = "$KOTOBA_SHA256" ] || { echo "error: Kotoba-Whisper checksum mismatch" >&2; exit 1; }
  mv "$TMP/model.bin" "$KOTOBA"
fi
VAD=models/silero_vad.onnx
VAD_SHA256=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6
if [ ! -f "$VAD" ] || [ "$(shasum -a 256 "$VAD" | cut -d' ' -f1)" != "$VAD_SHA256" ]; then
  mktmp models
  curl -fsSL -o "$TMP/vad.onnx" "$BASE/asr-models/silero_vad.onnx"
  [ "$(shasum -a 256 "$TMP/vad.onnx" | cut -d' ' -f1)" = "$VAD_SHA256" ] || { echo "error: silero_vad.onnx checksum mismatch" >&2; exit 1; }
  mv "$TMP/vad.onnx" "$VAD"
fi
echo "deps ok: sherpa-onnx $SHERPA_VERSION, whisper.cpp $WHISPER_BUILD, $MODEL, $MODEL_JA_EN, kotoba-whisper, silero_vad"
