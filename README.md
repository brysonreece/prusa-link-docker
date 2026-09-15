# PrusaLink in Docker

A reproducible, multi-arch container image for [PrusaLink](https://github.com/prusa3d/Prusa-Link),
built automatically from upstream releases.

```bash
docker pull ghcr.io/brysonreece/prusalink:latest
```

| Tag | Tracks |
|---|---|
| `:latest` | Newest upstream **release** |
| `:0.8.1`, `:0.8` | A specific release / minor line |
| `:nightly` | Current `master` (upstream's default branch), rebuilt only when it moves — currently `0.8.2`, which upstream has not tagged |
| `:nightly-<sha>` | A specific nightly, for pinning and rollback |

Built for `linux/amd64` and `linux/arm64`.

## Quick start

```bash
git clone https://github.com/brysonreece/prusa-link-docker.git
cd prusa-link-docker

# Find your printer's stable device path
ls -l /dev/serial/by-id/

# Point PRUSALINK_DEVICE at it
cp .env.example .env
$EDITOR .env
```

Set `PUID`/`PGID` in `compose.yaml` to match your user (`id -u`, `id -g`), then:

```bash
docker compose up -d
docker compose logs -f
```

PrusaLink is on `http://<host>:8080`. On first run it shows a setup wizard that
writes `prusa_printer_settings.ini` into `./data`.

## Requirements

- A **Linux** Docker host. `network_mode: host` is a no-op on Docker Desktop for
  macOS and Windows — see [Bridge networking](#bridge-networking-tradeoffs).
- A Prusa printer connected over USB (or UART on a Pi).

## Why the defaults look the way they do

Each of these is a deliberate choice, verified against upstream source.

### `network_mode: host`

Not convenience — correctness. `ip_updater.py` enumerates the host's network
interfaces, finds the one holding the current IP, and reports that address to
Prusa Connect; `service_discovery.py` advertises the same address over mDNS.

Under bridge networking both faithfully report the container's `172.x` address.
Connect's "Open PrusaLink" button then points at an unroutable host, and mDNS
discovery advertises a dead address. Nothing errors and the local UI works
fine, which is what makes this easy to miss. You can watch it happen in the
logs:

```
Our IP has changed, or we reconnected. The new one is 172.17.0.2
Instruction 'M552 P172.17.0.2' enqueued
```

That `M552` pushes the address to the printer's display and onward to Connect.

### No `privileged: true`

`/dev/ttyACM0` is owned `root:dialout` on the host, but the numeric `dialout`
GID is not portable — 20 on Debian, 18 elsewhere, different again on some Pi
images — and only the number is visible inside the container. Rather than
reaching for `privileged`, the entrypoint reads the GID off the device itself
and joins that exact group:

```
[entrypoint] granted /dev/ttyACM0 access via group serialdev20(20)
```

The container runs as a normal user with `no-new-privileges`.

### `/dev/serial/by-id/...` instead of `/dev/ttyACM0`

`ttyACM0` renumbers when USB devices enumerate in a different order after a
reboot, and the printer silently becomes `ttyACM1`. The `by-id` path derives
from the printer's own serial number and never changes. It is mapped *to*
`/dev/ttyACM0` inside the container so the config stays boring.

The path comes from `PRUSALINK_DEVICE` in your `.env` rather than being
hardcoded with a placeholder. Forget to set it and compose tells you what to
do:

```
required variable PRUSALINK_DEVICE is missing a value: set PRUSALINK_DEVICE
to your printer's by-id path - run `ls -l /dev/serial/by-id/` to find it
```

which beats Docker's `no such file or directory` for a path you were supposed
to have replaced.

### `/run/udev:/run/udev:ro`

Required for `port = auto`. PrusaLink matches the `ID_VENDOR_ID` and
`ID_MODEL_ID` udev properties against its supported-printer list; without udev
data those properties are empty and auto-detection finds nothing.

Prefer not to mount it? Set an explicit device path in `config/prusalink.ini`:

```ini
[printer]
port = /dev/ttyACM0
```

### `stop_grace_period: 30s`

PrusaLink only installs a SIGTERM handler on its daemonizing code path. A
container runs it in the foreground, where it handles **SIGINT** instead — so
the image sets `STOPSIGNAL SIGINT`.

That alone is not enough. The clean shutdown enqueues an `M117 PrusaLink
stopped` to the printer's display and waits out a 15-second state-change
timeout if nothing answers, taking around 17 seconds in total. Docker's default
grace period is 10, so the default would `SIGKILL` a perfectly healthy shutdown
two-thirds of the way through.

Using plain `docker run`? Stop it with `docker stop --time 30 prusalink`.

One boundary worth knowing: stopping the container during its first ~6 seconds,
before startup completes, exits with code 130 rather than 0. PrusaLink guards
its startup with `except Exception`, and `KeyboardInterrupt` is a
`BaseException`, so the interrupt reaches top level uncaught. The handler that
exits cleanly only covers the main wait loop, which startup has not reached
yet. Little state exists that early, so the practical impact is minimal -- but
if you script a stop immediately after a start, expect 130.

## Configuration

`config/prusalink.ini` is seeded from a template on first start and **never
rewritten** afterwards. Edit it and restart the container.

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PUID` / `PGID` | `1000` | Ownership of `./data` and `./config` |
| `TZ` | `Etc/UTC` | Container timezone |
| `PRUSALINK_PORT` | `8080` | Web port — **applied only when seeding the config** |
| `PRUSALINK_SERIAL_PORT` | `auto` | Device path — **applied only when seeding the config** |

Everything PrusaLink writes lives in `./data`: uploaded gcode, printer settings,
power-panic state, the PID file.

### Bridge networking tradeoffs

If host networking is unavailable or unwanted:

```bash
docker compose -f compose.bridge.yaml up -d
```

The local web UI works normally on `http://<host>:8080`. **Prusa Connect remote
access will not work**, for the reason described above. Accept that knowingly.

## Building locally

```bash
docker compose -f compose.yaml -f compose.build.yaml up -d --build
```

`PRUSALINK_SPEC` in `compose.build.yaml` must pin a full 40-character commit
SHA. Pinning a branch is what made the previous generation of PrusaLink images
unreproducible; CI enforces this with a regex.

To build a different upstream point:

```bash
docker build \
  --build-arg PRUSALINK_SPEC="prusalink @ git+https://github.com/prusa3d/Prusa-Link.git@<sha>" \
  --build-arg PRUSALINK_VERSION=<version> \
  --build-arg PRUSALINK_REVISION=<sha> \
  -t prusalink:local .
```

## How reproducibility is achieved

1. **The base image is pinned by digest**, not by tag, so `python:3.11-slim-bookworm`
   cannot shift underneath a rebuild.
2. **PrusaLink is pinned to a commit SHA.** A SHA is content-addressed, so this
   is exactly as reproducible as a version pin — the previous generation's
   mistake was pinning a *branch*, not using git.
3. **The build tooling is pinned too.** `pip` and `setuptools` are held at exact
   versions. This is not theoretical: setuptools 82.0.0 removed `pkg_resources`,
   which PrusaLink imports unguarded, so the reflexive
   `pip install --upgrade setuptools` produces an image that dies on the first
   request.
4. **Python 3.11 is a hard ceiling**, forced by PrusaLink's `pydantic==1.10.12`
   pin, whose newest published wheel is `cp311`.
5. **A smoke test in the runtime stage** imports the entire module graph at build
   time. Several modules touch native libraries at import scope rather than
   lazily, so a missing shared library is a daemon that cannot start rather than
   a degraded feature — the test turns that dependency list into an assertion.

## Automation

| Workflow | Trigger | Does |
|---|---|---|
| `watch-upstream.yml` | Daily | Detects a new upstream release and dispatches a build |
| `release.yml` | Dispatch | Builds `:X.Y.Z`, `:X.Y`, `:latest` |
| `nightly.yml` | Daily | Rebuilds `:nightly` only when `master` has actually moved |
| `pr.yml` | Pull request | Builds, boots, and asserts a clean shutdown |
| `build.yml` | Reusable | Multi-arch build and push |

Published state lives in the registry, not in a committed file: "have we built
0.8.1?" is answered by asking GHCR whether that tag exists. No bot commits, no
state file to drift, and deleting a tag makes it rebuild.

`watch-upstream.yml` needs a `DISPATCH_TOKEN` secret (a PAT with `repo` scope),
because events raised with the default `GITHUB_TOKEN` deliberately do not start
further workflow runs. Without it the watcher still runs and tells you which
command to run by hand.

### Forking

Everything is namespaced with `github.repository_owner`, so a fork publishes to
its own GHCR namespace with no edits. You will want to update the image
reference in `compose.yaml`.

## Troubleshooting

**`required variable PRUSALINK_DEVICE is missing a value`** — set it in `.env`
(copy `.env.example`). Find the path with `ls -l /dev/serial/by-id/`.

**`no serial devices found in the container`** — `PRUSALINK_DEVICE` points at a
path that does not exist on the host, so nothing was passed through. Re-check
`ls -l /dev/serial/by-id/`; the value must be the full path, not just the
`usb-...` filename.

**`port = auto but /run/udev is not mounted`** — add the mount, or set an
explicit `port` in `config/prusalink.ini`.

**Printer stuck in an `ERROR` state, `Error when connecting to serial`** —
PrusaLink can see no printer. Confirm the device mapping, and that nothing else
on the host (another PrusaLink, OctoPrint, a serial monitor) holds the port.

**Container exits immediately with a `KeyError`** — you started it with
`--user <uid>` for a UID that has no `/etc/passwd` entry. PrusaLink calls
`getpwuid()` at startup on the foreground path. Use `PUID`/`PGID` instead.

**Files in `./data` are owned by the wrong user** — set `PUID`/`PGID` to match
`id -u` / `id -g`.

## Relationship to upstream

This repository contains only packaging. PrusaLink itself is
[prusa3d/Prusa-Link](https://github.com/prusa3d/Prusa-Link) — report application
bugs there, and packaging bugs here.

It supersedes [donslice/prusa-link-docker](https://github.com/donslice/prusa-link-docker),
which is unmaintained and installs from unpinned git branches.

The reasoning behind each non-obvious choice is recorded in comments next to
the code it explains -- the `Dockerfile`, `docker-entrypoint.sh` and
`compose.yaml` all cite the upstream source line that motivated them.

## License

Packaging in this repository is MIT. PrusaLink itself is distributed by Prusa
Research under its own terms.
