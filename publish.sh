#!/usr/bin/env bash
#
# Publish built redis-cli artifacts (and the install script) to S3.
#
# Copyright (c) 2026-Present, Redis Ltd.
# All rights reserved.
#
# Licensed under your choice of (a) the Redis Source Available License 2.0
# (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
# GNU Affero General Public License v3 (AGPLv3).
#
# Layout produced in the bucket:
#   <prefix>/<version>/redis-cli-<version>-<os>-<arch>          (raw binary)
#   <prefix>/<version>/redis-cli-<version>-<os>-<arch>.sha256
#   <prefix>/install.sh                 (base URL baked in)
#   <prefix>/stable, <prefix>/latest    (version pointers, if --make-latest)
#
# Usage:
#   publish.sh --version V --bucket BUCKET --base-url URL
#              [--prefix PREFIX] [--dist DIR] [--profile NAME] [--make-latest]
#              [--public-read]
#
# For public releases, pass --public-read so uploaded objects are
# world-readable (e.g. served straight from the bucket over HTTP).
#
# Requires the AWS CLI, configured with credentials that can write to BUCKET
# (use --profile NAME to select a named profile, e.g. --profile stage).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION=""; BUCKET=""; BASE_URL=""; PREFIX="redis-cli"
DIST="$SCRIPT_DIR/dist"; MAKE_LATEST=0; PROFILE=""; PUBLIC_READ=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --base-url) BASE_URL="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --dist) DIST="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --make-latest) MAKE_LATEST=1; shift ;;
        --public-read) PUBLIC_READ=1; shift ;;
        -h|--help) sed -n '12,27p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$VERSION" ] || { echo "--version is required" >&2; exit 1; }
[ -n "$BUCKET" ]  || { echo "--bucket is required" >&2; exit 1; }
[ -n "$BASE_URL" ] || { echo "--base-url is required (used to bake install.sh)" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI not found" >&2; exit 1; }

# Named profile for local use; CI leaves this empty and uses OIDC creds.
[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"

S3="s3://${BUCKET}/${PREFIX}"

# Appended (unquoted) to every upload; empty by default. --public-read makes
# objects world-readable for public releases.
ACL=""
[ "$PUBLIC_READ" = "1" ] && ACL="--acl public-read"

echo ">> Uploading artifacts for $VERSION to ${S3}/${VERSION}/"
shopt -s nullglob
artifacts=("$DIST"/redis-cli-"$VERSION"-*)
[ ${#artifacts[@]} -gt 0 ] || { echo "no artifacts for $VERSION found in $DIST" >&2; exit 1; }
for f in "${artifacts[@]}"; do
    echo "   $(basename "$f")"
    aws s3 cp "$f" "${S3}/${VERSION}/$(basename "$f")" $ACL
done

echo ">> Publishing install.sh with base URL ${BASE_URL}/${PREFIX}"
TMP_INSTALL="$(mktemp "${TMPDIR:-/tmp}/install.XXXXXX.sh")"
sed "s|https://DOWNLOAD_BASE_URL_PLACEHOLDER|${BASE_URL}/${PREFIX}|g" \
    "$SCRIPT_DIR/install.sh" > "$TMP_INSTALL"
aws s3 cp "$TMP_INSTALL" "${S3}/install.sh" --content-type "text/x-shellscript" $ACL
rm -f "$TMP_INSTALL"

if [ "$MAKE_LATEST" = "1" ]; then
    # download.redis.io calls the stable-release alias "stable"; docker uses
    # "latest". Publish both, pointing at this version, so either idiom works.
    for alias in stable latest; do
        echo ">> Updating $alias -> $VERSION"
        printf '%s\n' "$VERSION" | aws s3 cp - "${S3}/${alias}" --content-type "text/plain" $ACL
    done
fi

echo ">> Published. Users can install with:"
echo "     curl -fsSL ${BASE_URL}/${PREFIX}/install.sh | sh"
