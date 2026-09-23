#!/usr/bin/env bash
set -euo pipefail

# run_sample.sh <samplesheet.csv> <outdir> <sample_id> [last_stage]
#
# ONE sample, stages 0-5 (validate .. quantify). This is what a single Slurm
# array task runs: the array supplies the sample_id, every task writes into the
# same shared outdir under its own sample directory, and nothing here knows or
# cares that seven siblings are running at the same time.
#
# It deliberately REFUSES the cohort stages. merge, analyze, qc_report and
# publish read every sample's output at once; running them inside an array task
# would have eight tasks racing to joint-call the same cohort from an
# incomplete set of GVCFs. Those belong to run_cohort.sh, which the scheduler
# starts only after the whole array succeeds.

usage() {
    echo "Usage: $0 <samplesheet.csv> <outdir> <sample_id> [last_stage]" >&2
    echo "       per-sample stages: ${PER_SAMPLE_STAGES[*]:-validate qc_raw trim align postprocess quantify}" >&2
    exit 1
}

(( $# >= 3 && $# <= 4 )) || usage

SAMPLESHEET="$1"
OUTDIR="$2"
ONLY_SAMPLE_ID="$3"
LAST_STAGE="${4:-quantify}"

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pipeline_lib.sh
source "$DRIVER_DIR/lib/pipeline_lib.sh"

# Restricts every per-sample stage to this one row. read_samples() applies it.
export ONLY_SAMPLE_ID

if [[ -z "$ONLY_SAMPLE_ID" ]]; then
    echo "$0: sample_id must not be empty" >&2
    exit 1
fi

# --- decline the cohort stages explicitly, rather than just not offering them ---
# Silently ignoring the request would leave the caller believing a cohort stage
# had run. Say why, and point at the script that does it.
if in_list "$LAST_STAGE" "${COHORT_STAGES[@]}"; then
    echo "$0: '$LAST_STAGE' is a cohort stage and cannot run inside a per-sample task." >&2
    echo "       Cohort stages (${COHORT_STAGES[*]}) need every sample's output," >&2
    echo "       so running one here would joint-call an incomplete cohort." >&2
    echo "       Use: ./run_cohort.sh <samplesheet.csv> <outdir> $LAST_STAGE" >&2
    exit 1
fi

if ! in_list "$LAST_STAGE" "${PER_SAMPLE_STAGES[@]}"; then
    echo "$0: unknown stage '$LAST_STAGE'" >&2
    echo "       per-sample stages: ${PER_SAMPLE_STAGES[*]}" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# Prove the sample exists BEFORE any stage runs, whichever stage was asked for.
# stage_validate parses the whole sheet itself and never calls read_samples(),
# so asking only for 'validate' would otherwise accept a sample_id that is not
# in the sheet at all and report a cheerful success.
log "run_sample: restricting to sample '$ONLY_SAMPLE_ID'"
read_samples
log "run_sample: matched ${#SAMPLE_IDS[@]} row(s) for '$ONLY_SAMPLE_ID'"

run_stage_range "$LAST_STAGE" "${PER_SAMPLE_STAGES[@]}"
