#!/usr/bin/env bash
#
# Write a short run summary to the job summary page, so the outcome is visible without
# downloading the log artifact.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$GITHUB_ACTION_PATH/scripts/lib.sh"

if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
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

    if [ "$missing" = "0" ]; then
        printf 'No commits required analysis. If that is unexpected, confirm `actions/checkout` used `fetch-depth: 0` — an incomplete clone makes Codiqo skip commits whose parent is missing locally.\n'
    elif [ "$failed" != "0" ]; then
        printf 'Some commits failed. The per-commit logs are in the `%s` artifact.\n' "${CODIQO_IN_LOG_ARTIFACT_NAME:-codiqo-analyze-logs}"
    fi
} >> "$GITHUB_STEP_SUMMARY"
