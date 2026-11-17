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
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
extra_args=()
codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/build-args"

#
# The download cache is restored under the key of the version indexed for this run. A restored entry
# from an older key can carry last run's language-server archive, which the plugin would ignore and the
# cache would then keep re-saving under the new key — ~100 MB a runner keeps restoring for nothing.
#
resolved_jdtls_version=""
if [ -f "$CODIQO_METADATA_FILE" ]; then
    resolved_jdtls_version=$(grep -E '^jdtlsVersion=[A-Za-z0-9._-]+$' "$CODIQO_METADATA_FILE" | tail -1 | cut -d= -f2-)
fi
if [ -n "$resolved_jdtls_version" ] && [ -d "$HOME/.cache/fetch" ]; then
    for archive in "$HOME"/.cache/fetch/jdt-language-server-*.tar.gz; do
        [ -e "$archive" ] || continue
        case "$(basename "$archive")" in
            "jdt-language-server-${resolved_jdtls_version}-"*.tar.gz) ;;
            *) codiqo::log "dropping stale language-server archive from the download cache: $(basename "$archive")"; rm -f "$archive" ;;
        esac
    done
fi
user_props=()
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/build-props"

#
# The hotspot snapshot is built for the commit the run started on. It is captured here, before the
# Gradle loop below checks out each analysed commit and moves HEAD away from it.
#
hotspots_commit=$(git rev-parse HEAD)

# Only the default branch writes the project's snapshot, so unmerged code never replaces it.
hotspots="${CODIQO_IN_HOTSPOTS:-true}"
if [ "$hotspots" = "true" ]; then
    run_branch=$(codiqo::ci_branch)
    if codiqo::ci_change_request; then
        hotspots=false
    elif [ -n "${CODIQO_DEFAULT_BRANCH:-}" ] && [ "$run_branch" != "${CODIQO_DEFAULT_BRANCH}" ]; then
        hotspots=false
    fi
    if [ "$hotspots" = "false" ]; then
        codiqo::log "hotspots skipped: the snapshot is built only on the default branch (${CODIQO_DEFAULT_BRANCH:-unknown}), not on ${run_branch:-this ref}."
    fi
fi

#
# The run's settings, each as codiqo.<name>=<value>. The Maven and the Gradle plugin read every
# setting under one name, so this one list serves both: Maven takes each as a user property (-D)
# and Gradle as a project property (-P), and an input added here reaches both build tools. Only
# what one plugin alone has is added beside its command below. An empty value is left out, so the
# plugin's own default holds.
#
settings=()
add_setting() {
    if [ -n "$2" ]; then
        settings+=("codiqo.$1=$2")
    fi
}
add_setting apiKey "env:CODIQO_API_KEY"
add_setting apiUrl "${CODIQO_IN_API_URL:-}"
add_setting connectTimeoutSeconds "${CODIQO_IN_API_CONNECT_TIMEOUT:-}"
add_setting readTimeoutSeconds "${CODIQO_IN_API_READ_TIMEOUT:-}"
add_setting firstParentOnly "${CODIQO_IN_FIRST_PARENT_ONLY:-true}"
add_setting excludeRevertedCommits "${CODIQO_IN_EXCLUDE_REVERTED_COMMITS:-true}"
add_setting includeBranches "${CODIQO_IN_INCLUDE_BRANCHES:-}"
add_setting includeAuthorEmails "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}"
add_setting excludeAuthorEmails "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}"
add_setting skipOnBuildFailure "${CODIQO_IN_SKIP_ON_BUILD_FAILURE:-true}"
add_setting failOnUninstrumentedModule "${CODIQO_IN_FAIL_ON_UNINSTRUMENTED_MODULE:-true}"
add_setting testFailureHoldShare "${CODIQO_IN_TEST_FAILURE_HOLD_SHARE:-}"
add_setting testFailureHoldMinTests "${CODIQO_IN_TEST_FAILURE_HOLD_MIN_TESTS:-}"
add_setting testTimeoutMinutes "${CODIQO_TEST_TIMEOUT_MINUTES}"
add_setting perTestTimeoutMinutes "${CODIQO_PER_TEST_TIMEOUT_MINUTES}"
add_setting ignoreCoverage "${CODIQO_IN_IGNORE_COVERAGE:-false}"
add_setting ignoreComplexity "${CODIQO_IN_IGNORE_COMPLEXITY:-false}"
add_setting ignoreCpd "${CODIQO_IN_IGNORE_CPD:-false}"
add_setting ignoreDiagnostics "${CODIQO_IN_IGNORE_DIAGNOSTICS:-false}"
add_setting hotspots "${hotspots}"
add_setting hotspotsCommitId "${hotspots_commit}"
add_setting dumpAnalysis "${CODIQO_IN_DUMP_ANALYSIS:-true}"
add_setting outputDirectory "${CODIQO_IN_ANALYSIS_OUTPUT_DIRECTORY:-}"
add_setting javaHome "${CODIQO_IN_JAVA_HOME:-}"
add_setting jdtlsJavaHome "${CODIQO_IN_JDTLS_JAVA_HOME:-}"
add_setting jdtlsVersion "${CODIQO_IN_JDTLS_VERSION:-}"
add_setting jdtlsUseSnapshot "${CODIQO_IN_JDTLS_USE_SNAPSHOT:-false}"
add_setting jdtUseSharedIndex "${CODIQO_IN_JDT_USE_SHARED_INDEX:-true}"
add_setting jdtIncludeDecompiledSources "${CODIQO_IN_JDT_INCLUDE_DECOMPILED_SOURCES:-false}"
add_setting jdtLombokAgent "${CODIQO_IN_JDT_LOMBOK_AGENT:-true}"
add_setting failOnJdtlsError "${CODIQO_IN_FAIL_ON_JDTLS_ERROR:-false}"
add_setting importTimeoutMinutes "${CODIQO_IN_IMPORT_TIMEOUT_MINUTES:-}"
add_setting lspQueryTimeoutSeconds "${CODIQO_IN_LSP_QUERY_TIMEOUT_SECONDS:-}"
add_setting pmdRules "${CODIQO_IN_PMD_RULES:-}"
add_setting pmdMinPriority "${CODIQO_IN_PMD_MIN_PRIORITY:-}"
add_setting spotbugsPriorityThreshold "${CODIQO_IN_SPOTBUGS_PRIORITY_THRESHOLD:-}"
add_setting spotbugsOmitVisitors "${CODIQO_IN_SPOTBUGS_OMIT_VISITORS:-}"
add_setting cpdMinimumTileSize "${CODIQO_IN_CPD_MINIMUM_TILE_SIZE:-}"
add_setting cpdIgnoreIdentifiers "${CODIQO_IN_CPD_IGNORE_IDENTIFIERS:-}"
add_setting diffContextLines "${CODIQO_IN_DIFF_CONTEXT_LINES:-}"
add_setting buildErrorCaptureLimit "${CODIQO_IN_BUILD_ERROR_CAPTURE_LIMIT:-}"
add_setting moveDetectionEnabled "${CODIQO_IN_MOVE_DETECTION:-true}"
add_setting moveSimilarityThreshold "${CODIQO_IN_MOVE_SIMILARITY_THRESHOLD:-}"
add_setting movedLineCoefficient "${CODIQO_IN_MOVED_LINE_COEFFICIENT:-}"
add_setting driverScoreCapMultiplier "${CODIQO_IN_DRIVER_SCORE_CAP_MULTIPLIER:-}"
add_setting driverScoreCapDryRun "${CODIQO_IN_DRIVER_SCORE_CAP_DRY_RUN:-false}"
add_setting driverFactorMaxDeviation "${CODIQO_IN_DRIVER_FACTOR_MAX_DEVIATION:-}"
add_setting maxRequests "${CODIQO_IN_MAX_REQUESTS:-}"
add_setting maxRequestsPerHost "${CODIQO_IN_MAX_REQUESTS_PER_HOST:-}"
add_setting llm.autoDiscoveryAgentInstructions "${CODIQO_IN_AGENT_INSTRUCTIONS:-true}"
add_setting llm.conventionFiles "${CODIQO_IN_AGENT_INSTRUCTION_FILES:-}"
add_setting llm.conventionFilesMaxChars "${CODIQO_IN_AGENT_INSTRUCTIONS_MAX_CHARS:-}"
#
# Every analysed commit is reviewed in that commit's own checkout (the Maven goal's analysis clone,
# the workspace under Gradle), so a backlog pays for one review per commit. The proxy is reached with
# the same API key, and each review's trace (every agent session and tool call) lands beside the
# logs, so it is redacted and uploaded with them.
#
if [ "${CODIQO_REVIEW:-false}" = "true" ]; then
    add_setting review true
    add_setting review.executable "${CODIQO_OPENCODE_EXECUTABLE:?the OpenCode install step did not run}"
    add_setting review.traceDirectory "$CODIQO_LOGS_DIR/review-trace"
    add_setting review.timeoutMinutes "${CODIQO_REVIEW_TIMEOUT_MINUTES:-}"
    add_setting review.temperature "${CODIQO_IN_REVIEW_TEMPERATURE:-}"
    add_setting review.topP "${CODIQO_IN_REVIEW_TOP_P:-}"
else
    add_setting review false
fi

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
# The cause and trace of an ABORT line the plugin wrote to the commit's progress file
# (epochMillis, ABORT, cause, trace; tab-separated), or nothing when it wrote none.
#
codiqo::abort_reason() {
    local file="$1"
    if [ -n "$file" ] && [ -f "$file" ]; then
        awk -F '\t' '$2 == "ABORT" { print $3 " [" $4 "]"; exit }' "$file"
    fi
}

#
# Halts the project on the server after a failed commit, so the next scheduled run does not pay for
# the same commit's review again, and succeeds only when the server recorded the halt.
# submit-commit-analysis halts it itself when it fails inside its JVM; this covers a run killed from
# outside (the per-commit deadline, an OOM kill), which leaves no exception to report, and records
# again a halt the plugin reported, in case the plugin could not record it. The server keeps the
# first halt, so a run that halted the project keeps its own reason. Maven only: the Gradle plugin
# has no halt task yet. A failed halt is a warning, never a second failure of the commit. The call
# retries for up to 15 minutes while the server is unreachable, so it runs under the heartbeat.
#
codiqo::halt_project() {
    local commit="$1" reason="$2" log="$3" rc=0
    if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
        return 1
    fi
    local halt=("$CODIQO_BUILD_CMD" -B -ntp -N)
    halt+=(${extra_args[@]+"${extra_args[@]}"})
    halt+=(${user_props[@]+"${user_props[@]}"})
    halt+=("${plugin}:halt-project")
    halt+=("-Dcodiqo.commitId=${commit}")
    halt+=("-Dcodiqo.apiKey=env:CODIQO_API_KEY")
    halt+=("-Dcodiqo.haltReason=${reason}")
    halt+=("-Dcodiqo.haltLogFile=${log}")
    if [ -n "${CODIQO_IN_API_URL:-}" ]; then halt+=("-Dcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
    if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then halt+=("-Dcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then halt+=("-Dcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi
    codiqo::run_step "halt-${commit}" "${halt[@]}" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    codiqo::warn "commit $commit: could not halt the project (exit $rc); see halt-${commit}.log. The next scheduled run will try this commit again."
    return 1
}

#
# Stops the run because the project is halted, whatever stop-on-first-failure says: every further
# commit would fail against the halt and pay for nothing.
#
codiqo::abort_run() {
    local index="$1" total="$2" abort="$3"
    codiqo::error "aborting the run: the project is halted until an administrator resumes it in Codiqo. Cause: $abort"
    codiqo::output "abort-reason" "$abort"
    codiqo::output "analysed-count" "$analysed"
    codiqo::output "failed-count" "$failed"
    codiqo::log "$((total - index)) commit(s) left unattempted."
}

#
# One commit's outcome, shared by both build-tool branches so the counters, the messages and the
# stop rules cannot drift between them. Returns non-zero when the caller must stop.
#
codiqo::report_commit_result() {
    local commit="$1" index="$2" total="$3" rc="$4" log="$5" loop_start="$6" progress="$7"
    local reason abort
    if reason=$(codiqo::assert_build_success "$log" "$rc"); then
        analysed=$((analysed + 1))
        codiqo::log "  ok ($index/$total, ${CODIQO_LAST_ELAPSED}s, $(($(date +%s) - loop_start))s cumulative)"
        return 0
    fi

    #
    # The plugin halted the project because the analysis itself cannot work (the LLM cannot be
    # reached, coverage cannot be measured): every further commit would fail the same way and pay
    # for nothing, so the whole run stops after this commit, whatever stop-on-first-failure says.
    #
    abort=$(codiqo::abort_reason "$progress")

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
        #
        # A worker that failed after its submission was accepted (while it shut down, say) halted
        # the project all the same, and a halted project fails every later commit.
        #
        if [ -n "$abort" ]; then
            codiqo::abort_run "$index" "$total" "$abort"
            return 1
        fi
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

    #
    # A run killed from outside its JVM left the plugin no exception to halt the project with, so it
    # is halted here, and the run stops as one the plugin halted would. Any other failure without an
    # ABORT line (no credential, the server unreachable before the analysis started, a project
    # already halted, a stopped run) is one the plugin chose not to halt for, and stays unhalted.
    #
    if [ -n "$abort" ]; then
        codiqo::halt_project "$commit" "$abort" "$log" || true
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        reason="the analysis run of commit $commit exceeded the ${CODIQO_PER_COMMIT_TIMEOUT_MINUTES}m per-commit deadline or was killed (exit $rc)"
        if codiqo::halt_project "$commit" "$reason" "$log"; then
            abort="$reason [see submit-${commit}.log]"
        fi
    fi
    if [ -n "$abort" ]; then
        codiqo::abort_run "$index" "$total" "$abort"
        return 1
    fi

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
        for setting in "${settings[@]}"; do cmd+=("-P${setting}"); done
        cmd+=("-Pcodiqo.commitId=${commit}")
        if [ -n "${CODIQO_IN_ANALYSIS_MAX_HEAP:-}" ]; then cmd+=("-Pcodiqo.analysisMaxHeap=${CODIQO_IN_ANALYSIS_MAX_HEAP}"); fi

        #
        # The plugin's build service appends project progress here, in the same format the Maven
        # fork's event spy writes, for the heartbeat to report.
        #
        progress="$CODIQO_LOGS_DIR/progress-${commit}.tsv"
        rm -f "$progress"
        cmd+=("-Pcodiqo.buildProgressFile=${progress}")

        rc=0
        log="$CODIQO_LOGS_DIR/submit-${commit}.log"
        CODIQO_STEP_TIMEOUT_SECONDS="$CODIQO_PER_COMMIT_TIMEOUT_SECONDS" CODIQO_PROGRESS_FILE="$progress" \
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
        codiqo::report_commit_result "$commit" "$index" "$total" "$rc" "$log" "$loop_start" "$progress" || exit $?
        continue
    fi

    #
    # -N for the same reason as in index-commits.sh: the goal clones the commit and builds its POMs
    # itself, so the tip's modules are never needed, and an invalid one would fail every commit
    # before the goal starts. The tip commit's own breakage is then excluded like any other commit's.
    #
    cmd=("$CODIQO_BUILD_CMD" -B -ntp -e -U -N)
    if [ -n "${CODIQO_IN_MAVEN_PARALLELISM:-}" ]; then cmd+=(-T "${CODIQO_IN_MAVEN_PARALLELISM}"); fi
    if [ -n "${CODIQO_TM_EXT_CLASSPATH:-}" ]; then cmd+=("-Dmaven.ext.class.path=${CODIQO_TM_EXT_CLASSPATH}"); fi
    cmd+=(${extra_args[@]+"${extra_args[@]}"})
    cmd+=(${user_props[@]+"${user_props[@]}"})
    cmd+=("${plugin}:submit-commit-analysis")
    for setting in "${settings[@]}"; do cmd+=("-D${setting}"); done
    cmd+=("-Dcodiqo.commitId=${commit}")
    #
    # Only the Maven goal forks its own build of the commit, so only it has a time machine, a build
    # deadline, a Maven home and options for that fork, and source jars to drop before the language
    # server imports the project.
    #
    cmd+=("-Dcodiqo.timeMachineEnabled=${CODIQO_IN_TIME_MACHINE:-true}")
    cmd+=("-Dcodiqo.buildTimeoutMinutes=${CODIQO_BUILD_TIMEOUT_MINUTES}")
    if [ -n "${CODIQO_IN_MAVEN_HOME:-}" ]; then cmd+=("-Dcodiqo.mavenHome=${CODIQO_IN_MAVEN_HOME}"); fi
    if [ -n "${CODIQO_IN_FORK_MAVEN_OPTS:-}" ]; then cmd+=("-Dcodiqo.forkMavenOpts=${CODIQO_IN_FORK_MAVEN_OPTS}"); fi
    if [ -n "${CODIQO_IN_JDT_SOURCE_EXCLUSIONS:-}" ]; then cmd+=("-Dcodiqo.jdtSourceExclusions=${CODIQO_IN_JDT_SOURCE_EXCLUSIONS}"); fi

    #
    # The forked build's event spy appends module progress here for the heartbeat to report.
    # It sits beside the commit's log so the upload keeps each module's duration as well.
    #
    progress="$CODIQO_LOGS_DIR/progress-${commit}.tsv"
    rm -f "$progress"
    cmd+=("-Dcodiqo.buildProgressFile=${progress}")

    rc=0
    log="$CODIQO_LOGS_DIR/submit-${commit}.log"
    CODIQO_STEP_TIMEOUT_SECONDS="$CODIQO_PER_COMMIT_TIMEOUT_SECONDS" CODIQO_PROGRESS_FILE="$progress" \
        codiqo::run_step "submit-${commit}" "${cmd[@]}" || rc=$?
    codiqo::emit_log_warnings "$log"
    codiqo::report_commit_result "$commit" "$index" "$total" "$rc" "$log" "$loop_start" "$progress" || exit $?
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
