#!/usr/bin/env bash
#SBATCH --job-name=vc-persample
#SBATCH --array=1-8
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=logs/persample_%A_%a.out
#SBATCH --error=logs/persample_%A_%a.err
#SBATCH --export=NONE
set -euo pipefail

# One array task = one sample, stages 0-5. submit.sh overrides the --array
# range and the resource directives above from slurm/conf/slurm.env.
#
# This script schedules; it does not analyse. The only thing it executes is
# run_sample.sh, which is the same code path the laptop driver uses.
#
# --export=NONE means the job starts from a clean environment rather than
# inheriting whatever happened to be set in the submitting shell. Anything the
# run needs is established here, explicitly.

# sbatch runs a COPY of this script from a spool directory, so $0 and
# $(dirname "$0") point somewhere useless. SLURM_SUBMIT_DIR is the directory
# the job was submitted from, which is the repo root.
cd "$SLURM_SUBMIT_DIR"

# Slurm opens the --output/--error files before this script runs, so logs/ has
# to exist at SUBMIT time (submit.sh creates it). Repeated here so that a
# hand-run `sbatch slurm/01_persample.sbatch` still works.
mkdir -p logs

source slurm/conf/slurm.env

SAMPLESHEET="${SLURM_SUBMIT_DIR}/${SAMPLESHEET_FILE}"
OUTDIR="${SLURM_SUBMIT_DIR}/${PIPELINE_OUTDIR}"

# --- pick this task's row: task 1 -> first data row (line 2) ---
sample_id=$(awk -F',' -v n="$SLURM_ARRAY_TASK_ID" 'NR==n+1{print $1}' "$SAMPLESHEET")

# An array range wider than the samplesheet yields an empty id here. Refusing
# is the point: a task that quietly does nothing still exits 0, the dependency
# is satisfied, and the cohort job runs on a cohort that is missing a sample.
if [[ -z "$sample_id" ]]; then
    echo "array task ${SLURM_ARRAY_TASK_ID} has no row in ${SAMPLESHEET}" >&2
    echo "       the sheet has $(( $(wc -l < "$SAMPLESHEET") - 1 )) data row(s);" >&2
    echo "       the --array range is wider than the cohort. Refusing to run." >&2
    exit 1
fi

# Threads come from what the scheduler actually granted, never a literal. Ask
# for 8 and hardcode 4 and half the allocation idles; the reverse oversubscribes
# the node and every job on it slows down.
export THREADS="$SLURM_CPUS_PER_TASK"

# Node-local scratch, unique per task, removed on any exit - including failure
# and scancel. Left behind, these fill the node and the next job on it fails
# for reasons that have nothing to do with the next job.
export TMPDIR="/tmp/${SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

echo "task ${SLURM_ARRAY_TASK_ID}: sample=${sample_id} threads=${THREADS} tmpdir=${TMPDIR}" >&2

bash ./run_sample.sh "$SAMPLESHEET" "$OUTDIR" "$sample_id"
