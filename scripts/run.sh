#!/usr/bin/env bash
#
# Run the whole analysis in one job: the steps action.yml runs as separate GitHub steps, in the same
# order and under the same conditions, for a CI system without composite actions. The GitLab template
# (gitlab/codiqo.yml) calls it; GitHub never does.
#
# Every CODIQO_IN_* variable is an action input, set by the template with the same default as
# action.yml. GitHub carries what one step exports to the next through files it names; here each step
# is a child process, so this script names those files (CODIQO_ENV_FILE, CODIQO_OUTPUT_FILE,
# CODIQO_PATH_FILE, read by lib.sh) and folds them back into its own environment after every step.
#
#   run.sh          the analysis, then the redaction and the summary
#   run.sh finish   only the redaction, for an after_script reached because the job was cancelled or
#                   ran out of time, which killed the script before it could redact its own logs
#
set -euo pipefail

mode="${1:-run}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#
# On GitLab everything lives under the project directory, the only place its cache and artifacts can
# reach, and stays out of git's sight through .git/info/exclude: the Gradle loop refuses a workspace with
# changes to tracked files, and nothing here may ever look like one.
#
if [ "${GITLAB_CI:-}" = "true" ]; then
    base="${CI_PROJECT_DIR:?}/.codiqo"
else
    base="${RUNNER_TEMP:-/tmp}/codiqo-run"
fi
export CODIQO_LOGS_DIR="$base/logs"
export CODIQO_WORK_DIR="$base/work"
export CODIQO_TOOL_CACHE="$base/cache/tools"
export CODIQO_ENV_FILE="$CODIQO_WORK_DIR/step-env"
export CODIQO_OUTPUT_FILE="$CODIQO_WORK_DIR/step-output"
export CODIQO_PATH_FILE="$CODIQO_WORK_DIR/step-path"
export CODIQO_SUMMARY_FILE="$CODIQO_LOGS_DIR/summary.md"
finished_marker="$CODIQO_WORK_DIR/finished"

# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

#
# What a step exported, put on PATH or reported, read back after it ends. Each file is emptied once read,
# so a value is applied once and PATH does not grow a duplicate entry per step.
#
codiqo::absorb_step() {
    local line key
    if [ -s "$CODIQO_ENV_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            key="${line%%=*}"
            case "$key" in '' | *[!A-Za-z0-9_]*) continue ;; esac
            export "$key=${line#*=}"
        done < "$CODIQO_ENV_FILE"
        : > "$CODIQO_ENV_FILE"
    fi
    if [ -s "$CODIQO_PATH_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] && export PATH="$line:$PATH"
        done < "$CODIQO_PATH_FILE"
        : > "$CODIQO_PATH_FILE"
    fi
}

# the last value a step reported for an output, or nothing
codiqo::step_output() {
    if [ -f "$CODIQO_OUTPUT_FILE" ]; then
        awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$CODIQO_OUTPUT_FILE"
    fi
}

codiqo::step() {
    local title="$1" script="$2"
    codiqo::log ""
    codiqo::log "--- $title"
    "$here/$script"
    codiqo::absorb_step
}

#
# The tools the scripts call that a slim JDK image may lack. A missing one is installed with the image's
# package manager when the job runs as root, which is the default for a GitLab job's container, and is
# otherwise named in the error, since a step would fail on it later with a far less useful message.
#
codiqo::require_tools() {
    local missing=() tool
    for tool in git python3 curl tar gzip; do
        command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    if [ "$(id -u)" = "0" ]; then
        codiqo::log "installing ${missing[*]}, which the image lacks."
        if command -v apt-get > /dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null \
                && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" ca-certificates > /dev/null
        elif command -v apk > /dev/null 2>&1; then
            apk add --no-cache "${missing[@]}" ca-certificates bash > /dev/null
        elif command -v microdnf > /dev/null 2>&1; then
            microdnf install -y "${missing[@]}" > /dev/null
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y -q "${missing[@]}" > /dev/null
        fi
    fi
    for tool in "${missing[@]}"; do
        command -v "$tool" > /dev/null 2>&1 \
            || codiqo::die "the job image has no $tool, and it could not be installed. Use an image that has git, python3, curl, tar and gzip."
    done
}

#
# The logs leave the job as an artifact, which nothing masks, so every secret the job holds is scrubbed
# from them first. When the redaction cannot run, the logs are removed rather than published as they are.
#
codiqo::redact() {
    local rc=0
    if [ ! -d "$CODIQO_LOGS_DIR" ]; then
        return 0
    fi
    CODIQO_SETTINGS_XML="${CODIQO_IN_SETTINGS_XML:-}" python3 "$here/redact-logs.py" || rc=$?
    if [ "$rc" -ne 0 ]; then
        codiqo::warn "log redaction failed (exit $rc); removing the logs rather than keeping them unredacted."
        rm -rf "${CODIQO_LOGS_DIR:?}"/*
        printf 'The logs were removed because they could not be redacted.\n' > "$CODIQO_LOGS_DIR/REDACTION-FAILED.txt"
    fi
}

codiqo::finish() {
    local rc="$1"
    trap - EXIT
    set +e
    codiqo::log ""
    codiqo::log "--- Redact secrets from the logs"
    codiqo::redact

    CODIQO_SUMMARY_MISSING="$(codiqo::step_output missing-count)" \
        CODIQO_SUMMARY_ANALYSED="$(codiqo::step_output analysed-count)" \
        CODIQO_SUMMARY_FAILED="$(codiqo::step_output failed-count)" \
        CODIQO_SUMMARY_ABORT="$(codiqo::step_output abort-reason)" \
        CODIQO_IN_LOG_ARTIFACT_NAME="${CODIQO_IN_LOG_ARTIFACT_NAME:-job artifacts}" \
        "$here/summary.sh"
    if [ -s "$CODIQO_SUMMARY_FILE" ]; then
        codiqo::group "Codiqo analysis summary"
        cat "$CODIQO_SUMMARY_FILE"
        codiqo::endgroup
    fi
    : > "$finished_marker"
    exit "$rc"
}

mkdir -p "$CODIQO_LOGS_DIR" "$CODIQO_WORK_DIR" "$CODIQO_TOOL_CACHE"

if [ "$mode" = "finish" ]; then
    if [ -f "$finished_marker" ]; then
        exit 0
    fi
    codiqo::log "the analysis did not finish; redacting the logs it left."
    command -v python3 > /dev/null 2>&1 || codiqo::require_tools
    codiqo::redact
    exit 0
fi

#
# A runner that keeps the build directory between jobs keeps the last run's logs and step files too; the
# artifact must hold this run's only, and a step must never read another run's outputs.
#
rm -rf "${CODIQO_LOGS_DIR:?}" "${CODIQO_WORK_DIR:?}"
mkdir -p "$CODIQO_LOGS_DIR" "$CODIQO_WORK_DIR"
trap 'codiqo::finish $?' EXIT

if codiqo::on_gitlab; then
    if [ -d .git/info ] && ! grep -qx '/.codiqo/' .git/info/exclude 2> /dev/null; then
        printf '/.codiqo/\n' >> .git/info/exclude
    fi
    #
    # The local Maven repository and the language-server download cache live in the home directory, which
    # GitLab's cache cannot reach, so they point into .codiqo/cache, which it can. A directory the image
    # already filled is left alone and simply not cached.
    #
    for pair in "$HOME/.m2/repository:$base/cache/m2-repository" "$HOME/.cache/fetch:$base/cache/fetch"; do
        link="${pair%%:*}"
        target="${pair#*:}"
        mkdir -p "$target" "$(dirname "$link")"
        if [ ! -e "$link" ]; then
            ln -s "$target" "$link"
        fi
    done
    #
    # The plugin builds each historical commit against a private local repository in java.io.tmpdir, seeded with
    # hard links to the cached one's releases. The cached repository lives on the build volume and /tmp in the
    # container's own filesystem, and a hard link cannot cross filesystems, so every seeding copied the whole
    # release set instead. Java's temporary directory goes on the build volume too, outside the cached paths.
    #
    mkdir -p "$base/tmp"
    tmpdir_opt="-Djava.io.tmpdir=$base/tmp"
    if [ -n "${CODIQO_IN_MAVEN_OPTS:-}" ]; then
        export CODIQO_IN_MAVEN_OPTS="$CODIQO_IN_MAVEN_OPTS $tmpdir_opt"
    else
        export MAVEN_OPTS="${MAVEN_OPTS:+$MAVEN_OPTS }$tmpdir_opt"
    fi
fi

codiqo::require_tools

#
# A masked GitLab variable must be a single line, so a settings.xml holding credentials is kept as a File
# variable, whose value is the path of a file the runner writes; the scripts take the content.
#
if [ -n "${CODIQO_IN_SETTINGS_XML:-}" ] && [ -f "${CODIQO_IN_SETTINGS_XML}" ]; then
    CODIQO_IN_SETTINGS_XML="$(cat "${CODIQO_IN_SETTINGS_XML}")"
    export CODIQO_IN_SETTINGS_XML
fi

#
# What action.yml computes from its expressions rather than passing straight through.
#
if [ -n "${CODIQO_API_KEY:-}" ]; then
    export CODIQO_IN_HAS_API_KEY=true
else
    export CODIQO_IN_HAS_API_KEY=false
fi
if [ "${CODIQO_IN_BUILD_TOOL:-maven}" = "gradle" ]; then
    export CODIQO_IN_MAVEN_VERSION=""
fi
export CODIQO_DEFAULT_BRANCH="${CODIQO_DEFAULT_BRANCH:-${CI_DEFAULT_BRANCH:-}}"

codiqo::step "Resolve Codiqo configuration" resolve-config.sh

if ! command -v java > /dev/null 2>&1; then
    codiqo::die "the job image has no java. Use a JDK image, Java 21 or newer, such as eclipse-temurin:21-jdk."
fi
java -version 2>&1 | head -n 1

build_tool="${CODIQO_BUILD_TOOL:-maven}"
if [ "$build_tool" != "gradle" ] && [ -n "${CODIQO_IN_MAVEN_VERSION:-}" ]; then
    codiqo::step "Set up Maven ${CODIQO_IN_MAVEN_VERSION}" setup-maven.sh
fi
if [ "$build_tool" != "gradle" ]; then
    codiqo::step "Configure Maven settings" prepare-maven.sh
fi
if [ "${CODIQO_IN_RESOLVE_DEPENDENCIES:-false}" = "true" ] && [ "$build_tool" != "gradle" ]; then
    codiqo::step "Resolve dependencies" resolve-dependencies.sh
fi
if [ "$build_tool" = "gradle" ]; then
    codiqo::step "Prepare the Codiqo Gradle init script" prepare-gradle.sh
fi

codiqo::step "Index commits" index-commits.sh
missing_count="$(codiqo::step_output missing-count)"

if [ "${missing_count:-0}" != "0" ]; then
    if [ "${CODIQO_IN_TIME_MACHINE:-true}" = "true" ] && [ "$build_tool" != "gradle" ]; then
        codiqo::step "Prepare the time-machine host extension" prepare-time-machine.sh
    fi
    if [ "${CODIQO_IN_REVIEW:-true}" = "true" ]; then
        codiqo::step "Set up Node.js for the OpenCode install" setup-node.sh
        codiqo::step "Set up OpenCode ${CODIQO_IN_OPENCODE_VERSION:-}" setup-opencode.sh
    fi
    codiqo::step "Submit commit analyses" submit-analyses.sh
fi
