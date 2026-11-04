#!/usr/bin/env bash
# Writes the checksums the hex package ships, from a published release:
#
#   priv/host.sha256                    the precompiled hosts (host.yml)
#   checksum-Elixir.Baguette.Native.exs the precompiled NIFs (nif.yml)
#
# Run from the repository root once `release.yml` has published the tag's
# GitHub release. The release workflow's `hex` job runs it before
# `mix hex.publish`.
#
# Requires: gh (authenticated), sha256sum, mix with the project's deps, and
# Rust: with no NIF checksums yet, compiling Baguette.Native builds the NIF
# from source.
#
#   scripts/release-checksums.sh v0.1.0
set -euo pipefail

tag=${1:?usage: release-checksums.sh <tag, e.g. v0.1.0>}
version=$(sed -n 's/^  @version "\(.*\)"/\1/p' mix.exs)
[ "$tag" = "v$version" ] || {
  echo "release-checksums: tag $tag is not mix.exs's version v$version" >&2
  exit 1
}

hosts=$(mktemp -d)
trap 'rm -rf "$hosts"' EXIT
gh release download "$tag" --pattern 'baguette_host-*.tar.gz' --dir "$hosts"
ls "$hosts"/*.tar.gz >/dev/null 2>&1 || {
  echo "release-checksums: release $tag has no baguette_host-* assets" >&2
  exit 1
}

{
  grep '^#' priv/host.sha256
  (cd "$hosts" && sha256sum -- *.tar.gz)
} >"$hosts/host.sha256"
mv "$hosts/host.sha256" priv/host.sha256
echo "release-checksums: pinned $(grep -vc '^#' priv/host.sha256) hosts in priv/host.sha256"

rm -f checksum-Elixir.Baguette.Native.exs
mix rustler_precompiled.download Baguette.Native --all --print
test -s checksum-Elixir.Baguette.Native.exs
