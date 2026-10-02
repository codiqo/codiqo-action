#!/usr/bin/env bash
#
# Install a pinned Apache Maven and put it first on PATH.
#
# The runner image's Maven moves whenever the image is rebuilt, so the same commit could be built
# by one Maven today and another next week. Pinning it keeps a commit's build reproducible across
# runs. The forked per-commit build inherits it too: without an explicit maven-home the plugin
# starts the fork from the host Maven's own maven.home.
#
# The archive comes from Maven Central rather than the Apache download CDN, which only keeps the
# latest releases and drops a pinned version once it is superseded. Its SHA-512 is checked against
# the checksum Central publishes beside it.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

version="${CODIQO_IN_MAVEN_VERSION:?}"
case "$version" in
    *[!0-9A-Za-z.-]* | '' | -* | .*)
        codiqo::die "maven-version '$version' is not a Maven version such as 3.10.0."
        ;;
esac

#
# The tool cache persists on a self-hosted runner, so a second run reuses the install. On a
# hosted runner it is simply an empty directory.
#
install_root="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/codiqo-maven/$version"
maven_home="$install_root/apache-maven-$version"

if [ -x "$maven_home/bin/mvn" ]; then
    codiqo::log "reusing Maven $version from $maven_home."
else
    base="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$version"
    archive="apache-maven-$version-bin.tar.gz"
    download_dir="$CODIQO_WORK_DIR/maven-download"
    mkdir -p "$download_dir" "$install_root"

    codiqo::log "downloading Maven $version from Maven Central."
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/$archive" "$base/$archive"; then
        codiqo::die "could not download $base/$archive. Check maven-version: it must be a released version present on Maven Central."
    fi
    curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/$archive.sha512" "$base/$archive.sha512" \
        || codiqo::die "could not download the checksum for $archive."

    #
    # Central's .sha512 holds the bare digest, with no file name, so it is compared directly
    # rather than fed to `sha512sum -c`.
    #
    expected=$(tr -d '[:space:]' < "$download_dir/$archive.sha512" | cut -c1-128)
    if command -v sha512sum > /dev/null 2>&1; then
        actual=$(sha512sum "$download_dir/$archive" | cut -d' ' -f1)
    else
        actual=$(shasum -a 512 "$download_dir/$archive" | cut -d' ' -f1)
    fi
    if [ "$expected" != "$actual" ]; then
        codiqo::die "SHA-512 mismatch for $archive: expected $expected, got $actual."
    fi

    tar -xzf "$download_dir/$archive" -C "$install_root"
    rm -rf "$download_dir"
    if [ ! -x "$maven_home/bin/mvn" ]; then
        codiqo::die "the Maven $version archive did not contain bin/mvn."
    fi
    codiqo::log "installed Maven $version to $maven_home."
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$maven_home/bin" >> "$GITHUB_PATH"
fi
codiqo::export MAVEN_HOME "$maven_home"

#
# A project wrapper still wins under maven-command: auto, because a historical commit should be
# built by the Maven it pinned. Say so, rather than leave the installed version looking unused.
#
if [ "${CODIQO_BUILD_CMD:-}" = "./mvnw" ]; then
    codiqo::log "the project ships ./mvnw, which still runs the build; Maven $version is on PATH but unused by it."
fi

"$maven_home/bin/mvn" --version
