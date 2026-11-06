# transcribe.cpp — Windows x64 server for multilingual speech models

Ready-to-run [transcribe.cpp](https://github.com/anomalyco/transcribe.cpp)
builds for Windows x64, packaged as one small HTTP server per backend.
transcribe.cpp carries model families whisper.cpp does not — Qwen3-ASR first —
so a dictation app can offer a multilingual choice beside its Whisper models
without changing its pipeline.

These are builds of pinned transcribe.cpp sources with the Vulkan backend
turned on. Two single executables, statically linked against the MSVC runtime,
no redistributable required.

## Why

Whisper models load from whisper.cpp; Qwen3-ASR is a different architecture,
and whisper.cpp does not know it. transcribe.cpp does, on the same ggml
foundation. The server speaks the same small contract whisperlane's supervisor
already drives, so the engine family is a runtime pin rather than a pipeline.

Measured on an **AMD Radeon RX 7700 XT** with Qwen3-ASR 0.6B Q8_0, 16 kHz mono
clips of 4 to 11 seconds:

| Backend | Warm inference | Working set |
| --- | ---: | ---: |
| Vulkan | 0.12–0.20 s | ~114 MB |
| CPU | 0.9–1.9 s | ~278 MB |

The first inference after a launch pays a one-time Vulkan pipeline compile
(about 3.8 s on the machine above). Later takes are warm.

## Contract

```
transcribe-server.exe --model <file.gguf> --host 127.0.0.1 --port 8811 [--language tr]
```

- `GET /` answers `200` when the engine is ready.
- `POST /inference` and `POST /v1/audio/transcriptions` take a multipart body
  with `file` (WAV), `response_format=json`, and `language`, and answer
  `{"text": "..."}`.
- The startup line states the backend that actually bound the model, for
  example `transcribe-server backend=vulkan device="AMD Radeon RX 7700 XT" ...`.

WAV input may be any sample rate or channel count; the server mixes to mono and
resamples to 16 kHz. `language` may be omitted or `auto` to detect.

## Downloads

Grab the latest zip from [Releases](../../releases). Files are named
`transcribe-vulkan-win-x64-<revision>.zip`.

Verify before you run it:

```powershell
Get-FileHash transcribe-vulkan-win-x64-*.zip -Algorithm SHA256
```

Compare against `SHA256SUMS.txt` on the same release page.

> **Requires an AVX2 CPU** (roughly 2013 or newer), the same baseline the
> whisper builds use.

> **Requires a Vulkan driver for the accelerated build.** AMD Adrenalin,
> Intel's Windows driver, and NVIDIA's driver all ship one. The processor
> build has no such requirement.

## What is in the zip

```
transcribe-server.exe       HTTP server with the Vulkan backend
transcribe-server-cpu.exe   HTTP server with the processor backend
```

No `transcribe.dll`, no `ggml*.dll`, and no Visual C++ runtime DLLs. A clean
machine can unpack the zip and run either executable.

## Models

Not bundled. Any GGUF for an architecture transcribe.cpp supports will load.
The model this repository exists for is pinned:

| | |
| --- | --- |
| File | `Qwen3-ASR-0.6B-Q8_0.gguf` |
| Source | `huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf` |
| Revision | `e4e16599b900eb0cb36e524514756bb92eb092b7` |
| Bytes | 850,423,456 |
| SHA-256 | `f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8` |
| License | Apache-2.0 (base `Qwen/Qwen3-ASR-0.6B`; GGUF conversion by handy-computer) |

**Pass `--language` explicitly.** With no hint the model auto-detects, which
costs a little more and can guess; `--language tr`, `--language en`, and so on
are exact.

## Building it yourself

On Windows:

1. Install [CMake](https://cmake.org/download/), the
   [Vulkan SDK](https://vulkan.lunarg.com/sdk/home), Visual Studio 2022 with the
   C++ tools, and Rust 1.99.1 (the repository pins it in `rust-toolchain.toml`).
2. Run the build script:

```powershell
.\build.ps1 -SmokeModel .\dist\smoke.gguf
```

It builds both backends, verifies the import tables, smoke-launches each
executable, and stages the two files in `dist\runtime`. The same script is what
CI runs, so a local success and a release build mean the same thing.

Two details are easy to miss, and the script handles both:

- The Rust binding emits `vulkan-1` as a link library without a search path;
  the SDK's `Lib` directory must be on `LIB`, or the link fails on
  `vulkan-1.lib`.
- The CMake build defaults to the DLL runtime; it is pinned to the static one
  so both halves of the executable agree.

See `.github/workflows/build.yml` for the release sequence.

## License

The server code in this repository is MIT-licensed. transcribe.cpp is
MIT-licensed; these are builds of its sources. Model weights are separate
downloads under their own licenses; the Qwen3-ASR file above is Apache-2.0.
