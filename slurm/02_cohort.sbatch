#!/usr/bin/env bash
#SBATCH --job-name=vc-cohort
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --time=02:00:00
#SBATCH --output=logs/cohort_%j.out
#SBATCH --error=logs/cohort_%j.err
#SBATCH --export=NONE
set -euo pipefail

# Stages 6-9, once, over every sample. Submitted by submit.sh with
# --dependency=afterok on the array, so by the time this starts every
# per-sample task has succeeded and the shared outdir is complete.
#
# Same rule as the array script: this file schedules, it does not analyse. The
# only thing it executes is run_cohort.sh.
#
# No --array here, and no sample id: this job is the whole cohort by design.

cd "$SLURM_SUBMIT_DIR"

mkdir -p logs

source slurm/conf/slurm.env

SAMPLESHEET="${SLURM_SUBMIT_DIR}/${SAMPLESHEET_FILE}"
OUTDIR="${SLURM_SUBMIT_DIR}/${PIPELINE_OUTDIR}"

export THREADS="$SLURM_CPUS_PER_TASK"

export TMPDIR="/tmp/${SLURM_JOB_ID}_cohort"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

echo "cohort job ${SLURM_JOB_ID}: threads=${THREADS} tmpdir=${TMPDIR}" >&2

bash ./run_cohort.sh "$SAMPLESHEET" "$OUTDIR"
