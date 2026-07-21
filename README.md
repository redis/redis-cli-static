# Redis CLI — Static Binaries

This repository builds and distributes standalone, **statically linked
`redis-cli`** binaries for Linux and macOS, and publishes them — together with a
`curl | sh` installer — to `packages.redis.io`.

## Why

`redis-cli` is often wanted on its own — on a laptop, a CI runner, an app
container, or a jump host — without building or installing the whole Redis
server. Distro packages are often outdated and need root, building from source
needs a toolchain, and Docker isn't always available for a one-off client. A
single static binary has no runtime dependencies, runs anywhere (including
Alpine and distroless/minimal images), and installs in one command.

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
curl -fsSL https://packages.redis.io/redis-cli/install.sh | REDIS_CLI_VERSION=8.8.0 sh
```

### Direct download (version-pinned, no installer)

```sh
curl -fsSL https://packages.redis.io/redis-cli/8.8.0/redis-cli-8.8.0-linux-amd64 -o redis-cli
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
./build.sh --version 8.8.0 --os darwin --arch arm64

# Linux (fully static via Alpine/Docker; cross-arch uses QEMU)
./build.sh --version 8.8.0 --os linux --arch amd64
./build.sh --version 8.8.0 --os linux --arch arm64
```

`--version` is any Redis tag (e.g. `8.8.0`) or branch (e.g. `unstable`).
Output (raw stripped binary + checksum) lands in `dist/`:

```
dist/redis-cli-8.8.0-darwin-arm64
dist/redis-cli-8.8.0-darwin-arm64.sha256
```

## Publishing

```sh
./publish.sh --version 8.8.0 \
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
    ├── .env                       # Build matrix (BUILD_TARGETS, SMOKE_TEST_ARCHES)
    ├── actions/                   # Composite actions (redis-debian/redis-rpm layout)
    │   ├── parse-env-file/        #   read .github/.env
    │   ├── parse-release-handle/  #   parse the release_handle JSON
    │   ├── update-redis-version/  #   re-pin .redis_version + build.sh SHA on release branch
    │   ├── run-smoke-tests/       #   install + verify across distros (test-distros.sh)
    │   ├── slack-notification/    #   release Slack notifications (no-op if webhook unset)
    │   └── common/slack.sh
    └── workflows/
        ├── cli.yml                    # On PR/push: build & test (uses .redis_version)
        ├── build-n-test.yml           # Reusable: build all targets + smoke test
        ├── release_build_and_test.yml # Dispatch: ensure branch, re-pin, build, emit handle
        └── release_publish.yml        # Dispatch: publish a built release (public/internal)
```

## CI

Matching `redis-debian`/`redis-rpm`, releases are driven by two
`workflow_dispatch` workflows that reuse a common build workflow:

| Workflow | Purpose |
| -------- | ------- |
| `release_build_and_test.yml` | Ensure the `release/<x.y>` branch (via `ensure-release-branch`), re-pin the source (`.redis_version` + `build.sh` `PINNED_*`) for the tag, build all four targets on that branch, smoke-test, and emit a `release_handle` artifact (`release_tag`/`run_id`/`workflow_uuid`/`release_type`). |
| `release_publish.yml` | Take a `release_handle`, verify the release branch, download the binaries built by that run (no rebuild), publish, and emit a `release_info` artifact. `release_type: internal` → staging bucket at its S3 URL; `release_type: public` → production served at `https://packages.redis.io`. Then runs the `run-smoke-tests` action against the published artifacts. |

This is the `redis-oss-release-automation` contract (`workflow_uuid` +
`release_handle` in / `release_info` out), so the shared orchestrator can drive
this repo the same way it drives `redis-debian`/`redis-rpm` — releases run on
`release/<x.y>` branches. Both accept a `release_tag` (defaults to
`.redis_version`).

**Promotion (`stable`/`latest`).** Like docker's `latest` tag / snap's `stable`
channel, these are moving pointers advanced at publish time. A `public` release
moves them automatically; `make_latest: true` forces it for any release (so
staging can rehearse promotion). The orchestrator propagates no promotion flag —
promotion is derived from `release_type` (public ⇒ GA ⇒ promote), matching how
apt/dnf resolve "latest" from the public index.

**Source integrity.** Release builds run `build.sh` with
`REDIS_CLI_REQUIRE_VERIFIED_SOURCE=1`, so building a version whose checksum isn't
pinned **fails** rather than silently skipping verification; `update-redis-version`
re-pins the checksum per release line on the `release/<x.y>` branch.

To exercise a release by hand (e.g. an internal/staging test), run the two
workflows in sequence, passing the handle from the first into the second:

```sh
gh workflow run release_build_and_test.yml -f release_tag=8.8.0 -f release_type=internal
# once it finishes, grab the handle it produced:
run_id=$(gh run list --workflow release_build_and_test.yml -L1 --json databaseId -q '.[0].databaseId')
gh run download "$run_id" -n release_handle -D /tmp/rh
gh workflow run release_publish.yml \
  -f release_type=internal -f release_tag=8.8.0 \
  -f release_handle="$(cat /tmp/rh/result.json)"
```

Authentication is fully OIDC (like `redis-rpm`): the workflow assumes a separate
IAM role per environment — no long-lived access keys. The public role is
`GitHub_OIDC_S3_Upload_RedisCliStatic`. Required repository secrets (`CLI_`
prefix, mirroring `redis-debian`/`redis-rpm`), selected by `release_type`:

| Secret | Purpose |
| ------ | ------- |
| `CLI_S3_IAM_ARN` / `CLI_S3_IAM_ARN_STAGING` | IAM role (OIDC) to assume — public / internal |
| `CLI_S3_BUCKET` / `CLI_S3_BUCKET_STAGING` | Target bucket — public / internal |
| `CLI_S3_REGION` / `CLI_S3_REGION_STAGING` | Bucket region — public / internal |

The key prefix (`redis-cli`) is the same in both buckets; only the bucket
differs, as `redis-debian` keeps the `deb` prefix across environments.

## Versioning

The version **is** the Redis version — this repo adds no numbering of its own.
Each build is published under an immutable, version-pinned path; `stable` and
`latest` are moving pointers to the newest promoted stable release
(`stable` matches the `download.redis.io` naming, `latest` the Docker one).
Pre-releases (e.g. `8.8-rc1`) are installable by exact version but never move
`stable`.

## Notes

- **Source integrity**: the pinned version's source tarball is verified against
  a hard-coded SHA-256 in `build.sh` (`PINNED_SHA256`) before building; bump it
  together with `.redis_version`. Pass `--sha256 <hash>` to verify a different
  `--version`.
- The installer downloads over HTTPS and verifies a SHA-256 checksum, guarding
  against corruption but not a determined MITM; artifact signing would be the
  next step if required.
