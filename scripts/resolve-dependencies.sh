#!/usr/bin/env bash
#
# Warm the local repository before any commit is analysed.
#
# Optional, and off by default, because dependency:go-offline is famously imperfect — it misses
# dependencies only reachable through a plugin, and some reactors make it fail outright. Where it
# does work it earns its keep twice over: the per-commit builds stop competing for the same
# downloads, and a broken or unreachable repository surfaces here as one clear warning rather than as a
# confusing build failure inside the first commit.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

codiqo::read_lines_into extra_args "$CODIQO_WORK_DIR/build-args"
codiqo::read_lines_into user_props "$CODIQO_WORK_DIR/build-props"

cmd=("$CODIQO_BUILD_CMD" -B -ntp -e -U)
cmd+=(${extra_args[@]+"${extra_args[@]}"})
cmd+=(${user_props[@]+"${user_props[@]}"})
cmd+=(dependency:go-offline)

rc=0
codiqo::run_step "maven-resolve-deps" "${cmd[@]}" || rc=$?
codiqo::emit_log_warnings "$CODIQO_LOGS_DIR/maven-resolve-deps.log"

#
# The BUILD SUCCESS assertion matters here specifically: go-offline can exit 0 having quietly
# skipped artifacts it could not resolve.
#
# A failure is a warning, not the end of the job: it reflects the tip alone, and an invalid POM
# there would otherwise block every historical commit. The per-commit builds resolve what they need
# anyway, and a commit that cannot be resolved is excluded on its own.
#
if reason=$(codiqo::assert_build_success "$CODIQO_LOGS_DIR/maven-resolve-deps.log" "$rc"); then
    codiqo::log "local repository warmed in ${CODIQO_LAST_ELAPSED}s."
else
    codiqo::warn "dependency:go-offline $reason; continuing without a warmed local repository."
    codiqo::tail_log "$CODIQO_LOGS_DIR/maven-resolve-deps.log"
fi
