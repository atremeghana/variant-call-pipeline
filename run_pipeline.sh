#!/usr/bin/env bash
set -euo pipefail

# run_pipeline.sh <samplesheet.csv> <outdir> [last_stage]
#
# Positional interface (matches the acceptance harness and the week-1 demo):
#   ./run_pipeline.sh samplesheet.csv out validate   # stop after stage 0
#   ./run_pipeline.sh samplesheet.csv out            # all ten stages
#
# The third argument is optional and defaults to the final stage, because the
# brief's smoke-run command omits it:
#
#   REF=$PWD/smoke.fa REGION=smoke_1mb bash run_pipeline.sh samplesheet.csv out
#
# REF and REGION are read by lib/pipeline_lib.sh, which maps them onto
# REFERENCE_FASTA and CALL_REGION; see the precedence note there.
#
# Every sample, stages 0-9, in one process. This is the laptop / single-node
# path and the interface the assignment-1 acceptance suite grades.
#
# The stage implementations now live in lib/pipeline_lib.sh so that
# run_sample.sh (one Slurm array task) and run_cohort.sh (the joint-calling
# job) call the identical functions. This file is only a driver.

usage() {
    echo "Usage: $0 <samplesheet.csv> <outdir> [last_stage]" >&2
    exit 1
}

[[ $# -eq 2 || $# -eq 3 ]] || usage

SAMPLESHEET="$1"
OUTDIR="$2"
LAST_STAGE="${3:-}"

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pipeline_lib.sh
source "$DRIVER_DIR/lib/pipeline_lib.sh"

# Defaulted only after the library is sourced, because STAGES lives there.
LAST_STAGE="${LAST_STAGE:-${STAGES[$(( ${#STAGES[@]} - 1 ))]}}"

# An unrecognized stage name never matches the main loop's break condition, so
# without this guard a typo ('validat') silently runs the ENTIRE pipeline -
# hours of alignment instead of an error in the first second.
if ! in_list "$LAST_STAGE" "${STAGES[@]}"; then
    echo "$0: unknown stage '$LAST_STAGE'" >&2
    echo "       valid stages: ${STAGES[*]}" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

run_stage_range "$LAST_STAGE" "${STAGES[@]}"
