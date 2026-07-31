#!/usr/bin/env bash
#
# Warm the local repository before any commit is analysed.
#
# Optional, and off by default, because dependency:go-offline is famously imperfect — it misses
# dependencies only reachable through a plugin, and some reactors make it fail outright. Where it
# does work it earns its keep twice over: the per-commit builds stop competing for the same
# downloads, and a broken or unreachable repository surfaces here in one clear step rather than as a
# confusing build failure inside the first commit.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/mvn-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/mvn-props"

cmd=("$CODIQO_MVN" -B -ntp -e -U)
cmd+=(${extra_args[@]+"${extra_args[@]}"})
cmd+=(${user_props[@]+"${user_props[@]}"})
cmd+=(dependency:go-offline)

rc=0
codiqo::run_maven_step "maven-resolve-deps" "${cmd[@]}" || rc=$?
codiqo::emit_log_warnings "$CODIQO_LOGS_DIR/maven-resolve-deps.log"

#
# The BUILD SUCCESS assertion matters here specifically: go-offline can exit 0 having quietly
# skipped artifacts it could not resolve.
#
if ! reason=$(codiqo::assert_build_success "$CODIQO_LOGS_DIR/maven-resolve-deps.log" "$rc"); then
    codiqo::error "dependency:go-offline $reason."
    codiqo::log "if this project cannot be resolved offline, set resolve-dependencies: false — the per-commit builds resolve what they need anyway."
    codiqo::tail_log "$CODIQO_LOGS_DIR/maven-resolve-deps.log"
    exit 1
fi

codiqo::log "local repository warmed in ${CODIQO_LAST_ELAPSED}s."
