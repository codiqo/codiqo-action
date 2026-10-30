#!/usr/bin/env bash
#
# Give the Eclipse JDT language server a JDK of its own, beside the one that builds the project.
#
# On GitHub the action installs jdtls-java-version with actions/setup-java and never calls this. A GitLab job runs
# in whatever image the template names, and an image chosen for a project that builds only on an older JDK holds
# no Java 25, which the server needs from jdt.ls 1.62.0, the plugin's default. The build keeps the image's JDK;
# the server gets one named explicitly as codiqo.jdtlsJavaHome, so it never depends on which JVM Maven or a Gradle
# daemon happens to run on. That is the image's JDK when it is already jdtls-java-version or newer; otherwise
# Temurin's latest jdtls-java-version build, downloaded from Adoptium, checked against the SHA-256 Adoptium
# publishes for it before it is unpacked, and kept in the tool cache for the next job.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# one setting -XshowSettings:properties prints for a java executable, as the plugin reads it
java_setting() {
    "$1" -XshowSettings:properties -version 2>&1 | sed -n "s/^ *$2 = //p" | head -n 1
}

if [ -n "${CODIQO_IN_JDTLS_JAVA_HOME:-}" ]; then
    codiqo::log "the language server runs on jdtls-java-home, $CODIQO_IN_JDTLS_JAVA_HOME."
    exit 0
fi

release="${CODIQO_IN_JDTLS_JAVA_VERSION:-}"
if [ -z "$release" ]; then
    codiqo::log "jdtls-java-version is empty: the language server runs on the JDK that builds the project."
    exit 0
fi
case "$release" in
    *[!0-9]*) codiqo::die "jdtls-java-version '$release' is not a Java feature release such as 25." ;;
esac

build_java="java"
if [ -n "${CODIQO_IN_JAVA_HOME:-}" ]; then
    build_java="$CODIQO_IN_JAVA_HOME/bin/java"
elif [ -n "${JAVA_HOME:-}" ]; then
    build_java="$JAVA_HOME/bin/java"
fi
build_release="$(java_setting "$build_java" java.specification.version)"
build_release="${build_release#1.}"
case "$build_release" in
    '' | *[!0-9]*) build_release=0 ;;
esac
if [ "$build_release" -ge "$release" ]; then
    home="$(java_setting "$build_java" java.home)"
    codiqo::log "the language server runs on the build's JDK, Java $build_release at $home."
    codiqo::export CODIQO_IN_JDTLS_JAVA_HOME "$home"
    exit 0
fi

case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) codiqo::die "no Temurin $release build for $(uname -m); set jdtls-java-home to a Java $release JDK in the image." ;;
esac
os="linux"
if [ -f /etc/alpine-release ]; then
    os="alpine-linux"
fi

install_root="${CODIQO_TOOL_CACHE:-${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}}/codiqo-jdk/$release-$os-$arch"
download_dir="$CODIQO_WORK_DIR/jdk-download"
mkdir -p "$download_dir" "$install_root"

api="https://api.adoptium.net/v3/assets/latest/$release/hotspot?architecture=$arch&image_type=jdk&os=$os&vendor=eclipse"
codiqo::log "the build's JDK is Java $build_release; looking up Temurin $release for the language server."
if curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/assets.json" "$api"; then
    read -r name link checksum < <(python3 -I - "$download_dir/assets.json" << 'PY'
import json, sys

with open(sys.argv[1]) as assets:
    package = json.load(assets)[0]["binary"]["package"]
print(package["name"], package["link"], package["checksum"])
PY
    )
    jdk_home="$install_root/${name%.tar.gz}"

    if [ -x "$jdk_home/bin/java" ]; then
        codiqo::log "reusing $name from $jdk_home."
    else
        codiqo::log "downloading $name from Adoptium."
        curl -fsSL --retry 3 --retry-delay 5 -o "$download_dir/$name" "$link" \
            || codiqo::die "could not download $link."
        if command -v sha256sum > /dev/null 2>&1; then
            actual=$(sha256sum "$download_dir/$name" | cut -d' ' -f1)
        else
            actual=$(shasum -a 256 "$download_dir/$name" | cut -d' ' -f1)
        fi
        if [ "$checksum" != "$actual" ]; then
            codiqo::die "SHA-256 mismatch for $name: expected $checksum, got $actual."
        fi

        rm -rf "$jdk_home.partial"
        mkdir -p "$jdk_home.partial"
        tar -xzf "$download_dir/$name" -C "$jdk_home.partial" --strip-components=1
        mv "$jdk_home.partial" "$jdk_home"
        codiqo::log "installed $name to $jdk_home."

        # a newer build of the release replaces the cached one, so the job cache keeps a single JDK
        find "$install_root" -mindepth 1 -maxdepth 1 -type d ! -name "$(basename "$jdk_home")" -exec rm -rf {} +
    fi
else
    # an Adoptium outage must not fail every scheduled run while the cache still holds a build of the release
    jdk_home="$(find "$install_root" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' | head -n 1)"
    if [ -n "$jdk_home" ] && [ -x "$jdk_home/bin/java" ]; then
        codiqo::warn "api.adoptium.net did not answer; reusing the cached $(basename "$jdk_home")."
    else
        codiqo::die "could not look up Temurin $release on api.adoptium.net. Set jdtls-java-home to a Java $release JDK in the image, or use an image whose JDK is Java $release or newer."
    fi
fi
rm -rf "$download_dir"

installed_release="$(java_setting "$jdk_home/bin/java" java.specification.version)"
if [ "$installed_release" != "$release" ]; then
    codiqo::die "$jdk_home reports Java ${installed_release:-nothing}, not $release."
fi
home="$(java_setting "$jdk_home/bin/java" java.home)"
codiqo::log "the language server runs on Java $release at $home."
codiqo::export CODIQO_IN_JDTLS_JAVA_HOME "$home"
