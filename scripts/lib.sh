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
# run_step read the same.
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
# Build output is redirected to a file so the heartbeat stays readable, which would
# otherwise hide the plugin's own diagnostics. The two that matter most in practice are the
# "deepen the clone" warning (a shallow checkout silently analyses nothing) and the
# "time-machine is not loaded in the host Maven" warning, so re-surface those lines.
#
# The grammar is the build tool's, not codiqo's. Maven prefixes every line with its level;
# Gradle prints a warn message bare, so anchoring on Maven's [WARNING] matched nothing on a
# Gradle log and swallowed the very warnings this exists to surface. Gradle logs are matched
# on the plugin's own "codiqo:" prefix plus the forked worker's slf4j-simple levels.
#
codiqo::_log_line_pattern() {
    if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
        printf '%s' '^(WARN|ERROR)[[:space:]]|^codiqo: '
    else
        printf '%s' '^\[(WARNING|ERROR)\]'
    fi
}

codiqo::emit_log_warnings() {
    local log="$1" limit="${2:-40}" found pattern
    if [ ! -f "$log" ]; then
        return 0
    fi
    pattern=$(codiqo::_log_line_pattern)
    found=$(grep -c -E "$pattern" "$log" 2>/dev/null || true)
    if [ -z "$found" ] || [ "$found" = "0" ]; then
        return 0
    fi
    codiqo::group "$(basename "$log"): $found flagged line(s) (last $limit)"
    grep -E "$pattern" "$log" | tail -n "$limit" || true
    codiqo::endgroup
}

#
# Did the forked analysis worker get its submission accepted? The engine logs the backend's
# acceptance ("accepted analysis id: ... status: ...", or the degraded variant when the build
# failed), which is the only evidence in the step log that the deliverable was produced. The
# Gradle path needs it because a build can end BUILD FAILED — a Test task that hit its timeout —
# long after codiqoSubmitAnalysis has posted.
#
codiqo::analysis_accepted() {
    local log="$1"
    if [ ! -f "$log" ]; then
        return 1
    fi
    grep -q -a -E 'accepted (degraded )?analysis id:' "$log" 2> /dev/null
}

codiqo::_mem_summary() {
    if command -v free > /dev/null 2>&1; then
        free -h 2>/dev/null | awk '/^Mem:/ {printf "mem %s/%s", $3, $2} /^Swap:/ {printf " swap %s/%s", $3, $2}'
    else
        printf 'mem n/a'
    fi
}

#
# Largest process by resident set. Picks the maximum in a single awk pass rather than
# `sort -k2 -n -r | head -1`: `head` closes the pipe after one line, and because the
# Actions runner leaves SIGPIPE ignored, children inherit SIG_IGN and sort reports
# "fflush failed: 'standard output': Broken pipe" into the step log instead of dying
# silently on the signal.
#
codiqo::_top_process() {
    ps -eo comm=,rss= 2>/dev/null |
        awk '$NF + 0 > max { max = $NF + 0; name = $1 }
             END { if (name != "") printf "top: %s %.1fG", name, max / 1048576 }'
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
codiqo::run_step() {
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
    #
    # Only the LAST reactor result belongs to this invocation. Codiqo forks a build per analysed
    # commit, and that fork writes its own summary into the same log — so a commit codiqo
    # deliberately excluded (an unresolvable historical dependency, say) leaves a BUILD FAILURE
    # behind even though the outer run went on to succeed and reported the exclusion. Matching
    # anywhere in the file turned every such exclusion into a failed step, which is a normal
    # backfill outcome, not a failure.
    #
    #
    # The two build tools word this differently, and the wordings overlap: Gradle's BUILD SUCCESSFUL
    # contains Maven's BUILD SUCCESS as a prefix, so a shared pattern would read a Gradle success
    # correctly and then miss BUILD FAILED entirely. Each tool gets its own pair.
    #
    local pattern success failure
    if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
        pattern='BUILD (SUCCESSFUL|FAILED)'
        success='BUILD SUCCESSFUL'
        failure='BUILD FAILED'
    else
        pattern='BUILD (SUCCESS|FAILURE)'
        success='BUILD SUCCESS'
        failure='BUILD FAILURE'
    fi

    local result
    result=$(grep -aoE "$pattern" "$log" 2> /dev/null | tail -1)
    if [ -z "$result" ]; then
        printf 'did not log %s' "$success"
        return 1
    fi
    if [ "$result" = "$failure" ]; then
        printf 'logged %s despite exit 0' "$failure"
        return 1
    fi
    return 0
}
