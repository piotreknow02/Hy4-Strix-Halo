# Hy4-Flash SQ-128 — one-command Podman deploy (AMD Strix Halo 128 GB)

Serves [strata-engine/Hy4-Flash-Strata](https://huggingface.co/strata-engine/Hy4-Flash-Strata)
SQ-128 (Tencent Hy4-Flash 220B-A12B, `strata-hy4` engine, DFly2 speculative decoding,
vision, 128K context) in a rootless Podman container on an AMD Strix Halo
(Ryzen AI Max+ 395), using the official prebuilt image
`ghcr.io/niko1221/strata:0.2.19-rocm-gfx1151`.

One command brings it up; one command tears it down.

```bash
cp .env.sample .env   # optional — every var has a default
./start.sh            # pull image -> run -> container downloads model -> wait healthy
./stop.sh
```

## What's here

| File          | Role                                                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `start.sh`    | One-command entrypoint: preflight → pull image (cached) → run → health-poll.                                                                |
| `stop.sh`     | Stops the container with a 120 s grace period; idempotent.                                                                                  |
| `.env.sample` | Optional overrides — copy to `.env`.                                                                                                        |

There is **no Containerfile** — the vendor publishes ready-made Strata images per
card (here `0.2.19-rocm-gfx1151`, HIP engine for gfx1151); `start.sh` pulls it.
Nothing to build.

The ~181 GB model is **not** baked into the image: the container downloads it
itself on first start (resumable, size + SHA-256 verified) into the `./strata-data`
bind at `Strata-data/models/hy4-flash/`.

## Requirements

- **Podman** (rootless) — `podman --version` ≥ 5.x
- **AMD GPU driver** present: `/dev/kfd` and `/dev/dri/renderD128` exist
- Current user in the **`render`** group — check with `id -nG`
- **128 GiB unified RAM** — the SQ-128 footprint (~113 GB) fits 128 GiB at 128K
  context with zero SSD reads; on less RAM the engine still runs but streams
  experts from SSD (use `MODEL=SQ-96` or `SQ-64` instead)
- **≥ 200 GB free disk** — 181.23 GB of model files (`SQ-128` 113.7 GB +
  `Engram-Q8` 67.6 GB + `Vision` 0.93 GB) plus image and engine headroom
- Outbound HTTPS to **huggingface.co** (model files) and **github.com**
  (the `strata-hy4` shape engine + its signed release feed)
- `curl` on the host

No host Python or `huggingface-cli` needed — the container downloads and
SHA-256-verifies the model itself. No root/sudo is required for the normal
path. Podman runs rootless; GPU access comes from `--group-add keep-groups`
(carries your host `render` group into the container) plus
`--security-opt label=disable` — on SELinux hosts the container policy denies
`mmap` on `/dev/kfd`, which otherwise kills the engine at model load (see
Troubleshooting).

## Quick start

```bash
cp .env.sample .env      # optional
./start.sh
```

First run:

1. Pulls the `ghcr.io/niko1221/strata:0.2.19-rocm-gfx1151` image (anonymous pull).
2. Starts the container; it downloads the ~181 GB model into
   `./strata-data/Strata-data/models/hy4-flash/` (resumable across restarts).
3. Streams the engine log to the terminal and records it in `.hy4.log`.
4. Exits "ready" once `/health` returns 200.

Then:

```bash
curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[0].id'
# -> hy4-flash-sq-128
```

Tear down:

```bash
./stop.sh
```

Re-running `./start.sh` after the first time skips the pull and the download
(files are found by name + size in the data dir) and reaches ready in minutes —
just the model load.

## Configuration

Copy `.env.sample` to `.env` and edit. Precedence (highest first):
**exported shell env → `.env` → `start.sh` defaults.**

| Var              | Default                                    | Meaning                                                        |
| ---------------- | ------------------------------------------ | -------------------------------------------------------------- |
| `IMAGE`          | `ghcr.io/niko1221/strata:0.2.19-rocm-gfx1151` | Strata image tag                                             |
| `CONTAINER_NAME` | `hy4-flash-strata`                         | Container name                                                 |
| `PORT`           | `8080`                                     | Host publish port (container always listens on 8080)           |
| `DATA_DIR`       | `./strata-data`                            | Model + state bind (mounted at `/data`); use an absolute path if you change it |
| `LOG_FILE`       | `./.hy4.log`                               | Engine output log                                              |
| `READY_TIMEOUT`  | `14400`                                    | Seconds to wait for the health endpoint (first start downloads ~181 GB) |
| `FAMILY`         | `hy4-flash`                                | Model family                                                   |
| `MODEL`          | `SQ-128`                                   | `SQ-64` \| `SQ-96` \| `SQ-128` (default; needs 128 GiB RAM)    |
| `CONTEXT`        | *(131072)*                                 | Context length; unset = engine default (128K)                  |
| `VISION`         | *(on)*                                     | Vision shard on by default (`Hy4-Flash-Vision.strata`, 0.93 GB) |
| `KV`             | *(engine default)*                         | KV cache quantisation passthrough                              |
| `PARALLEL`       | *(engine default)*                         | Parallelism passthrough                                        |
| `TUNE`           | *(engine default)*                         | Tuning passthrough                                             |
| `STRATA_SET`     | *(docker preset)*                          | Strata settings set passthrough                                |
| `API_KEY`        | *(unset)*                                  | Unset = no API key (loopback-only server); set it to require `Authorization` on `/v1/*` |

Do **not** set `DRAFTING`: the hy4 family drafter set is `off|dfly2` and DFly2
is the engine default ("natively built in"); the entrypoint's `DRAFTING` values
(`auto|mtp|dflash2|off`) are the Qwen set.

## How it works

By default `start.sh` runs **keyless**: it passes
`strata launch --no-tui --access lan --no-api-key --data-dir /data/Strata-data --family hy4-flash --model SQ-128`
straight through as the container command (the vendor entrypoint execs any
non-`run` CMD unchanged — its own `run` always turns a key on). Because
`strata launch` exits once the server is up (the engine is a detached daemon),
a small keep-alive wrapper inside the container supervises it and replicates
the entrypoint's stop contract. Set `API_KEY` in `.env` and `start.sh` uses
the vendor entrypoint flow instead (env vars → flags, key required on
`/v1/*`). DFly2 drafting, the Vision shard and the 128K context are the engine
defaults — `start.sh` deliberately leaves them unset.

`/data` layout inside the bind:

- `Strata-data/` — models and packs (the three `.strata` files land in `models/hy4-flash/`)
- `state/` — presets (and the API key in keyed mode)
- `install/` — run configs and logs

Keyless mode answers `/v1/*` and `GET /health` without authentication; keyed
mode requires the key on `/v1/*` (never on `/health`, which is what `start.sh`
polls). `podman stop` sends SIGTERM, which both modes translate into
`strata launch --stop` — requests are drained and the model is unloaded
cleanly (hence `--stop-timeout 120`). From image 0.2.17 the container frees
model page-cache itself before load (Ubuntu `systemd-oomd` guard).

## API usage

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "hy4-flash-sq-128",
    "messages": [{"role": "user", "content": "Explain what a KV cache is, briefly."}],
    "max_tokens": 256,
    "temperature": 0.9,
    "top_p": 1.0
  }' | jq -r '.choices[0].message'
```

Recommended sampling from the model card: `temperature 0.9`, `top_p 1.0`,
`top_k` off. Anthropic-compatible apps (Claude Code et al.) use the base URL
`http://127.0.0.1:8080` (no key by default; in keyed mode pass it as the API key).

## Ops

```bash
podman logs -f hy4-flash-strata                        # engine log stream
podman exec hy4-flash-strata strata monitor --once     # live throughput/utilisation
podman exec hy4-flash-strata strata launch --status    # launcher status
```

## Troubleshooting

**First launch takes hours** — the container downloads ~181 GB from huggingface.co
before loading. Watch progress in `.hy4.log` / `podman logs -f`. The download is
resumable: `./stop.sh` + `./start.sh` continues where it left off; partial files
are completed, verified by size + SHA-256.

**`exit 137` on stop** — the model unload was killed before finishing. `start.sh`
already sets `--stop-timeout 120`; if you stopped the container with a shorter
`podman stop -t`, give it the full grace: `podman stop -t 120 hy4-flash-strata`.

**SELinux: `Memory critical error by agent node-0 ... Reason: Memory in use`
at model load** — Fedora's SELinux container policy denies `mmap` on
`/dev/kfd` (`hsa_device_t`) for rootless containers, so HSA queue setup dies
when the engine starts loading the model; the kernel log stays silent (root
cause per [ROCm/ROCm#6182](https://github.com/ROCm/ROCm/issues/6182)).
`start.sh` passes `--security-opt label=disable`, which lifts SELinux
confinement from the container — acceptable here because the port is
loopback-only and there is no API key by default. The `:z` bind suffix stays for
setups that re-enable labeling.

**`engine does not match this computer's graphics card` (exit 3)** — the gfx1151
engine can't see the GPU: `/dev/kfd`/`/dev/dri` not passed or the `render` group
is missing. Check `id -nG` and the `--device`/`--group-add keep-groups` flags.

**Ubuntu: `systemd-oomd` kills the engine during load** — image ≥ 0.2.17 frees
the model page-cache itself before loading (this image is 0.2.19). If you still
see kills, diagnose with `journalctl --user | grep "oomd killed"`; setting
`STRATA_OOMD_ROOM=0` in the container disables the guard.

**HSA `Cannot allocate memory` / memlock pin errors** — the user session's
`memlock` limit is too low for ROCm memory pinning. `start.sh` only warns about
this (it does not block). If the engine actually fails to pin, raise it once
(needs sudo):

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nLimitMEMLOCK=infinity\n' | sudo tee /etc/systemd/system/user@.service.d/10-memlock.conf
sudo systemctl daemon-reload
# then log out and back in
```

**No `/dev/kfd` or `/dev/dri`** — the AMD GPU kernel driver is not loaded. Load it:

```bash
sudo modprobe amdgpu
sudo modprobe kfd
```

## Model speed reference (AMD Strix Halo, Ryzen AI Max+ 395, 128 GB)

| Metric          | Value       |
| --------------- | ----------- |
| Decode          | 51–60 tok/s |
| Prompt processing | ~728 tok/s |

Speed figures from the [model card](https://huggingface.co/strata-engine/Hy4-Flash-Strata).

## Licence

- Model: quantised build of [tencent/Hy4-flash](https://huggingface.co/tencent/Hy4-flash) — Tencent Hy License
- Strata engine / Terminal: MIT
- This recipe: provided as-is, without warranty
