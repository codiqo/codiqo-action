#!/usr/bin/env bash
#
# Validate the environment and normalise every input exactly once, so the later steps are
# straight-line and no shorthand is parsed twice.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

mkdir -p "$CODIQO_WORK_DIR" "$CODIQO_LOGS_DIR"

# ---------------------------------------------------------------- repository preconditions

#
# `[ -d .git ]` is wrong: in a linked worktree or a submodule .git is a *file*. Ask git.
#
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    codiqo::die "no git repository in $(pwd). Add actions/checkout with fetch-depth: 0 before this action."
fi

if ! git rev-parse --verify HEAD > /dev/null 2>&1; then
    codiqo::die "the repository has no commits at HEAD, so there is nothing to analyse."
fi

#
# A shallow or filtered clone is the single most common cause of a run that reports success
# while analysing nothing: index-commits drops any sha whose commit or first parent is
# missing locally, so the missing-analyses file comes back empty.
#
shallow=$(git rev-parse --is-shallow-repository 2> /dev/null || echo "false")
partial=$(git config --get remote.origin.partialclonefilter 2> /dev/null || true)
if [ "$shallow" = "true" ] || [ -n "$partial" ]; then
    detail="shallow=$shallow partial-filter=${partial:-none}"
    if [ "${CODIQO_IN_REQUIRE_FULL_HISTORY:-true}" = "true" ]; then
        codiqo::die "this repository has incomplete history ($detail). Codiqo needs full history to walk commits — set fetch-depth: 0 on actions/checkout, or set require-full-history: false to proceed anyway."
    fi
    codiqo::warn "repository history is incomplete ($detail); commits whose parent is missing locally will be skipped silently."
fi

# ---------------------------------------------------------------------------- commit window

case "${CODIQO_IN_COMMIT_WINDOW:-3m}" in
    0) commit_window="P0D" ;;
    1m) commit_window="P1M" ;;
    3m) commit_window="P3M" ;;
    6m) commit_window="P6M" ;;
    1year) commit_window="P1Y" ;;
    "") commit_window="P3M" ;;
    *) commit_window="${CODIQO_IN_COMMIT_WINDOW}" ;;
esac
case "$commit_window" in
    P*) : ;;
    *) codiqo::die "commit-window '${CODIQO_IN_COMMIT_WINDOW}' is neither a known shorthand (0, 1m, 3m, 6m, 1year) nor an ISO-8601 period such as P2W." ;;
esac

# --------------------------------------------------------------------------------- timeouts

#
# Sets CODIQO_MINUTES. Must not be called inside $(...): codiqo::die exits, and in a
# subshell that would only end the subshell, leaving the caller with an empty value.
#
codiqo::_require_minutes() {
    case "$1" in
        '' | *[!0-9]*) codiqo::die "$2 must be a known shorthand or a positive whole number of minutes, got '$1'." ;;
    esac
    if [ "$1" -le 0 ]; then
        codiqo::die "$2 must be greater than zero, got '$1'."
    fi
    CODIQO_MINUTES="$1"
}

per_commit_raw="${CODIQO_IN_PER_COMMIT_TIMEOUT:-}"
if [ -z "$per_commit_raw" ] && [ -n "${CODIQO_IN_PER_COMMIT_TIMEOUT_MINUTES:-}" ]; then
    codiqo::warn "per-commit-timeout-minutes is deprecated; use per-commit-timeout (accepts 30m, 1h, 90m, 2h or raw minutes)."
    per_commit_raw="${CODIQO_IN_PER_COMMIT_TIMEOUT_MINUTES}"
fi
case "${per_commit_raw:-1h}" in
    30m) per_commit_minutes=30 ;;
    1h | '') per_commit_minutes=60 ;;
    90m) per_commit_minutes=90 ;;
    2h) per_commit_minutes=120 ;;
    *)
        codiqo::_require_minutes "$per_commit_raw" "per-commit-timeout"
        per_commit_minutes="$CODIQO_MINUTES"
        ;;
esac

case "${CODIQO_IN_PER_TEST_TIMEOUT:-15m}" in
    off | 0) per_test_minutes=0 ;;
    5m) per_test_minutes=5 ;;
    10m) per_test_minutes=10 ;;
    15m | '') per_test_minutes=15 ;;
    *)
        codiqo::_require_minutes "${CODIQO_IN_PER_TEST_TIMEOUT}" "per-test-timeout"
        per_test_minutes="$CODIQO_MINUTES"
        ;;
esac

#
# The three deadlines nest, and the nesting is load-bearing rather than cosmetic. The outer per-commit
# timeout kills the whole analysis. The build timeout ends one forked build, which is what lets codiqo
# record the commit as a build failure instead of dying with it. The test timeout ends the test phase,
# leaving the build free to finish and report. Each must be able to fire before the one outside it —
# and the outer clock starts first, so an equal pair means the outer one always wins and the graceful
# path is unreachable. Rather than reject the combination, derive each budget from the one around it
# and clamp anything that does not fit: a caller who lowers per-commit-timeout wants a shorter run,
# not a failed one, and every value below is passed explicitly so nothing falls back to a compiled
# default that could reinstate the equality.
#
codiqo::_fit_within() {
    local fitted
    fitted=$(( $1 * 3 / 4 ))
    if [ "$fitted" -lt 1 ]; then
        fitted=1
    fi
    CODIQO_MINUTES="$fitted"
}

codiqo::_fit_within "$per_commit_minutes"
build_ceiling="$CODIQO_MINUTES"
build_timeout_minutes="$build_ceiling"
if [ -n "${CODIQO_IN_BUILD_TIMEOUT_MINUTES:-}" ]; then
    codiqo::_require_minutes "${CODIQO_IN_BUILD_TIMEOUT_MINUTES}" "build-timeout-minutes"
    build_timeout_minutes="$CODIQO_MINUTES"
    if [ "$build_timeout_minutes" -gt "$build_ceiling" ]; then
        codiqo::warn "build-timeout-minutes ${build_timeout_minutes}m leaves no room under the ${per_commit_minutes}m per-commit deadline; using ${build_ceiling}m so a fork timeout can still be reported as a build failure."
        build_timeout_minutes="$build_ceiling"
    fi
fi

codiqo::_fit_within "$build_timeout_minutes"
test_ceiling="$CODIQO_MINUTES"
test_timeout_minutes="${CODIQO_IN_TEST_TIMEOUT_MINUTES:-30}"
codiqo::_require_minutes "$test_timeout_minutes" "test-timeout-minutes"
test_timeout_minutes="$CODIQO_MINUTES"
if [ "$test_timeout_minutes" -gt "$test_ceiling" ]; then
    codiqo::warn "test-timeout-minutes ${test_timeout_minutes}m cannot fire inside a ${build_timeout_minutes}m build; using ${test_ceiling}m so a hung test phase is reaped instead of taking the whole build down."
    test_timeout_minutes="$test_ceiling"
fi

#
# The last rung: half the test budget, which is what the plugin derives for itself when the property
# is absent. The action always passes it, so that derivation never runs here and the ceiling has to be
# applied on this side. `off` stays off.
#
per_test_ceiling=$(( test_timeout_minutes / 2 ))
if [ "$per_test_ceiling" -lt 1 ]; then
    per_test_ceiling=1
fi
if [ "$per_test_minutes" -gt "$per_test_ceiling" ]; then
    codiqo::warn "per-test-timeout ${per_test_minutes}m leaves no room inside a ${test_timeout_minutes}m test phase; using ${per_test_ceiling}m."
    per_test_minutes="$per_test_ceiling"
fi

# ----------------------------------------------------------------------------------- branch

#
# The plugin needs a branch name to attribute the index, and fails on a detached HEAD it
# cannot resolve. `github.ref_name` alone is wrong for pull_request events, where it is
# "<number>/merge" rather than the source branch.
#
branch="${CODIQO_IN_BRANCH:-}"
if [ -z "$branch" ]; then
    case "${GITHUB_EVENT_NAME:-}" in
        pull_request | pull_request_target) branch="${GITHUB_HEAD_REF:-}" ;;
        *)
            case "${GITHUB_REF:-}" in
                refs/heads/*) branch="${GITHUB_REF_NAME:-}" ;;
            esac
            ;;
    esac
fi
if [ -z "$branch" ]; then
    codiqo::log "no branch could be derived from the event; letting the plugin auto-detect."
fi

# -------------------------------------------------------------------------------- build tool

build_tool="${CODIQO_IN_BUILD_TOOL:-maven}"
case "$build_tool" in
    maven | gradle) ;;
    *) codiqo::die "build-tool must be 'maven' or 'gradle', not '$build_tool'." ;;
esac

# ----------------------------------------------------------------------------- build command

if [ "$build_tool" = "gradle" ]; then
    build_command="${CODIQO_IN_GRADLE_COMMAND:-auto}"
    if [ "$build_command" = "auto" ]; then
        #
        # The wrapper is strongly preferred over a PATH gradle: it pins the distribution the project
        # was written against, and analysing a historical commit means running whatever wrapper that
        # commit shipped.
        #
        if [ -x "./gradlew" ]; then
            build_command="./gradlew"
            codiqo::log "using the project's Gradle wrapper (./gradlew)."
        else
            build_command="gradle"
        fi
    fi
    label="gradle command   "
else
    build_command="${CODIQO_IN_MAVEN_COMMAND:-auto}"
    if [ "$build_command" = "auto" ]; then
        if [ -x "./mvnw" ]; then
            build_command="./mvnw"
            codiqo::log "using the project's Maven wrapper (./mvnw)."
        else
            build_command="mvn"
        fi
    fi
    label="maven command    "
fi
if ! command -v "$build_command" > /dev/null 2>&1 && [ ! -x "$build_command" ]; then
    codiqo::die "$label '$build_command' was not found on PATH and is not an executable file."
fi

# --------------------------------------------------------- build arguments and user properties

#
# One argument per line. Whitespace splitting is kept only for a single-line value, so
# `maven-args: '-T 1C -Dfoo=bar'` keeps working while a multi-line value can carry paths
# containing spaces.
#
# Tool-aware for the same reason the properties below are: the two tools do not share a flag
# grammar. `-ntp` is not a Gradle option at all, and `-Pci` is a profile to Maven but a project
# property to Gradle — so passing maven-args to Gradle would either abort the build or silently
# mean something else.
#
args_file="$CODIQO_WORK_DIR/build-args"
: > "$args_file"
if [ "$build_tool" = "gradle" ]; then
    raw_args="${CODIQO_IN_GRADLE_ARGS:-}"
else
    raw_args="${CODIQO_IN_MAVEN_ARGS:-}"
fi
if [ -n "$raw_args" ]; then
    case "$raw_args" in
        *"
"*)
            printf '%s\n' "$raw_args" | while IFS= read -r line; do
                trimmed="${line#"${line%%[![:space:]]*}"}"
                trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
                case "$trimmed" in '' | '#'*) continue ;; esac
                printf '%s\n' "$trimmed" >> "$args_file"
            done
            ;;
        *)
            # shellcheck disable=SC2086 # deliberate word splitting of a single-line value
            for word in $raw_args; do printf '%s\n' "$word" >> "$args_file"; done
            ;;
    esac
fi

#
# key=value per line, split at the FIRST '=' so values may contain '='. Emitted as
# individual -Dkey=value elements so a value containing spaces survives.
#
#
# One file, whichever tool is driving: only one of the two inputs can be in play per run, and the
# only difference downstream is the flag each tool spells its user properties with.
#
props_file="$CODIQO_WORK_DIR/build-props"
: > "$props_file"
if [ "$build_tool" = "gradle" ]; then
    props_input="${CODIQO_IN_GRADLE_PROJECT_PROPERTIES:-}"
    props_label="gradle-project-properties"
    props_flag="-P"
else
    props_input="${CODIQO_IN_MAVEN_USER_PROPERTIES:-}"
    props_label="maven-user-properties"
    props_flag="-D"
fi
if [ -n "$props_input" ]; then
    printf '%s\n' "$props_input" | while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in '' | '#'*) continue ;; esac
        case "$trimmed" in
            *=*) : ;;
            *)
                codiqo::error "$props_label line '$trimmed' is not key=value."
                exit 1
                ;;
        esac
        key="${trimmed%%=*}"
        case "$key" in
            *[[:space:]]* | '')
                codiqo::error "$props_label key '$key' is empty or contains whitespace."
                exit 1
                ;;
        esac
        printf -- '%s%s\n' "$props_flag" "$trimmed" >> "$props_file"
    done
fi

# ------------------------------------------------------------------------------------ exports

codiqo::export CODIQO_WORK_DIR "$CODIQO_WORK_DIR"
codiqo::export CODIQO_LOGS_DIR "$CODIQO_LOGS_DIR"
codiqo::export CODIQO_COMMIT_WINDOW "$commit_window"
codiqo::export CODIQO_PER_COMMIT_TIMEOUT_MINUTES "$per_commit_minutes"
codiqo::export CODIQO_PER_COMMIT_TIMEOUT_SECONDS "$((per_commit_minutes * 60))"
codiqo::export CODIQO_BUILD_TIMEOUT_MINUTES "$build_timeout_minutes"
codiqo::export CODIQO_TEST_TIMEOUT_MINUTES "$test_timeout_minutes"
codiqo::export CODIQO_PER_TEST_TIMEOUT_MINUTES "$per_test_minutes"
codiqo::export CODIQO_BRANCH "$branch"
codiqo::export CODIQO_BUILD_TOOL "$build_tool"
#
# `-` rather than `:-`: the composite action always sets this variable, so an empty value is the
# documented way to analyse without running tests. `:-` would substitute on empty too and quietly
# reinstate `test`, making that opt-out unreachable. Newlines collapse to spaces because the export
# travels through GITHUB_ENV as a single KEY=value line, which a block scalar would break.
#
gradle_tasks=$(printf '%s' "${CODIQO_IN_GRADLE_TASKS-test}" | tr '\n' ' ')
codiqo::export CODIQO_GRADLE_TASKS "$gradle_tasks"
codiqo::export CODIQO_BUILD_CMD "$build_command"
codiqo::export CODIQO_HEARTBEAT_INTERVAL "${CODIQO_IN_HEARTBEAT_INTERVAL:-30}"
codiqo::export CODIQO_TAIL_LINES "${CODIQO_IN_TAIL_LINES:-400}"
codiqo::export CODIQO_MISSING_FILE "$CODIQO_WORK_DIR/missing-analyses.txt"

if [ -n "${CODIQO_IN_MAVEN_OPTS:-}" ]; then
    codiqo::export MAVEN_OPTS "${CODIQO_IN_MAVEN_OPTS}"
fi

# Maven runs the analysis in its own JVM, so an unsized heap is a quarter of the runner's RAM: enough
# for most projects, and a silent OutOfMemoryError in copy-paste detection or diagnostics for a large
# one, which then fails every scheduled run on the same commit.
effective_maven_opts="${CODIQO_IN_MAVEN_OPTS:-${MAVEN_OPTS:-}}"
if [ "$build_tool" = "maven" ] && ! printf '%s' "$effective_maven_opts" | grep -qE -- '-Xmx|MaxRAMPercentage|MaxRAM='; then
    codiqo::warn "MAVEN_OPTS sets no heap limit, so the analysis JVM gets a quarter of this runner's memory. A large project can run out of it; set -Xmx through maven-opts or the job's MAVEN_OPTS."
fi

codiqo::group "resolved codiqo configuration"
codiqo::log "plugin version   : ${CODIQO_IN_VERSION:-unset}"
codiqo::log "api url          : ${CODIQO_IN_API_URL:-default}"
codiqo::log "build tool       : $build_tool"
codiqo::log "$label: $build_command"
codiqo::log "branch           : ${branch:-<auto-detect>}"
codiqo::log "commit window    : $commit_window"
codiqo::log "per-commit limit : ${per_commit_minutes}m"
codiqo::log "build limit      : ${build_timeout_minutes}m"
codiqo::log "test limit       : ${test_timeout_minutes}m"
codiqo::log "per-test limit   : ${per_test_minutes}m (0 = disabled)"
codiqo::log "extra args       : $(wc -l < "$args_file" | tr -d ' ') line(s)"
codiqo::log "user properties  : $(wc -l < "$props_file" | tr -d ' ') line(s)"
codiqo::endgroup
