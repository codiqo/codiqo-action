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
# The two deadlines are not interchangeable and their order is load-bearing. The outer per-commit
# timeout kills the whole analysis; the inner build timeout only ends the forked build, which is what
# lets codiqo excuse the commit as a build failure and retry it against progressively older snapshots.
# The outer clock starts before the fork does, so an equal pair means the outer one always wins and
# that recovery path becomes unreachable — every slow build turns into a hard CI failure instead.
#
codiqo::_require_minutes "${CODIQO_IN_BUILD_TIMEOUT_MINUTES:-45}" "build-timeout-minutes"
build_timeout_minutes="$CODIQO_MINUTES"
if [ "$per_commit_minutes" -le "$build_timeout_minutes" ]; then
    codiqo::die "per-commit-timeout (${per_commit_minutes}m) must be greater than build-timeout-minutes (${build_timeout_minutes}m), with enough headroom for the fork timeout to fire and the commit to be recorded as a build failure."
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

# ----------------------------------------------------------------------------- maven command

maven_command="${CODIQO_IN_MAVEN_COMMAND:-auto}"
if [ "$maven_command" = "auto" ]; then
    if [ -x "./mvnw" ]; then
        maven_command="./mvnw"
        codiqo::log "using the project's Maven wrapper (./mvnw)."
    else
        maven_command="mvn"
    fi
fi
if ! command -v "$maven_command" > /dev/null 2>&1 && [ ! -x "$maven_command" ]; then
    codiqo::die "maven command '$maven_command' was not found on PATH and is not an executable file."
fi

# --------------------------------------------------------- maven arguments and user properties

#
# One argument per line. Whitespace splitting is kept only for a single-line value, so
# `maven-args: '-T 1C -Dfoo=bar'` keeps working while a multi-line value can carry paths
# containing spaces.
#
args_file="$CODIQO_WORK_DIR/mvn-args"
: > "$args_file"
raw_args="${CODIQO_IN_MAVEN_ARGS:-}"
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
props_file="$CODIQO_WORK_DIR/mvn-props"
: > "$props_file"
if [ -n "${CODIQO_IN_MAVEN_USER_PROPERTIES:-}" ]; then
    printf '%s\n' "${CODIQO_IN_MAVEN_USER_PROPERTIES}" | while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in '' | '#'*) continue ;; esac
        case "$trimmed" in
            *=*) : ;;
            *)
                codiqo::error "maven-user-properties line '$trimmed' is not key=value."
                exit 1
                ;;
        esac
        key="${trimmed%%=*}"
        case "$key" in
            *[[:space:]]* | '')
                codiqo::error "maven-user-properties key '$key' is empty or contains whitespace."
                exit 1
                ;;
        esac
        printf -- '-D%s\n' "$trimmed" >> "$props_file"
    done
fi

# ------------------------------------------------------------------------------------ exports

codiqo::export CODIQO_WORK_DIR "$CODIQO_WORK_DIR"
codiqo::export CODIQO_LOGS_DIR "$CODIQO_LOGS_DIR"
codiqo::export CODIQO_COMMIT_WINDOW "$commit_window"
codiqo::export CODIQO_PER_COMMIT_TIMEOUT_MINUTES "$per_commit_minutes"
codiqo::export CODIQO_PER_COMMIT_TIMEOUT_SECONDS "$((per_commit_minutes * 60))"
codiqo::export CODIQO_PER_TEST_TIMEOUT_MINUTES "$per_test_minutes"
codiqo::export CODIQO_BRANCH "$branch"
codiqo::export CODIQO_MVN "$maven_command"
codiqo::export CODIQO_HEARTBEAT_INTERVAL "${CODIQO_IN_HEARTBEAT_INTERVAL:-30}"
codiqo::export CODIQO_TAIL_LINES "${CODIQO_IN_TAIL_LINES:-400}"
codiqo::export CODIQO_MISSING_FILE "$CODIQO_WORK_DIR/missing-analyses.txt"

if [ -n "${CODIQO_IN_MAVEN_OPTS:-}" ]; then
    codiqo::export MAVEN_OPTS "${CODIQO_IN_MAVEN_OPTS}"
fi

codiqo::group "resolved codiqo configuration"
codiqo::log "plugin version   : ${CODIQO_IN_VERSION:-unset}"
codiqo::log "api url          : ${CODIQO_IN_API_URL:-default}"
codiqo::log "maven command    : $maven_command"
codiqo::log "branch           : ${branch:-<auto-detect>}"
codiqo::log "commit window    : $commit_window"
codiqo::log "per-commit limit : ${per_commit_minutes}m"
codiqo::log "build limit      : ${build_timeout_minutes}m"
codiqo::log "per-test limit   : ${per_test_minutes}m (0 = disabled)"
codiqo::log "extra args       : $(wc -l < "$args_file" | tr -d ' ') line(s)"
codiqo::log "user properties  : $(wc -l < "$props_file" | tr -d ' ') line(s)"
codiqo::endgroup
