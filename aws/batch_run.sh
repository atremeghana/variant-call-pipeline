#!/usr/bin/env bash
set -euo pipefail
# setup: the settings from the job definition, the job's id, an empty folder
: "${DATA:?set DATA to the s3:// folder that holds samplesheet.csv, the FASTQs and the reference}"
: "${RESULTS:?set RESULTS to the s3:// folder the results go to}"
: "${REF_NAME:=smoke.fa}"
job=${AWS_BATCH_JOB_ID:-local}
work=$(mktemp -d /tmp/run.XXXXXX)

# 1 · copy in
echo "[batch_run] 1/3 copying ${DATA}/ to ${work}/data"
aws s3 cp "${DATA%/}/" "${work}/data/" --recursive --no-progress
# 2 · run
echo "[batch_run] 2/3 running the pipeline: REF=${REF_NAME} REGION=${REGION:-?} THREADS=${THREADS:-?}"
cd "${work}/data"                         # the samplesheet's FASTQ paths are relative to its folder
REF="${work}/data/${REF_NAME}" bash /pipeline/run_pipeline.sh samplesheet.csv "${work}/out"
# 3 · copy out
echo "[batch_run] 3/3 copying ${work}/out/results/ to ${RESULTS%/}/${job}/"
aws s3 cp "${work}/out/results/" "${RESULTS%/}/${job}/" --recursive --no-progress
echo "[batch_run] done"
