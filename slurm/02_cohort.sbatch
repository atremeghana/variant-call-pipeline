#!/usr/bin/env bash
#SBATCH --job-name=vc-cohort
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --time=02:00:00
#SBATCH --output=logs/cohort_%j.out
#SBATCH --error=logs/cohort_%j.err
#SBATCH --export=NONE
#-----------------------------------------------------------------------------
# Stages 6-9, once, over every sample. submit.sh submits this with
# --dependency=afterok on the array, so by the time it starts every per-sample
# task has SUCCEEDED and the shared outdir is complete.
#
# afterok and not afterany: a failed sample under afterany would give you a
# joint-called cohort quietly missing a column, which is worse than no cohort.
#
# No --array here and no sample id: this job is the whole cohort by design, and
# run_cohort.sh clears ONLY_SAMPLE_ID itself so an inherited filter cannot
# shrink it.
#
# Same rule as the array script: this file schedules, it does not analyse. The
# only thing it executes is run_cohort.sh.
#
# The resource numbers above are DEFAULTS AND GUESSES, overridden by submit.sh
# from slurm/conf/slurm.env. Neither set is measured yet - see RESOURCES.md.
#-----------------------------------------------------------------------------
set -euo pipefail

# See 01_persample.sbatch for why this is $SLURM_SUBMIT_DIR and not
# $(dirname "$0"), and why the file is tested for rather than just sourced.
if [[ ! -s "${SLURM_SUBMIT_DIR}/conf/slurm.env" ]]; then
    printf 'no conf/slurm.env in %s\n' "${SLURM_SUBMIT_DIR}" >&2
    printf 'submit from the slurm/ directory, or use: bash submit.sh\n' >&2
    exit 78            # EX_CONFIG
fi
# shellcheck source=conf/slurm.env
source "${SLURM_SUBMIT_DIR}/conf/slurm.env"

cd "${SLURM_SUBMIT_DIR}"
mkdir -p logs

SIF="/scratch/${USER}/containers/variant-call.sif"

export THREADS="${SLURM_CPUS_PER_TASK}"

export TMPDIR="/tmp/${SLURM_JOB_ID}"
mkdir -p "${TMPDIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

printf 'cohort job %s on %s: cores=%s tmpdir=%s\n' \
       "${SLURM_JOB_ID}" "$(hostname)" "${SLURM_CPUS_PER_TASK}" "${TMPDIR}" >&2

# Stages 6-9 only. run_cohort.sh refuses the per-sample stages by name, so this
# job cannot be talked into re-running eight samples serially in one allocation.
apptainer exec --cleanenv \
    --env THREADS="${THREADS}" \
    --env TMPDIR="${TMPDIR}" \
    --env SLURM_JOB_ID="${SLURM_JOB_ID}" \
    --env SLURM_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK}" \
    --bind /courses/BINF6610.202710,/scratch/${USER} \
    "${SIF}" \
    bash "${PIPELINE_DIR}/run_cohort.sh" \
         "${SAMPLESHEET}" "${RUN_ROOT}/run" publish

