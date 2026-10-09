#!/usr/bin/env bash
#
# Install a pinned OpenCode CLI for the plugin's local review.
#
# OpenCode 2.x is published to npm as @opencode/cli, with one native binary package per platform
# that the package's postinstall links into place. The older opencode-ai package stops at 1.x and
# GitHub carries 2.x as tags without release assets, so npm is the only prebuilt source of a 2.x
# binary. npm verifies each tarball against the registry's integrity hash.
#
# The install goes into its own prefix rather than the runner's global node_modules, so a pinned
# version never collides with another OpenCode on the image, and the prefix is what the action caches.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

version="${CODIQO_IN_OPENCODE_VERSION:?}"
case "$version" in
    *[!0-9A-Za-z.-]* | '' | -* | .*)
        codiqo::die "opencode-version '$version' is not an OpenCode version such as 2.0.20."
        ;;
esac

install_root="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/codiqo-opencode/$version"
executable="$install_root/bin/opencode"

#
# A restored cache or a self-hosted runner's tool cache may already hold it. Trusted only when the
# binary actually reports the pinned version, so a half-written prefix is reinstalled, not reused.
#
installed_version() {
    # prints "opencode v2.0.20"
    "$executable" --version 2> /dev/null | head -n 1 | awk '{ print $NF }' | sed 's/^v//'
}

if [ -x "$executable" ] && [ "$(installed_version)" = "$version" ]; then
    codiqo::log "reusing OpenCode $version from $install_root."
else
    if ! command -v npm > /dev/null 2>&1; then
        codiqo::die "review: true needs npm to install OpenCode $version, and npm is not on PATH. Add actions/setup-node before this action, or set review: false."
    fi

    rm -rf "$install_root"
    mkdir -p "$install_root"
    codiqo::log "installing @opencode/cli@$version from npm."
    #
    # --ignore-scripts=false overrides a runner-wide ignore-scripts: the postinstall is what moves the
    # platform binary into bin/, and without it the command is an empty placeholder.
    #
    if ! npm install --global --prefix "$install_root" --ignore-scripts=false --no-fund --no-audit \
        "@opencode/cli@$version"; then
        codiqo::die "could not install @opencode/cli@$version from npm. Check opencode-version: it must be a published @opencode/cli version (npm view @opencode/cli versions)."
    fi
fi

actual=$(installed_version || true)
if [ "$actual" != "$version" ]; then
    codiqo::die "the OpenCode install at $executable reports version '${actual:-nothing}', not $version. The platform binary may be missing for $(uname -s)-$(uname -m)."
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$install_root/bin" >> "$GITHUB_PATH"
fi
codiqo::export CODIQO_OPENCODE_EXECUTABLE "$executable"
codiqo::log "OpenCode $version is at $executable."
