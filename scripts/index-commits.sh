#!/usr/bin/env bash
#
# Ask the backend which commits still need analysis. This must run before any submission:
# the backend rejects a sha it has never seen indexed.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

extra_args=()
codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/build-args"
user_props=()
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/build-props"

#
# env: indirection keeps the key out of the process table and out of any echo of the command
# line; both plugins resolve it via io.codiqo.util.Env.
#
if [ "${CODIQO_BUILD_TOOL:-maven}" = "gradle" ]; then
    cmd=("$CODIQO_BUILD_CMD" --console=plain --init-script "$CODIQO_GRADLE_INIT")
    cmd+=(${extra_args[@]+"${extra_args[@]}"})
    #
    # The project properties belong on this invocation too, not only on the submit one: a build
    # whose settings.gradle needs -PbuildEnv=ci to configure cannot even be evaluated without them,
    # and indexing is the first Gradle run of the job.
    #
    cmd+=(${user_props[@]+"${user_props[@]}"})
    cmd+=("codiqoIndexCommits")
    cmd+=("-Pcodiqo.apiKey=env:CODIQO_API_KEY")
    cmd+=("-Pcodiqo.commitWindow=${CODIQO_COMMIT_WINDOW}")
    cmd+=("-Pcodiqo.firstParentOnly=${CODIQO_IN_FIRST_PARENT_ONLY:-true}")
    cmd+=("-Pcodiqo.indexOutputFile=${CODIQO_MISSING_FILE}")
    cmd+=("-Pcodiqo.indexMetadataFile=${CODIQO_METADATA_FILE}")

    if [ -n "${CODIQO_IN_JDTLS_VERSION:-}" ]; then cmd+=("-Pcodiqo.jdtlsVersion=${CODIQO_IN_JDTLS_VERSION}"); fi
    if [ "${CODIQO_IN_JDTLS_USE_SNAPSHOT:-false}" = "true" ]; then cmd+=("-Pcodiqo.jdtlsUseSnapshot=true"); fi

    if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Pcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
    if [ -n "${CODIQO_BRANCH:-}" ]; then cmd+=("-Pcodiqo.branch=${CODIQO_BRANCH}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_BRANCHES:-}" ]; then cmd+=("-Pcodiqo.includeBranches=${CODIQO_IN_INCLUDE_BRANCHES}"); fi
    if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Pcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Pcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_MAX_COMMITS:-}" ]; then cmd+=("-Pcodiqo.missingAnalysesLimit=${CODIQO_IN_MAX_COMMITS}"); fi
    if [ -n "${CODIQO_IN_INDEX_REF:-}" ]; then cmd+=("-Pcodiqo.indexRef=${CODIQO_IN_INDEX_REF}"); fi
    if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Pcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Pcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi
else
    plugin="io.codiqo:codiqo-maven-plugin:${CODIQO_IN_VERSION}"

    #
    # -N because the goal needs only the root POM's identity, and Maven otherwise reads every
    # module of the checked-out tip before any goal runs, whatever the goal declares. One invalid
    # module POM at the tip (a duplicate dependency, say) then failed the whole job, so not even
    # the healthy historical commits were indexed.
    #
    cmd=("$CODIQO_BUILD_CMD" -B -ntp -e -U -N)
    cmd+=(${extra_args[@]+"${extra_args[@]}"})
    cmd+=(${user_props[@]+"${user_props[@]}"})
    cmd+=("${plugin}:index-commits")
    cmd+=("-Dcodiqo.apiKey=env:CODIQO_API_KEY")
    cmd+=("-Dcodiqo.commitWindow=${CODIQO_COMMIT_WINDOW}")
    cmd+=("-Dcodiqo.firstParentOnly=${CODIQO_IN_FIRST_PARENT_ONLY:-true}")
    cmd+=("-Dcodiqo.missingAnalysesOutputFile=${CODIQO_MISSING_FILE}")
    cmd+=("-Dcodiqo.indexMetadataFile=${CODIQO_METADATA_FILE}")

    if [ -n "${CODIQO_IN_JDTLS_VERSION:-}" ]; then cmd+=("-Dcodiqo.jdtlsVersion=${CODIQO_IN_JDTLS_VERSION}"); fi
    if [ "${CODIQO_IN_JDTLS_USE_SNAPSHOT:-false}" = "true" ]; then cmd+=("-Dcodiqo.jdtlsUseSnapshot=true"); fi

    if [ -n "${CODIQO_IN_API_URL:-}" ]; then cmd+=("-Dcodiqo.apiUrl=${CODIQO_IN_API_URL}"); fi
    if [ -n "${CODIQO_BRANCH:-}" ]; then cmd+=("-Dcodiqo.branch=${CODIQO_BRANCH}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_BRANCHES:-}" ]; then cmd+=("-Dcodiqo.includeBranches=${CODIQO_IN_INCLUDE_BRANCHES}"); fi
    if [ -n "${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.excludeAuthorEmails=${CODIQO_IN_EXCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_INCLUDE_AUTHOR_EMAILS:-}" ]; then cmd+=("-Dcodiqo.includeAuthorEmails=${CODIQO_IN_INCLUDE_AUTHOR_EMAILS}"); fi
    if [ -n "${CODIQO_IN_MAX_COMMITS:-}" ]; then cmd+=("-Dcodiqo.missingAnalysesLimit=${CODIQO_IN_MAX_COMMITS}"); fi
    if [ -n "${CODIQO_IN_INDEX_BATCH_SIZE:-}" ]; then cmd+=("-Dcodiqo.indexBatchSize=${CODIQO_IN_INDEX_BATCH_SIZE}"); fi
    if [ -n "${CODIQO_IN_INDEX_REF:-}" ]; then cmd+=("-Dcodiqo.indexRef=${CODIQO_IN_INDEX_REF}"); fi
    if [ -n "${CODIQO_IN_API_CONNECT_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.connectTimeoutSeconds=${CODIQO_IN_API_CONNECT_TIMEOUT}"); fi
    if [ -n "${CODIQO_IN_API_READ_TIMEOUT:-}" ]; then cmd+=("-Dcodiqo.readTimeoutSeconds=${CODIQO_IN_API_READ_TIMEOUT}"); fi
fi

rc=0
codiqo::run_step "codiqo-index" "${cmd[@]}" || rc=$?

#
# This is the first step to download the Codiqo plugin. A snapshot being published at that moment
# can leave its metadata pointing at jars the repository does not serve yet, and the step fails to
# resolve the plugin. Only that failure is retried, once, after the publish has had time to finish;
# any other failure stops the job as before.
#
if [ "$rc" -ne 0 ] && grep -qE "(Plugin|Could not find artifact|Could not resolve).*io\.codiqo[.:]codiqo-(maven|gradle)-plugin" "$CODIQO_LOGS_DIR/codiqo-index.log"; then
    codiqo::warn "the Codiqo plugin could not be downloaded, likely while a new snapshot was being published; retrying in 2 minutes."
    sleep 120
    rc=0
    codiqo::run_step "codiqo-index" "${cmd[@]}" || rc=$?
fi
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

#
# The plugin reports the language-server version the analysis will use, so the download cache can be
# keyed on the version itself rather than on the jdtls-version input alone: with the input unset every
# plugin default change would otherwise leave the stale archive in the cache and download the new one
# on every ephemeral runner. An old plugin writes no file, and the action then falls back to the input.
#
resolved_jdtls_version=""
if [ -f "$CODIQO_METADATA_FILE" ]; then
    resolved_jdtls_version=$(grep -E '^jdtlsVersion=[A-Za-z0-9._-]+$' "$CODIQO_METADATA_FILE" | tail -1 | cut -d= -f2-)
fi
codiqo::output "resolved-jdtls-version" "$resolved_jdtls_version"

if [ "$missing_count" -eq 0 ]; then
    codiqo::log "no commits require analysis."
    #
    # A zero here is normal on a quiet repository, but it is also what an incomplete clone
    # produces, so point at that explicitly rather than leaving a silent success.
    #
    codiqo::log "if that is unexpected, check the clone holds every commit ($(codiqo::full_history_hint)) and that commit-window covers the commits you expect."
else
    codiqo::log "$missing_count commit(s) require analysis (oldest first)."
fi
