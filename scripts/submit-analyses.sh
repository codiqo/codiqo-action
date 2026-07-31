#!/usr/bin/env bash
#
# Analyse and submit each pending commit, one at a time, under its own deadline.
#
# Sequential on purpose: a single commit analysis forks a full `clean verify`, starts a JDT
# language server and runs static analysis, so two at once on one runner would compete for
# memory and produce timeouts that look like build failures.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

if [ ! -f "$CODIQO_MISSING_FILE" ]; then
    codiqo::log "no missing-analyses file at $CODIQO_MISSING_FILE; nothing to submit."
    codiqo::output "analysed-count" "0"
    codiqo::output "failed-count" "0"
    exit 0
fi

commits=()
while IFS= read -r line || [ -n "$line" ]; do
    sha=$(printf '%s' "$line" | tr -d '[:space:]')
    if [ -n "$sha" ]; then
        commits+=("$sha")
    fi
done < "$CODIQO_MISSING_FILE"

total=${#commits[@]}
if [ "$total" -eq 0 ]; then
    codiqo::log "missing-analyses file is empty; nothing to submit."
    codiqo::output "analysed-count" "0"
    codiqo::output "failed-count" "0"
    exit 0
fi

plugin="io.codiqo:codiqo-maven-plugin:${CODIQO_IN_VERSION}"
codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/mvn-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/mvn-props"

analysed=0
failed=0
loop_start=$(date +%s)
index=0

for commit in "${commits[@]}"; do
    index=$((index + 1))
    #
    # Author identity is off by default: these logs are uploaded as a build artifact, so the
    # public default keeps personal data out of it. Callers who want it opt in.
    #
    if [ "${CODIQO_IN_LOG_COMMIT_AUTHORS:-false}" = "true" ]; then
        who=$(git show -s --format='%an <%ae>' "$commit" 2> /dev/null || echo "unknown author")
        codiqo::log "submitting analysis $index/$total for $commit by $who"
    else
        codiqo::log "submitting analysis $index/$total for $commit"
    fi

    cmd=("$CODIQO_MVN" -B -ntp -e -U)
    if [ -n "${CODIQO_IN_MAVEN_PARALLELISM:-}" ]; then cmd+=(-T "${CODIQO_IN_MAVEN_PARALLELISM}"); fi
    if [ -n "${CODIQO_TM_EXT_CLASSPATH:-}" ]; then cmd+=("-Dmaven.ext.class.path=${CODIQO_TM_EXT_CLASSPATH}"); fi
    cmd+=(${extra_args[@]+"${extra_args[@]}"})
    cmd+=(${user_props[@]+"${user_props[@]}"})
    cmd+=("${plugin}:submit-commit-analysis")
    cmd+=("-Dcodiqo.commitId=${commit}")
    cmd+=("-Dcodiqo.apiKey=env:CODIQO_API_KEY")
    cmd+=("-Dcodiqo.firstParentOnly=${CODIQO_IN_FIRST_PARENT_ONLY:-true}")
    cmd+=("-Dcodiqo.scoreOnBuildFailure=${CODIQO_IN_SCORE_ON_BUILD_FAILURE:-false}")
    cmd+=("-Dcodiqo.excludeRevertedCommits=${CODIQO_IN_EXCLUDE_REVERTED_COMMITS:-true}")
    cmd+=("-Dcodiqo.ignoreCoverage=${CODIQO_IN_IGNORE_COVERAGE:-false}")
    cmd+=("-Dcodiqo.timeMachineEnabled=${CODIQO_IN_TIME_MACHINE:-true}")
    cmd+=("-Dcodiqo.dumpAnalysis=${CODIQO_IN_DUMP_ANALYSIS:-true}")
    cmd+=("-Dcodiqo.perTestTimeoutMinutes=${CODIQO_PER_TEST_TIMEOUT_MINUTES}")

    if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Dcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
    if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_JAVA_HOME:-}" ]; then cmd+=("-Dcodiqo.javaHome=${CODIQO_IN_JAVA_HOME}"); fi
    if [ -n "${CODIQO_IN_MAVEN_HOME:-}" ]; then cmd+=("-Dcodiqo.mavenHome=${CODIQO_IN_MAVEN_HOME}"); fi
    if [ -n "${CODIQO_IN_JDTLS_VERSION:-}" ]; then cmd+=("-Dcodiqo.jdtlsVersion=${CODIQO_IN_JDTLS_VERSION}"); fi
    if [ -n "${CODIQO_IN_BUILD_TIMEOUT_MINUTES:-}" ]; then cmd+=("-Dcodiqo.buildTimeoutMinutes=${CODIQO_IN_BUILD_TIMEOUT_MINUTES}"); fi
    if [ -n "${CODIQO_IN_TEST_TIMEOUT_MINUTES:-}" ]; then cmd+=("-Dcodiqo.testTimeoutMinutes=${CODIQO_IN_TEST_TIMEOUT_MINUTES}"); fi
    if [ -n "${CODIQO_IN_IMPORT_TIMEOUT_MINUTES:-}" ]; then cmd+=("-Dcodiqo.importTimeoutMinutes=${CODIQO_IN_IMPORT_TIMEOUT_MINUTES}"); fi
    if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi

    rc=0
    log="$CODIQO_LOGS_DIR/submit-${commit}.log"
    CODIQO_STEP_TIMEOUT_SECONDS="$CODIQO_PER_COMMIT_TIMEOUT_SECONDS" \
        codiqo::run_maven_step "submit-${commit}" "${cmd[@]}" || rc=$?
    codiqo::emit_log_warnings "$log"

    if reason=$(codiqo::assert_build_success "$log" "$rc"); then
        analysed=$((analysed + 1))
        codiqo::log "  ok ($index/$total, ${CODIQO_LAST_ELAPSED}s, $(($(date +%s) - loop_start))s cumulative)"
        continue
    fi

    failed=$((failed + 1))
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        #
        # GNU timeout reports 124, and 137 is SIGKILL — which is also what a kernel OOM kill
        # looks like, so name both possibilities rather than blaming the deadline outright.
        #
        codiqo::error "commit $commit exceeded the ${CODIQO_PER_COMMIT_TIMEOUT_MINUTES}m per-commit deadline, or was killed (exit $rc; a kernel OOM kill also produces 137)."
    else
        codiqo::error "commit $commit $reason."
    fi
    codiqo::tail_log "$log"

    if [ "${CODIQO_IN_FAIL_FAST:-true}" = "true" ]; then
        codiqo::output "analysed-count" "$analysed"
        codiqo::output "failed-count" "$failed"
        codiqo::log "stopping after the first failure (fail-fast). $((total - index)) commit(s) left unattempted."
        exit 1
    fi
done

codiqo::output "analysed-count" "$analysed"
codiqo::output "failed-count" "$failed"
codiqo::log "submitted $analysed of $total analyses in $(($(date +%s) - loop_start))s ($failed failed)."

#
# With fail-fast off the loop keeps going, but the step still has to report the truth.
#
if [ "$failed" -gt 0 ]; then
    exit 1
fi
