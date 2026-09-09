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
codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/build-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/build-props"

#
# Who checks out the commit differs by build tool, and it is not a style choice. The Maven goal
# clones the repository itself and builds the commit in a temporary tree, so the workspace is
# never touched. A Gradle build reads its whole model at startup, so it cannot re-target itself at
# another commit from inside a task — the checkout has to happen here, before the build starts.
#
# That makes this loop responsible for putting the workspace back. The original ref is captured up
# front and restored by a trap, so an interrupted or failed run still leaves the workspace as
# actions/checkout produced it rather than on some historical commit.
#
if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
    #
    # The per-commit checkout is `--force`, which overwrites modified tracked files and cannot be
    # undone: the trap below restores the ref, never the content. So a workspace carrying edits from
    # an earlier step — codegen, a version bump, an applied patch — is rejected here rather than
    # silently destroyed one line later. Untracked files are not at risk and are not counted.
    #
    dirty=$(git status --porcelain --untracked-files=no)
    if [ -n "$dirty" ]; then
        codiqo::error "the workspace has uncommitted changes to tracked files, and analysing with build-tool: gradle checks out each commit with --force, which would discard them:"
        printf '%s\n' "$dirty" | head -n 20
        codiqo::die "commit or stash them, or run this action before the steps that modify the checkout."
    fi

    original_ref=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
    codiqo::log "gradle mode: the workspace is checked out per commit and restored to $original_ref afterwards."
    #
    # Single quotes on purpose. A double-quoted trap body would bake the ref into the string and let
    # bash re-parse it when the trap fires, so a legal branch name carrying an apostrophe (or worse)
    # would break the restore, or run as code. Expanding at trap time keeps it a value.
    #
    trap 'git checkout --force --quiet "$original_ref" 2> /dev/null || true' EXIT
fi

analysed=0
failed=0
loop_start=$(date +%s)
index=0

#
# One commit's outcome, shared by both build-tool branches so the counters, the messages and the
# stop-on-first-failure rule cannot drift between them. Returns non-zero when the caller must stop.
#
codiqo::report_commit_result() {
    local commit="$1" index="$2" total="$3" rc="$4" log="$5" loop_start="$6"
    local reason
    if reason=$(codiqo::assert_build_success "$log" "$rc"); then
        analysed=$((analysed + 1))
        codiqo::log "  ok ($index/$total, ${CODIQO_LAST_ELAPSED}s, $(($(date +%s) - loop_start))s cumulative)"
        return 0
    fi

    #
    # Gradle exits non-zero whenever any task failed, and --continue exists precisely so a Test task
    # that hit codiqo's timeout still carries the build through to codiqoSubmitAnalysis. Judging the
    # commit on the exit status alone would discard an analysis the backend has already accepted
    # and, with stop-on-first-failure, abort the whole backfill over it — so the worker's acceptance
    # line outranks the exit code. A killed run (124/137) is never relaxed: its log can be truncated
    # mid-post, so an acceptance line may be missing or, worse, only half written.
    #
    if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] &&
        codiqo::analysis_accepted "$log"; then
        analysed=$((analysed + 1))
        codiqo::warn "commit $commit: the build $reason, but the analysis was accepted — counting it as analysed."
        codiqo::log "  ok ($index/$total, ${CODIQO_LAST_ELAPSED}s, $(($(date +%s) - loop_start))s cumulative)"
        return 0
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

    if [ "${CODIQO_IN_STOP_ON_FIRST_FAILURE:-true}" = "true" ]; then
        codiqo::output "analysed-count" "$analysed"
        codiqo::output "failed-count" "$failed"
        codiqo::log "stopping after the first failure. $((total - index)) commit(s) left unattempted."
        return 1
    fi
    return 0
}

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

    if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
        if ! git checkout --force --quiet "$commit" 2> /dev/null; then
            failed=$((failed + 1))
            codiqo::error "commit $commit could not be checked out; is the clone deep enough?"
            if [ "${CODIQO_IN_STOP_ON_FIRST_FAILURE:-true}" = "true" ]; then
                codiqo::output "analysed-count" "$analysed"
                codiqo::output "failed-count" "$failed"
                codiqo::log "stopping after the first failure. $((total - index)) commit(s) left unattempted."
                exit 1
            fi
            continue
        fi
        #
        # A checkout of an already-built commit restores same-content classes with fresh mtimes
        # behind older sources, which trips the engine's staleness guard. Dropping the compiled
        # output costs a recompile and removes a whole class of false failures.
        #
        find . -type d -path '*/build/classes' -prune -exec rm -rf {} + 2> /dev/null || true
        find . -type d -path '*/build/jacoco' -prune -exec rm -rf {} + 2> /dev/null || true

        cmd=("$CODIQO_BUILD_CMD" --console=plain --init-script "$CODIQO_GRADLE_INIT")
        #
        # --continue is mandatory, not tidiness: codiqo caps every Test task with a timeout, and a
        # task that hits it still fails even though ordinary test failures are ignored. Without it
        # the build stops before codiqoSubmitAnalysis and the commit produces nothing.
        #
        cmd+=(--continue)
        cmd+=(${extra_args[@]+"${extra_args[@]}"})
        cmd+=(${user_props[@]+"${user_props[@]}"})
        #
        # Word splitting is wanted here, globbing is not: `--tests *Test` would otherwise be
        # expanded against the workspace and Gradle would receive file names, or the literal.
        #
        set -f
        for task in ${CODIQO_GRADLE_TASKS}; do cmd+=("$task"); done
        set +f
        cmd+=("codiqoSubmitAnalysis")
        cmd+=("-Pcodiqo.commitId=${commit}")
        cmd+=("-Pcodiqo.apiKey=env:CODIQO_API_KEY")
        cmd+=("-Pcodiqo.firstParentOnly=${CODIQO_IN_FIRST_PARENT_ONLY:-true}")
        cmd+=("-Pcodiqo.excludeRevertedCommits=${CODIQO_IN_EXCLUDE_REVERTED_COMMITS:-true}")
        cmd+=("-Pcodiqo.ignoreCoverage=${CODIQO_IN_IGNORE_COVERAGE:-false}")
        cmd+=("-Pcodiqo.ignoreComplexity=${CODIQO_IN_IGNORE_COMPLEXITY:-false}")
        cmd+=("-Pcodiqo.ignoreCpd=${CODIQO_IN_IGNORE_CPD:-false}")
        cmd+=("-Pcodiqo.ignoreDiagnostics=${CODIQO_IN_IGNORE_DIAGNOSTICS:-false}")
        cmd+=("-Pcodiqo.skipOnBuildFailure=${CODIQO_IN_SKIP_ON_BUILD_FAILURE:-true}")
        cmd+=("-Pcodiqo.scoreOnBuildFailure=${CODIQO_IN_SCORE_ON_BUILD_FAILURE:-false}")
        cmd+=("-Pcodiqo.failOnUninstrumentedModule=${CODIQO_IN_FAIL_ON_UNINSTRUMENTED_MODULE:-true}")
        cmd+=("-Pcodiqo.failOnJdtlsError=${CODIQO_IN_FAIL_ON_JDTLS_ERROR:-false}")
        cmd+=("-Pcodiqo.jdtUseSharedIndex=${CODIQO_IN_JDT_USE_SHARED_INDEX:-true}")
        cmd+=("-Pcodiqo.jdtIncludeDecompiledSources=${CODIQO_IN_JDT_INCLUDE_DECOMPILED_SOURCES:-false}")
        cmd+=("-Pcodiqo.jdtlsUseSnapshot=${CODIQO_IN_JDTLS_USE_SNAPSHOT:-false}")
        cmd+=("-Pcodiqo.testTimeoutMinutes=${CODIQO_TEST_TIMEOUT_MINUTES}")
        cmd+=("-Pcodiqo.perTestTimeoutMinutes=${CODIQO_PER_TEST_TIMEOUT_MINUTES}")

        if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Pcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
        if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Pcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
        if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Pcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
        if [ -n "${CODIQO_IN_INCLUDE_BRANCHES:-}" ]; then cmd+=("-Pcodiqo.includeBranches=${CODIQO_IN_INCLUDE_BRANCHES}"); fi
        if [ -n "${CODIQO_IN_JAVA_HOME:-}" ]; then cmd+=("-Pcodiqo.javaHome=${CODIQO_IN_JAVA_HOME}"); fi
        if [ -n "${CODIQO_IN_JDTLS_VERSION:-}" ]; then cmd+=("-Pcodiqo.jdtlsVersion=${CODIQO_IN_JDTLS_VERSION}"); fi
        if [ -n "${CODIQO_IN_IMPORT_TIMEOUT_MINUTES:-}" ]; then cmd+=("-Pcodiqo.importTimeoutMinutes=${CODIQO_IN_IMPORT_TIMEOUT_MINUTES}"); fi
        if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Pcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
        if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Pcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi
        if [ -n "${CODIQO_IN_ANALYSIS_MAX_HEAP:-}" ]; then cmd+=("-Pcodiqo.analysisMaxHeap=${CODIQO_IN_ANALYSIS_MAX_HEAP}"); fi
        #
        # Both of these are read from project properties by the Gradle plugin exactly as the Maven
        # mojo reads them from system properties, so leaving them off this branch made two supported
        # inputs silently inert on Gradle alone.
        #
        if [ -n "${CODIQO_IN_LSP_QUERY_TIMEOUT_SECONDS:-}" ]; then cmd+=("-Pcodiqo.lspQueryTimeoutSeconds=${CODIQO_IN_LSP_QUERY_TIMEOUT_SECONDS}"); fi
        if [ -n "${CODIQO_IN_ANALYSIS_OUTPUT_DIRECTORY:-}" ]; then cmd+=("-Pcodiqo.outputDirectory=${CODIQO_IN_ANALYSIS_OUTPUT_DIRECTORY}"); fi

        rc=0
        log="$CODIQO_LOGS_DIR/submit-${commit}.log"
        CODIQO_STEP_TIMEOUT_SECONDS="$CODIQO_PER_COMMIT_TIMEOUT_SECONDS" \
            codiqo::run_step "submit-${commit}" "${cmd[@]}" || rc=$?
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            #
            # The deadline kills the gradlew client. A daemon reused from an earlier invocation is a
            # separate process that outlives it, and the analysis it forked is that daemon's child,
            # not the client's — so both can still be running, holding this commit's checkout, when
            # the loop force-checks-out the next one. Reap the daemon before that happens.
            #
            codiqo::log "stopping the Gradle daemon after a killed build."
            "$CODIQO_BUILD_CMD" --stop > /dev/null 2>&1 || true
        fi
        codiqo::emit_log_warnings "$log"
        codiqo::report_commit_result "$commit" "$index" "$total" "$rc" "$log" "$loop_start" || exit $?
        continue
    fi

    cmd=("$CODIQO_BUILD_CMD" -B -ntp -e -U)
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
    cmd+=("-Dcodiqo.llm.autoDiscoveryAgentInstructions=${CODIQO_IN_AGENT_INSTRUCTIONS:-true}")
    cmd+=("-Dcodiqo.skipOnBuildFailure=${CODIQO_IN_SKIP_ON_BUILD_FAILURE:-true}")
    cmd+=("-Dcodiqo.failOnUninstrumentedModule=${CODIQO_IN_FAIL_ON_UNINSTRUMENTED_MODULE:-true}")
    cmd+=("-Dcodiqo.failOnJdtlsError=${CODIQO_IN_FAIL_ON_JDTLS_ERROR:-false}")
    cmd+=("-Dcodiqo.ignoreComplexity=${CODIQO_IN_IGNORE_COMPLEXITY:-false}")
    cmd+=("-Dcodiqo.ignoreCpd=${CODIQO_IN_IGNORE_CPD:-false}")
    cmd+=("-Dcodiqo.ignoreDiagnostics=${CODIQO_IN_IGNORE_DIAGNOSTICS:-false}")
    cmd+=("-Dcodiqo.moveDetectionEnabled=${CODIQO_IN_MOVE_DETECTION:-true}")
    cmd+=("-Dcodiqo.driverScoreCapDryRun=${CODIQO_IN_DRIVER_SCORE_CAP_DRY_RUN:-false}")
    cmd+=("-Dcodiqo.jdtUseSharedIndex=${CODIQO_IN_JDT_USE_SHARED_INDEX:-true}")
    cmd+=("-Dcodiqo.jdtIncludeDecompiledSources=${CODIQO_IN_JDT_INCLUDE_DECOMPILED_SOURCES:-false}")
    cmd+=("-Dcodiqo.jdtlsUseSnapshot=${CODIQO_IN_JDTLS_USE_SNAPSHOT:-false}")
    cmd+=("-Dcodiqo.buildTimeoutMinutes=${CODIQO_BUILD_TIMEOUT_MINUTES}")
    cmd+=("-Dcodiqo.testTimeoutMinutes=${CODIQO_TEST_TIMEOUT_MINUTES}")
    cmd+=("-Dcodiqo.perTestTimeoutMinutes=${CODIQO_PER_TEST_TIMEOUT_MINUTES}")

    if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Dcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
    if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_JAVA_HOME:-}" ]; then cmd+=("-Dcodiqo.javaHome=${CODIQO_IN_JAVA_HOME}"); fi
    if [ -n "${CODIQO_IN_MAVEN_HOME:-}" ]; then cmd+=("-Dcodiqo.mavenHome=${CODIQO_IN_MAVEN_HOME}"); fi
    if [ -n "${CODIQO_IN_JDTLS_VERSION:-}" ]; then cmd+=("-Dcodiqo.jdtlsVersion=${CODIQO_IN_JDTLS_VERSION}"); fi
    if [ -n "${CODIQO_IN_IMPORT_TIMEOUT_MINUTES:-}" ]; then cmd+=("-Dcodiqo.importTimeoutMinutes=${CODIQO_IN_IMPORT_TIMEOUT_MINUTES}"); fi
    if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_BRANCHES:-}" ]; then cmd+=("-Dcodiqo.includeBranches=${CODIQO_IN_INCLUDE_BRANCHES}"); fi
    if [ -n "${CODIQO_IN_PMD_RULES:-}" ]; then cmd+=("-Dcodiqo.pmdRules=${CODIQO_IN_PMD_RULES}"); fi
    if [ -n "${CODIQO_IN_PMD_MIN_PRIORITY:-}" ]; then cmd+=("-Dcodiqo.pmdMinPriority=${CODIQO_IN_PMD_MIN_PRIORITY}"); fi
    if [ -n "${CODIQO_IN_SPOTBUGS_PRIORITY_THRESHOLD:-}" ]; then cmd+=("-Dcodiqo.spotbugsPriorityThreshold=${CODIQO_IN_SPOTBUGS_PRIORITY_THRESHOLD}"); fi
    if [ -n "${CODIQO_IN_SPOTBUGS_OMIT_VISITORS:-}" ]; then cmd+=("-Dcodiqo.spotbugsOmitVisitors=${CODIQO_IN_SPOTBUGS_OMIT_VISITORS}"); fi
    if [ -n "${CODIQO_IN_CPD_MINIMUM_TILE_SIZE:-}" ]; then cmd+=("-Dcodiqo.cpdMinimumTileSize=${CODIQO_IN_CPD_MINIMUM_TILE_SIZE}"); fi
    if [ -n "${CODIQO_IN_DIFF_CONTEXT_LINES:-}" ]; then cmd+=("-Dcodiqo.diffContextLines=${CODIQO_IN_DIFF_CONTEXT_LINES}"); fi
    if [ -n "${CODIQO_IN_BUILD_ERROR_CAPTURE_LIMIT:-}" ]; then cmd+=("-Dcodiqo.buildErrorCaptureLimit=${CODIQO_IN_BUILD_ERROR_CAPTURE_LIMIT}"); fi
    if [ -n "${CODIQO_IN_MOVE_SIMILARITY_THRESHOLD:-}" ]; then cmd+=("-Dcodiqo.moveSimilarityThreshold=${CODIQO_IN_MOVE_SIMILARITY_THRESHOLD}"); fi
    if [ -n "${CODIQO_IN_MOVED_LINE_COEFFICIENT:-}" ]; then cmd+=("-Dcodiqo.movedLineCoefficient=${CODIQO_IN_MOVED_LINE_COEFFICIENT}"); fi
    if [ -n "${CODIQO_IN_DRIVER_SCORE_CAP_MULTIPLIER:-}" ]; then cmd+=("-Dcodiqo.driverScoreCapMultiplier=${CODIQO_IN_DRIVER_SCORE_CAP_MULTIPLIER}"); fi
    if [ -n "${CODIQO_IN_DRIVER_FACTOR_MAX_DEVIATION:-}" ]; then cmd+=("-Dcodiqo.driverFactorMaxDeviation=${CODIQO_IN_DRIVER_FACTOR_MAX_DEVIATION}"); fi
    if [ -n "${CODIQO_IN_MAX_REQUESTS:-}" ]; then cmd+=("-Dcodiqo.maxRequests=${CODIQO_IN_MAX_REQUESTS}"); fi
    if [ -n "${CODIQO_IN_MAX_REQUESTS_PER_HOST:-}" ]; then cmd+=("-Dcodiqo.maxRequestsPerHost=${CODIQO_IN_MAX_REQUESTS_PER_HOST}"); fi
    if [ -n "${CODIQO_IN_LSP_QUERY_TIMEOUT_SECONDS:-}" ]; then cmd+=("-Dcodiqo.lspQueryTimeoutSeconds=${CODIQO_IN_LSP_QUERY_TIMEOUT_SECONDS}"); fi
    if [ -n "${CODIQO_IN_JDT_SOURCE_EXCLUSIONS:-}" ]; then cmd+=("-Dcodiqo.jdtSourceExclusions=${CODIQO_IN_JDT_SOURCE_EXCLUSIONS}"); fi
    if [ -n "${CODIQO_IN_ANALYSIS_OUTPUT_DIRECTORY:-}" ]; then cmd+=("-Dcodiqo.outputDirectory=${CODIQO_IN_ANALYSIS_OUTPUT_DIRECTORY}"); fi
    if [ -n "${CODIQO_IN_AGENT_INSTRUCTION_FILES:-}" ]; then cmd+=("-Dcodiqo.llm.conventionFiles=${CODIQO_IN_AGENT_INSTRUCTION_FILES}"); fi
    if [ -n "${CODIQO_IN_AGENT_INSTRUCTIONS_MAX_CHARS:-}" ]; then cmd+=("-Dcodiqo.llm.conventionFilesMaxChars=${CODIQO_IN_AGENT_INSTRUCTIONS_MAX_CHARS}"); fi

    rc=0
    log="$CODIQO_LOGS_DIR/submit-${commit}.log"
    CODIQO_STEP_TIMEOUT_SECONDS="$CODIQO_PER_COMMIT_TIMEOUT_SECONDS" \
        codiqo::run_step "submit-${commit}" "${cmd[@]}" || rc=$?
    codiqo::emit_log_warnings "$log"
    codiqo::report_commit_result "$commit" "$index" "$total" "$rc" "$log" "$loop_start" || exit $?
done

codiqo::output "analysed-count" "$analysed"
codiqo::output "failed-count" "$failed"
codiqo::log "submitted $analysed of $total analyses in $(($(date +%s) - loop_start))s ($failed failed)."

#
# With stop-on-first-failure off the loop keeps going, but the step still has to report the truth.
#
if [ "$failed" -gt 0 ]; then
    exit 1
fi
