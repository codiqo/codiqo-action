# shellcheck shell=bash
#
# Shared helpers for the Codiqo action. Sourced by every script; never executed directly.
#
# Portability: the heartbeat reads /proc, so CPU and memory columns are Linux-only and
# degrade to "n/a" elsewhere. Everything else works on bash 3.2, which is why array files
# are read with a `while read` loop rather than `mapfile` (absent before bash 4).

CODIQO_LOGS_DIR="${CODIQO_LOGS_DIR:-${RUNNER_TEMP:-/tmp}/step-logs}"
CODIQO_WORK_DIR="${CODIQO_WORK_DIR:-${RUNNER_TEMP:-/tmp}/codiqo}"

codiqo::log() { printf '%s\n' "$*"; }
codiqo::warn() { printf '::warning::%s\n' "$*"; }
codiqo::error() { printf '::error::%s\n' "$*"; }
codiqo::group() { printf '::group::%s\n' "$*"; }
codiqo::endgroup() { printf '::endgroup::\n'; }
codiqo::die() {
    codiqo::error "$*"
    exit 1
}
codiqo::output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}
codiqo::export() {
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
    fi
    export "$1=$2"
}

#
# Read a file of one-per-line values into the named array. Blank lines and lines whose
# first non-space character is '#' are skipped. A missing file yields an empty array
# rather than an error, so callers need no existence check.
#
codiqo::read_lines_into() {
    local target="$1" file="$2" line
    eval "$target=()"
    if [ ! -f "$file" ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '' | '#'*) continue ;;
        esac
        eval "$target+=(\"\$line\")"
    done < "$file"
}

#
# Emit the tail of a log, used on failure. Kept separate so the three failure branches in
# run_maven_step read the same.
#
codiqo::tail_log() {
    local log="$1" lines="${2:-${CODIQO_TAIL_LINES:-400}}"
    if [ ! -f "$log" ]; then
        codiqo::log "  (no log at $log)"
        return 0
    fi
    codiqo::log "=========================================================="
    codiqo::log "       last $lines lines of $(basename "$log")"
    codiqo::log "=========================================================="
    tail -n "$lines" "$log"
}

#
# Maven output is redirected to a file so the heartbeat stays readable, which would
# otherwise hide the plugin's own diagnostics. The two that matter most in practice are the
# "deepen the clone" warning (a shallow checkout silently analyses nothing) and the
# "time-machine is not loaded in the host Maven" warning, so re-surface WARNING/ERROR lines.
#
codiqo::emit_log_warnings() {
    local log="$1" limit="${2:-40}" found
    if [ ! -f "$log" ]; then
        return 0
    fi
    found=$(grep -c -E '^\[(WARNING|ERROR)\]' "$log" 2>/dev/null || true)
    if [ -z "$found" ] || [ "$found" = "0" ]; then
        return 0
    fi
    codiqo::group "$(basename "$log"): $found warning/error lines (last $limit)"
    grep -E '^\[(WARNING|ERROR)\]' "$log" | tail -n "$limit" || true
    codiqo::endgroup
}

codiqo::_mem_summary() {
    if command -v free > /dev/null 2>&1; then
        free -h 2>/dev/null | awk '/^Mem:/ {printf "mem %s/%s", $3, $2} /^Swap:/ {printf " swap %s/%s", $3, $2}'
    else
        printf 'mem n/a'
    fi
}

codiqo::_top_process() {
    ps -eo comm=,rss= 2>/dev/null | sort -k2 -n -r | head -1 |
        awk '{printf "top: %s %.1fG", $1, $2/1048576}'
}

codiqo::_load_average() {
    if [ -r /proc/loadavg ]; then
        awk '{printf "load %s", $1}' /proc/loadavg
    else
        printf 'load n/a'
    fi
}

#
# CPU busy ratio between two /proc/stat samples. "steal" counts as busy so a throttled
# shared runner does not look idle while it is starved.
#
# Sets CODIQO_CPU_TEXT rather than printing, because the carried-over sample must survive
# the call: inside $(...) the assignments would land in a subshell and every reading would
# degrade to a cumulative average instead of an interval rate.
#
codiqo::_cpu_sample() {
    CODIQO_CPU_TEXT='cpu n/a'
    if [ ! -r /proc/stat ]; then
        return 0
    fi
    local busy total dbusy dtotal
    busy=$(awk '/^cpu /{print $2+$3+$4+$7+$8+$9; exit}' /proc/stat)
    total=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9; exit}' /proc/stat)
    dbusy=$((busy - ${CODIQO_CPU_BUSY_PREV:-0}))
    dtotal=$((total - ${CODIQO_CPU_TOTAL_PREV:-0}))
    CODIQO_CPU_BUSY_PREV="$busy"
    CODIQO_CPU_TOTAL_PREV="$total"
    if [ "$dtotal" -gt 0 ]; then
        CODIQO_CPU_TEXT="cpu $((dbusy * 100 / dtotal))%"
    fi
}

#
# Wait for a pid, printing one status line per interval. Two reasons this exists rather
# than letting Maven stream: GitHub abandons a job it believes has lost contact with the
# runner, and a "+0 lines" delta is the clearest signal that a build has wedged rather
# than merely gone quiet.
#
# MUST be called as `codiqo::heartbeat_wait ... || rc=$?` — a bare call aborts the step
# under `set -e` when the wrapped command fails.
#
codiqo::heartbeat_wait() {
    local pid="$1" label="$2" log="$3" start="$4"
    local interval="${CODIQO_HEARTBEAT_INTERVAL:-30}"
    local waited=0 lines_prev=0 lines_now elapsed slice
    CODIQO_CPU_BUSY_PREV=0
    CODIQO_CPU_TOTAL_PREV=0
    codiqo::_cpu_sample

    while kill -0 "$pid" 2> /dev/null; do
        slice=10
        if [ "$slice" -gt "$interval" ]; then slice="$interval"; fi
        sleep "$slice"
        waited=$((waited + slice))
        if [ "$waited" -lt "$interval" ]; then
            continue
        fi
        waited=0
        elapsed=$(($(date +%s) - start))
        lines_now=0
        if [ -f "$log" ]; then
            lines_now=$(wc -l < "$log" | tr -d ' ')
        fi
        codiqo::_cpu_sample
        printf '[status] %s: %ss elapsed | %s | %s | %s %s | log %s lines (+%s)\n' \
            "$label" "$elapsed" "$(codiqo::_mem_summary)" "$(codiqo::_top_process)" \
            "$CODIQO_CPU_TEXT" "$(codiqo::_load_average)" \
            "$lines_now" "$((lines_now - lines_prev))"
        lines_prev="$lines_now"
    done

    wait "$pid"
}

#
# Run a Maven invocation into a log file with a heartbeat, then assert it truly succeeded.
# Exit code alone is not enough: Maven can exit 0 with BUILD FAILURE in some plugin
# configurations, and a killed JVM can leave a truncated log with neither marker.
#
# Set CODIQO_STEP_TIMEOUT_SECONDS to wrap the command in `timeout -k 60`. Returns the exit
# status; 124/137 mean the deadline or a kill (GNU timeout, or an OOM kill).
#
codiqo::run_maven_step() {
    local name="$1"
    shift
    local log="$CODIQO_LOGS_DIR/${name}.log"
    local start rc=0
    mkdir -p "$CODIQO_LOGS_DIR"
    start=$(date +%s)

    codiqo::log "running $name (log: $log)"
    if [ -n "${CODIQO_STEP_TIMEOUT_SECONDS:-}" ] && command -v timeout > /dev/null 2>&1; then
        timeout -k 60 "$CODIQO_STEP_TIMEOUT_SECONDS" "$@" > "$log" 2>&1 &
    else
        if [ -n "${CODIQO_STEP_TIMEOUT_SECONDS:-}" ]; then
            codiqo::warn "coreutils timeout is unavailable; running $name without a deadline"
        fi
        "$@" > "$log" 2>&1 &
    fi
    codiqo::heartbeat_wait $! "$name" "$log" "$start" || rc=$?

    CODIQO_LAST_LOG="$log"
    CODIQO_LAST_ELAPSED=$(($(date +%s) - start))
    return "$rc"
}

#
# The three-way success assertion, split out so submit-analyses.sh can add its own
# per-commit messaging around it. On failure it echoes a reason on stdout and returns
# non-zero, so callers use `if ! reason=$(...)`. On success it prints nothing — anything
# written here would be captured by that command substitution instead of reaching the log.
#
codiqo::assert_build_success() {
    local log="$1" rc="$2"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf 'timed out or was killed (exit %s)' "$rc"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'failed with exit %s' "$rc"
        return 1
    fi
    if grep -q 'BUILD FAILURE' "$log" 2> /dev/null; then
        printf 'logged BUILD FAILURE despite exit 0'
        return 1
    fi
    if ! grep -q 'BUILD SUCCESS' "$log" 2> /dev/null; then
        printf 'did not log BUILD SUCCESS'
        return 1
    fi
    return 0
}
