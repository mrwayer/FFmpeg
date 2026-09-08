# bottlify/ — the WebAssembly video decoder build

Bottlify infrastructure, not an upstream candidate. It lives on this fork's `bottlify` branch so
that the build runs on this repository's Actions minutes and publishes to this repository's
releases, leaving the consuming project's CI and release list alone.

- `decoder.c` — a narrow, handle-based C API over FFmpeg, original work under MPL-2.0.
- `build-decoder.sh` — configure flags and the link, run inside the pinned image.
- `Dockerfile` — that image: `emscripten/emsdk` at a fixed version plus what FFmpeg's own build
  needs.
- `build.mjs` — the driver. `node bottlify/build.mjs` needs Docker and nothing else, and produces
  `bottlify/out/{video-decoder.wasm,SHA256SUMS,video-decoder.manifest.json}`.

`.github/workflows/bottlify-video-decoder.yml` runs exactly that and publishes the three files as a
release tagged `build-<short sha>`. The consuming project pins those bytes and fetches them; nothing
downstream needs Emscripten.

The FFmpeg being built is this checkout. Neither `--enable-gpl` nor `--enable-nonfree` is passed:
the artifact is FFmpeg under LGPL-2.1-or-later, and the corresponding source is this repository at
the commit named in the manifest.
