#!/usr/bin/env bash
#
# Ask the backend which commits still need analysis. This must run before any submission:
# the backend rejects a sha it has never seen indexed.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

plugin="io.codiqo:codiqo-maven-plugin:${CODIQO_IN_VERSION}"
codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/mvn-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/mvn-props"

cmd=("$CODIQO_MVN" -B -ntp -e -U)
cmd+=(${extra_args[@]+"${extra_args[@]}"})
cmd+=(${user_props[@]+"${user_props[@]}"})
cmd+=("${plugin}:index-commits")
#
# env: indirection keeps the key out of the process table and out of any Maven echo of the
# command line; the plugin resolves it via io.codiqo.util.Env.
#
cmd+=("-Dcodiqo.apiKey=env:CODIQO_API_KEY")
cmd+=("-Dcodiqo.commitWindow=${CODIQO_COMMIT_WINDOW}")
cmd+=("-Dcodiqo.firstParentOnly=${CODIQO_IN_FIRST_PARENT_ONLY:-true}")
cmd+=("-Dcodiqo.missingAnalysesOutputFile=${CODIQO_MISSING_FILE}")

if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Dcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
if [ -n "${CODIQO_BRANCH:-}" ]; then cmd+=("-Dcodiqo.branch=${CODIQO_BRANCH}"); fi
if [ -n "${CODIQO_IN_INCLUDE_BRANCHES:-}" ]; then cmd+=("-Dcodiqo.includeBranches=${CODIQO_IN_INCLUDE_BRANCHES}"); fi
if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
if [ -n "${CODIQO_IN_MAX_COMMITS:-}" ]; then cmd+=("-Dcodiqo.missingAnalysesLimit=${CODIQO_IN_MAX_COMMITS}"); fi
if [ -n "${CODIQO_IN_INDEX_BATCH_SIZE:-}" ]; then cmd+=("-Dcodiqo.indexBatchSize=${CODIQO_IN_INDEX_BATCH_SIZE}"); fi
if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi

rc=0
codiqo::run_maven_step "codiqo-index" "${cmd[@]}" || rc=$?
codiqo::emit_log_warnings "$CODIQO_LOGS_DIR/codiqo-index.log"

if ! reason=$(codiqo::assert_build_success "$CODIQO_LOGS_DIR/codiqo-index.log" "$rc"); then
    codiqo::error "index-commits $reason"
    codiqo::tail_log "$CODIQO_LOGS_DIR/codiqo-index.log"
    exit 1
fi

missing_count=0
if [ -f "$CODIQO_MISSING_FILE" ]; then
    missing_count=$(sed 's/[[:space:]]//g' "$CODIQO_MISSING_FILE" | grep -c -v '^$' || true)
fi

codiqo::output "missing-count" "$missing_count"
codiqo::output "missing-file" "$CODIQO_MISSING_FILE"

if [ "$missing_count" -eq 0 ]; then
    codiqo::log "no commits require analysis."
    #
    # A zero here is normal on a quiet repository, but it is also what an incomplete clone
    # produces, so point at that explicitly rather than leaving a silent success.
    #
    codiqo::log "if that is unexpected, check that actions/checkout used fetch-depth: 0 and that commit-window covers the commits you expect."
else
    codiqo::log "$missing_count commit(s) require analysis (oldest first)."
fi
