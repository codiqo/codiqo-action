#!/usr/bin/env bash
#
# Install a pinned Node.js for the npm that installs OpenCode, when the image has no npm of its own.
#
# On GitHub the runner image ships Node, and actions/setup-node pins another, so the action never calls
# this. A GitLab job runs in whatever image the template names, and the JDK images it defaults to carry no
# Node; a distribution package is no answer either, since a stable distribution's Node can be older than
# the one OpenCode's installer supports. The official linux tarball is checked against the release's
# SHASUMS256.txt before it is unpacked.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if command -v npm > /dev/null 2>&1; then
    codiqo::log "using the image's npm ($(npm --version)); node-version is not installed."
    exit 0
fi

version="${CODIQO_IN_NODE_VERSION:?}"
case "$version" in
    *[!0-9.]* | '' | .*)
        codiqo::die "node-version '$version' is not a Node.js release such as 24.22.1."
        ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) codiqo::die "no Node.js $version build for $(uname -m); use an image that has npm, or set review: false." ;;
esac

install_root="${CODIQO_TOOL_CACHE:-${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}}/codiqo-node/$version"
name="node-v$version-linux-$arch"
node_home="$install_root/$name"

if [ -x "$node_home/bin/npm" ]; then
    codiqo::log "reusing Node.js $version from $node_home."
else
    base="https://nodejs.org/dist/v$version"
    download_dir="$CODIQO_WORK_DIR/node-download"
    mkdir -p "$download_dir" "$install_root"

    codiqo::log "downloading Node.js $version from nodejs.org."
    curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/$name.tar.gz" "$base/$name.tar.gz" \
        || codiqo::die "could not download $base/$name.tar.gz. Check node-version: it must be a released Node.js version."
    curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/SHASUMS256.txt" "$base/SHASUMS256.txt" \
        || codiqo::die "could not download the checksums of Node.js $version."

    expected=$(awk -v file="$name.tar.gz" '$2 == file { print $1 }' "$download_dir/SHASUMS256.txt")
    if command -v sha256sum > /dev/null 2>&1; then
        actual=$(sha256sum "$download_dir/$name.tar.gz" | cut -d' ' -f1)
    else
        actual=$(shasum -a 256 "$download_dir/$name.tar.gz" | cut -d' ' -f1)
    fi
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        codiqo::die "SHA-256 mismatch for $name.tar.gz: expected ${expected:-nothing}, got $actual."
    fi

    tar -xzf "$download_dir/$name.tar.gz" -C "$install_root"
    rm -rf "$download_dir"
    codiqo::log "installed Node.js $version to $node_home."
fi

codiqo::add_path "$node_home/bin"
codiqo::log "node $("$node_home/bin/node" --version), npm $("$node_home/bin/npm" --version)"
