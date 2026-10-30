#!/usr/bin/env bash
#
# Write a short run summary to the job summary page, so the outcome is visible without
# downloading the log artifact.
#
# The backticks in the printf formats below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

summary_file="${CODIQO_SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"
if [ -z "$summary_file" ]; then
    exit 0
fi

missing="${CODIQO_SUMMARY_MISSING:-0}"
analysed="${CODIQO_SUMMARY_ANALYSED:-0}"
failed="${CODIQO_SUMMARY_FAILED:-0}"

{
    printf '## Codiqo analysis\n\n'
    printf '| | |\n|---|---|\n'
    printf '| Plugin | `%s` |\n' "${CODIQO_IN_VERSION:-unknown}"
    printf '| Branch | `%s` |\n' "${CODIQO_BRANCH:-auto-detected}"
    printf '| Commit window | `%s` |\n' "${CODIQO_COMMIT_WINDOW:-unknown}"
    printf '| Commits pending | %s |\n' "$missing"
    printf '| Analysed | %s |\n' "$analysed"
    printf '| Failed | %s |\n' "$failed"
    printf '\n'

    if [ -n "${CODIQO_SUMMARY_ABORT:-}" ]; then
        printf '**The run was aborted:** the project is halted until an administrator resumes it in Codiqo.\n\n'
        # a fenced block, not a code span: an exception message can carry a backtick of its own
        printf 'Cause:\n\n```\n%s\n```\n\n' "$CODIQO_SUMMARY_ABORT"
    fi
    if [ "$missing" = "0" ]; then
        printf 'No commits required analysis. If that is unexpected, check the clone holds every commit (%s) — an incomplete clone makes Codiqo skip commits whose parent is missing locally.\n' "$(codiqo::full_history_hint)"
    elif [ "$failed" != "0" ]; then
        printf 'Some commits failed. The per-commit logs are in the `%s` artifact.\n' "${CODIQO_IN_LOG_ARTIFACT_NAME:-codiqo-analyze-logs}"
    fi
} >> "$summary_file"
