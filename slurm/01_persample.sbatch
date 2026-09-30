#!/usr/bin/env bash
#SBATCH --job-name=vc-persample
#SBATCH --array=1-8
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=logs/persample_%A_%a.out
#SBATCH --error=logs/persample_%A_%a.err
#SBATCH --export=NONE
#-----------------------------------------------------------------------------
# Stages 0-5 for ONE sample. Eight of these run at the same time.
#
# There is no bioinformatics in this file. It decides WHICH sample runs and with
# what resources; run_sample.sh decides what to do to it.
#
# --array=1-8 because the cohort sheet has eight samples. The mapping from task
# id to sample is done below, by reading the sheet - not by a list of names
# here, which would have to be edited every time the cohort changed.
#
# The four resource numbers above are DEFAULTS AND GUESSES. submit.sh overrides
# them from slurm/conf/slurm.env, and neither set has been measured on Explorer
# yet; RESOURCES.md is where the seff/sacct numbers and the reasoning go.
#-----------------------------------------------------------------------------
set -euo pipefail

# NOT $(dirname "$0"): sbatch copies your script to the node's spool directory
# and runs the COPY, so $0 is there and conf/ is not beside it.
# $SLURM_SUBMIT_DIR is the directory you were standing in when you typed sbatch
# and Slurm sets it itself, so it survives --export=NONE.
#
# That also means conf/slurm.env has to be in the directory you submitted FROM.
# `bash submit.sh` guarantees it by cd-ing here first; submitting this file by
# hand from somewhere else does not, and the failure is nasty: --output=logs/...
# is relative to the submit directory too, so a job submitted from a directory
# with no logs/ comes back FAILED with no log to read. Test for the file and say
# so, rather than letting `source` fail into that silence.
if [[ ! -s "${SLURM_SUBMIT_DIR}/conf/slurm.env" ]]; then
    printf 'no conf/slurm.env in %s\n' "${SLURM_SUBMIT_DIR}" >&2
    printf 'submit from the slurm/ directory, or use: bash submit.sh\n' >&2
    exit 78            # EX_CONFIG
fi
# shellcheck source=conf/slurm.env
source "${SLURM_SUBMIT_DIR}/conf/slurm.env"

cd "${SLURM_SUBMIT_DIR}"
mkdir -p logs

module load miniconda3/25.9.1
source activate "${CONDA_ENV}"

# The cores Slurm actually gave us, handed to the tools. The pipeline already
# reads THREADS from the environment and lets it beat conf/pipeline.env, so this
# one line is the whole change.
export THREADS="${SLURM_CPUS_PER_TASK}"

# Scratch on the node's own disk, and a trap that removes it however this job
# ends. The stages read TMPDIR and hand it to every tool that spills, so the
# spill lands here rather than on shared /scratch beside the output.
#
# No tool is named in this file, on purpose: what runs is the pipeline's
# business, and this script's only job is to say where the scratch space is.
#
# The trap rather than an `rm` at the bottom: a job that is cancelled or times
# out never reaches the bottom.
export TMPDIR="/tmp/${SLURM_JOB_ID}"
mkdir -p "${TMPDIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- which sample is this task? ---------------------------------------------
# Read from the sheet, by column NAME, skipping the header. Task n takes data
# row n, so --array=1-8 covers row 2 to row 9 of the file.
#
# By name rather than `print $1` because that is the contract everywhere else in
# this pipeline, and a sheet whose columns get reordered should move this script
# with it rather than silently yield a condition where a sample_id belongs.
SAMPLE=$(awk -F, -v n="${SLURM_ARRAY_TASK_ID}" '
    NR == 1 {
        for (i = 1; i <= NF; i++) if ($i == "sample_id") c = i
        if (!c) { print "samplesheet has no sample_id column" > "/dev/stderr"; exit 65 }
        next
    }
    NR == n + 1 { print $c; exit }
' "${SAMPLESHEET}")

# An array wider than the samplesheet gets an empty name here. Refuse, loudly:
# run_sample.sh would reject an empty id too, but this says which task and which
# sheet, which is what you need to fix the --array range.
if [[ -z "${SAMPLE}" ]]; then
    printf 'task %s: no data row %s in %s\n' \
           "${SLURM_ARRAY_TASK_ID}" "${SLURM_ARRAY_TASK_ID}" "${SAMPLESHEET}" >&2
    printf 'the --array range is wider than the sheet has samples\n' >&2
    exit 64            # EX_USAGE
fi

printf 'task %s on %s: sample=%s cores=%s tmpdir=%s\n' \
       "${SLURM_ARRAY_TASK_ID}" "$(hostname)" "${SAMPLE}" \
       "${SLURM_CPUS_PER_TASK}" "${TMPDIR}" >&2

# Stages 0-5 only. run_sample.sh refuses the cohort stages by name, so a typo
# here cannot start joint-calling an incomplete cohort from inside an array task.
bash "${PIPELINE_DIR}/run_sample.sh" \
     "${SAMPLESHEET}" "${RUN_ROOT}/run" "${SAMPLE}" quantify
