# Redis CLI — Static Binaries

This repository builds and distributes standalone, **statically linked
`redis-cli`** binaries for Linux and macOS, and publishes them — together with a
`curl | sh` installer — to `packages.redis.io`.

## Why

`redis-cli` is often wanted on its own — on a laptop, a CI runner, an app
container, or a jump host — without installing or building the whole Redis
server, and without a package that also pulls in `redis-server`. Existing
options each have friction:

- **Distro packages** (`apt`/`dnf`) are often outdated, tie the client version
  to the server package, and need root.
- **Building from source** requires a toolchain and pulls all of Redis.
- **Docker** isn't always available or appropriate for a one-off client.

A single static binary solves this: it has **no runtime dependencies** (no libc
or OpenSSL to match on Linux; no Homebrew/OpenSSL on macOS), runs on any distro
including minimal/container images, and installs in one command. Versions are
pinnable via a stable URL, matching how Redis already ships source tarballs.

## Features

- **Platforms**: Linux `amd64`/`arm64`, macOS `amd64`/`arm64`.
- **Fully static on Linux** (musl) — runs on any distribution, including
  Alpine, Amazon Linux, and distroless/minimal images.
- **TLS built in** (`--tls`, `rediss://`) via statically linked OpenSSL.
- **One-command install**, SHA-256 verified, needing only `curl`/`wget`
  (no `tar`/`gzip`, so it works on the most minimal images).
- **Version pinning** via a stable, immutable per-version URL.
- Built from released Redis source; the binary reports the true Redis version.

## Installation

### Latest stable

```sh
curl -fsSL https://packages.redis.io/redis-cli/install.sh | sh
```

### A specific version

```sh
curl -fsSL https://packages.redis.io/redis-cli/install.sh | REDIS_CLI_VERSION=8.4.4 sh
```

### Direct download (version-pinned, no installer)

```sh
curl -fsSL https://packages.redis.io/redis-cli/8.4.4/redis-cli-8.4.4-linux-amd64 -o redis-cli
chmod +x redis-cli
```

Installer environment overrides: `REDIS_CLI_VERSION` (a version, or
`stable`/`latest`; default `stable`), `REDIS_CLI_INSTALL_DIR` (default
`/usr/local/bin`, else `~/.local/bin`), `REDIS_CLI_BASE_URL`.

## Prerequisites (for building)

- **Docker** — for the Linux (musl/Alpine) builds.
- **macOS host with `brew install openssl@3`** — for the macOS builds
  (macOS binaries can only be built on macOS).

## Building locally

```sh
# macOS
./build.sh --version 8.4.4 --os darwin --arch arm64

# Linux (fully static via Alpine/Docker; cross-arch uses QEMU)
./build.sh --version 8.4.4 --os linux --arch amd64
./build.sh --version 8.4.4 --os linux --arch arm64
```

`--version` is any Redis tag (e.g. `8.4.4`) or branch (e.g. `unstable`).
Output (raw stripped binary + checksum) lands in `dist/`:

```
dist/redis-cli-8.4.4-darwin-arm64
dist/redis-cli-8.4.4-darwin-arm64.sha256
```

## Publishing

```sh
./publish.sh --version 8.4.4 \
  --bucket <bucket> --base-url https://packages.redis.io \
  --prefix redis-cli --make-latest [--profile <aws-profile>]
```

Produces, under the bucket:

```
<prefix>/<version>/redis-cli-<version>-<os>-<arch>(.sha256)   # immutable
<prefix>/install.sh                                           # base URL baked in
<prefix>/stable, <prefix>/latest                              # version pointers
```

## Project Structure

```
.
├── README.md                 # This file
├── LICENSE
├── build.sh                  # Fetch a Redis version + build one static target
├── publish.sh                # Upload artifacts + install.sh to S3
├── install.sh                # End-user installer (curl | sh)
├── test-distros.sh           # Docker smoke tests across many distros
├── .redis_version            # Default Redis version to build
└── .github/
    └── workflows/
        ├── build-and-test.yml         # Reusable: build all targets + smoke test
        ├── pull-request.yml           # On PR: build & test (uses .redis_version)
        ├── release_build_and_test.yml # Dispatch: build & test a release
        └── release_publish.yml        # Dispatch: build & publish (public/internal)
```

## CI

Matching `redis-debian`/`redis-rpm`, releases are driven by two
`workflow_dispatch` workflows that reuse a common build workflow:

| Workflow | Purpose |
| -------- | ------- |
| `release_build_and_test.yml` | Build all four targets and smoke-test them (no publish). |
| `release_publish.yml` | Build, then publish. `release_type: internal` → staging bucket at its S3 URL; `release_type: public` → production bucket served at `https://packages.redis.io`. After publishing it runs `test-distros.sh` against the just-published artifacts (amd64 + arm64) as a smoke test. |

Both accept a `release_tag` (defaults to `.redis_version`). Publishing to the
public channel moves the `stable`/`latest` pointers only when `make_latest` is
set. Required configuration is documented in `release_publish.yml`
(`secrets.AWS_ROLE_ARN`, `vars.AWS_REGION`, bucket vars).

## Versioning

The version **is** the Redis version — this repo adds no numbering of its own.
Each build is published under an immutable, version-pinned path; `stable` and
`latest` are moving pointers to the newest promoted stable release
(`stable` matches the `download.redis.io` naming, `latest` the Docker one).
Pre-releases (e.g. `8.8-rc1`) are installable by exact version but never move
`stable`.

## Notes

- **Source integrity (optional)**: pass `build.sh --sha256 <hash>` to verify the
  downloaded Redis source tarball before building; a mismatch aborts. Omitted by
  default (no checksum is stored in the repo).
- The installer uses HTTPS and verifies a SHA-256 checksum. `curl` and GNU
  `wget` validate TLS certificates; BusyBox `wget` does not. Checksums protect
  against corruption, not a determined MITM — artifact signing
  (cosign/minisign) would be the next step if required. Not implemented today.
- macOS `amd64` requires an Intel runner (`macos-14-large`); arm64 builds on
  `macos-14-xlarge`.
