#!/usr/bin/env bash
set -euo pipefail

# submit.sh - queue the whole run: one array job, then one cohort job that
# starts only if every array task succeeded.
#
#   ./slurm/submit.sh [samplesheet.csv] [outdir]
#
# Submits and returns; it does not wait. Track it with `squeue -u "$USER"`.

SUBMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SUBMIT_DIR"

source slurm/conf/slurm.env

SHEET="${1:-$SAMPLESHEET_FILE}"
OUT="${2:-$PIPELINE_OUTDIR}"

if [[ ! -f "$SHEET" ]]; then
    echo "$0: samplesheet not found: $SHEET" >&2
    exit 1
fi

command -v sbatch >/dev/null 2>&1 || {
    echo "$0: sbatch not found - this script only runs on the cluster." >&2
    exit 1
}

# Slurm creates each job's --output/--error file before the job script runs.
# If logs/ does not exist at that moment the task fails immediately, with the
# reason written nowhere observable. Create it here, at submit time.
mkdir -p logs

# --- array size is DERIVED from the sheet, never a literal ---
# Counting data rows means adding a ninth sample needs no edit to any script.
# Blank trailing lines are excluded so a stray newline cannot create a task
# with no row to process.
N_SAMPLES=$(awk 'NR>1 && NF>0' "$SHEET" | wc -l)
if (( N_SAMPLES < 1 )); then
    echo "$0: no data rows in $SHEET - nothing to submit." >&2
    exit 1
fi

ARRAY_SPEC="1-${N_SAMPLES}"
[[ -n "${ARRAY_THROTTLE:-}" ]] && ARRAY_SPEC="${ARRAY_SPEC}%${ARRAY_THROTTLE}"

echo "submitting: ${N_SAMPLES} sample(s) from ${SHEET} -> ${OUT}" >&2

# --parsable prints just the job id, which is the whole reason the dependency
# below can be wired up without parsing human-readable text.
ARRAY_ID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --array="$ARRAY_SPEC" \
    --cpus-per-task="$PERSAMPLE_CPUS" \
    --mem="$PERSAMPLE_MEM" \
    --time="$PERSAMPLE_TIME" \
    slurm/01_persample.sbatch)

echo "  array job:  ${ARRAY_ID}  (${ARRAY_SPEC})" >&2

# afterok, not afterany: the cohort stages joint-call across every sample, so
# starting them when a task FAILED would silently produce a cohort VCF with a
# sample missing rather than an error.
#
# --kill-on-invalid-dep=yes because the default is to leave the dependent job
# queued forever in DependencyNeverSatisfied once the array fails. Cancelling
# it is both honest and polite to everyone else in the queue.
COHORT_ID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --cpus-per-task="$COHORT_CPUS" \
    --mem="$COHORT_MEM" \
    --time="$COHORT_TIME" \
    --dependency=afterok:"$ARRAY_ID" \
    --kill-on-invalid-dep=yes \
    slurm/02_cohort.sbatch)

echo "  cohort job: ${COHORT_ID}  (afterok:${ARRAY_ID})" >&2
echo "track with: squeue -u \"\$USER\"" >&2
