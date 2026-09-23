#!/usr/bin/env bash
set -euo pipefail

# run_cohort.sh <samplesheet.csv> <outdir> [last_stage]
#
# Stages 6-9 (merge .. publish), once, for the whole cohort. Reads whatever the
# per-sample array already wrote into the shared outdir - it runs no per-sample
# work of its own and re-does nothing.
#
# ONLY_SAMPLE_ID is deliberately NOT set here, and is actively cleared below.
# Every stage in this half needs all eight samples at once: joint genotyping
# over a filtered cohort would silently produce a VCF with the other samples
# missing rather than failing, which is the worst possible outcome.

usage() {
    echo "Usage: $0 <samplesheet.csv> <outdir> [last_stage]" >&2
    echo "       cohort stages: ${COHORT_STAGES[*]:-merge analyze qc_report publish}" >&2
    exit 1
}

(( $# >= 2 && $# <= 3 )) || usage

SAMPLESHEET="$1"
OUTDIR="$2"
LAST_STAGE="${3:-publish}"

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pipeline_lib.sh
source "$DRIVER_DIR/lib/pipeline_lib.sh"

# Never inherit a per-sample filter, even if the caller's environment carries
# one over from a previous run_sample.sh invocation in the same shell.
unset ONLY_SAMPLE_ID

# --- decline the per-sample stages ---
# These are the array's work and have already run, once per sample, in
# parallel. Re-running them here would serialize eight samples into one job.
if in_list "$LAST_STAGE" "${PER_SAMPLE_STAGES[@]}"; then
    echo "$0: '$LAST_STAGE' is a per-sample stage and does not belong in the cohort job." >&2
    echo "       Per-sample stages (${PER_SAMPLE_STAGES[*]}) run once per sample," >&2
    echo "       in parallel, as the job array." >&2
    echo "       Use: ./run_sample.sh <samplesheet.csv> <outdir> <sample_id> $LAST_STAGE" >&2
    exit 1
fi

if ! in_list "$LAST_STAGE" "${COHORT_STAGES[@]}"; then
    echo "$0: unknown stage '$LAST_STAGE'" >&2
    echo "       cohort stages: ${COHORT_STAGES[*]}" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# Read the sheet up front so a missing or malformed samplesheet is an error
# here, not three stages later.
read_samples
log "run_cohort: ${#SAMPLE_IDS[@]} sample(s) in the cohort"

run_stage_range "$LAST_STAGE" "${COHORT_STAGES[@]}"
