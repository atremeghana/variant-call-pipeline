#!/usr/bin/env bash
set -euo pipefail

# submit.sh - queue the whole run: one array job, then one cohort job that
# starts only if every array task succeeded.
#
#   bash slurm/submit.sh           all samples in the sheet
#   bash slurm/submit.sh 1-2       just the first two, to check it works
#
# Submits and returns; it does not wait. Track it with `squeue -u "$USER"`.
#
# WHAT IS CONFIGURED WHERE
#   slurm/conf/slurm.env   the sheet, the account, the partition, RUN_ROOT,
#                          PIPELINE_DIR and the three allocation sizes
#   conf/pipeline.env      the reference and the call region
# Nothing is configured here. This file only wires two sbatch calls together.

# cd into THIS directory, not the repository root, and submit the .sbatch files
# by their bare names.
#
# That is what makes $SLURM_SUBMIT_DIR inside both jobs equal to slurm/, which
# is the whole contract they rely on: they look for conf/slurm.env beside
# themselves and write logs/ there. Submitting `slurm/01_persample.sbatch` from
# the repository root instead would set $SLURM_SUBMIT_DIR to the root, where
# conf/ is conf/pipeline.env's directory and holds no slurm.env at all - so the
# guard at the top of each .sbatch would fire and the job would exit 78.
#
# Doing the cd here also means this script works from anywhere: `bash
# slurm/submit.sh`, `./submit.sh` from inside slurm/, or an absolute path from
# a cron job all behave identically.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

if [[ ! -s conf/slurm.env ]]; then
    echo "$0: no conf/slurm.env beside this script" >&2
    exit 78            # EX_CONFIG
fi
# shellcheck source=conf/slurm.env
source conf/slurm.env

command -v sbatch >/dev/null 2>&1 || {
    echo "$0: sbatch not found - this script only runs on the cluster." >&2
    exit 1
}

if [[ ! -f "$SAMPLESHEET" ]]; then
    echo "$0: samplesheet not found: $SAMPLESHEET" >&2
    echo "       (set SAMPLESHEET in conf/slurm.env)" >&2
    exit 1
fi

if [[ ! -x "$PIPELINE_DIR/run_sample.sh" && ! -f "$PIPELINE_DIR/run_sample.sh" ]]; then
    echo "$0: no run_sample.sh under PIPELINE_DIR: $PIPELINE_DIR" >&2
    echo "       (set PIPELINE_DIR in conf/slurm.env to where you cloned the repo)" >&2
    exit 1
fi

# Slurm creates each job's --output/--error file before the job script runs. If
# logs/ does not exist at that moment the task fails immediately and the reason
# is written nowhere observable. Create it here, at submit time, in the same
# directory the jobs will resolve `logs/` against.
mkdir -p logs

# --- array size is DERIVED from the sheet, never a literal -------------------
# Counting data rows means adding a ninth sample needs no edit to any script.
# Blank trailing lines are excluded so a stray newline cannot create a task with
# no row to process - which 01_persample.sbatch would then refuse, correctly but
# pointlessly. An explicit range on the command line wins, for a smoke submit.
if [[ -n "${1:-}" ]]; then
    ARRAY_SPEC="$1"
    echo "array range given on the command line: ${ARRAY_SPEC}" >&2
else
    N_SAMPLES=$(awk 'NR>1 && NF>0' "$SAMPLESHEET" | wc -l)
    if (( N_SAMPLES < 1 )); then
        echo "$0: no data rows in $SAMPLESHEET - nothing to submit." >&2
        exit 1
    fi
    ARRAY_SPEC="1-${N_SAMPLES}"
    if [[ -n "${ARRAY_THROTTLE:-}" ]]; then
        ARRAY_SPEC="${ARRAY_SPEC}%${ARRAY_THROTTLE}"
    fi
fi

echo "sheet:    ${SAMPLESHEET}" >&2
echo "pipeline: ${PIPELINE_DIR}" >&2
echo "outdir:   ${RUN_ROOT}/run" >&2
echo >&2

# --parsable prints just the job id, which is the whole reason the dependency
# below can be wired up without parsing human-readable text.
ARRAY_ID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --array="$ARRAY_SPEC" \
    --cpus-per-task="$PERSAMPLE_CPUS" \
    --mem="$PERSAMPLE_MEM" \
    --time="$PERSAMPLE_TIME" \
    01_persample.sbatch)

echo "  array job:  ${ARRAY_ID}  (${ARRAY_SPEC})" >&2

# afterok, not afterany: the cohort stages joint-call across every sample, so
# starting them when a task FAILED would silently produce a cohort VCF with a
# sample missing rather than an error.
#
# --kill-on-invalid-dep=yes because the default is to leave the dependent job
# queued forever in DependencyNeverSatisfied once the array fails. Cancelling it
# is both honest and polite to everyone else in the queue.
COHORT_ID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --cpus-per-task="$COHORT_CPUS" \
    --mem="$COHORT_MEM" \
    --time="$COHORT_TIME" \
    --dependency=afterok:"$ARRAY_ID" \
    --kill-on-invalid-dep=yes \
    02_cohort.sbatch)

echo "  cohort job: ${COHORT_ID}  (afterok:${ARRAY_ID})" >&2
echo >&2
echo "watch:    squeue -u \"\$USER\"" >&2
echo "measure:  seff ${ARRAY_ID}_1 ; seff ${COHORT_ID}" >&2
echo "logs:     ${HERE}/logs/" >&2
