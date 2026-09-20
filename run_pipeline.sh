#!/usr/bin/env bash
set -euo pipefail

# run_pipeline.sh <samplesheet.csv> <outdir> <last_stage>
#
# Positional interface (matches the acceptance harness and the week-1 demo):
#   ./run_pipeline.sh samplesheet.csv out validate
#
# Week 1: single file, one function per stage, run in order.
# Splitting into lib/ and stages/ is week 2's job, once the job-array
# entry point actually needs it.

usage() {
    echo "Usage: $0 <samplesheet.csv> <outdir> <last_stage>" >&2
    exit 1
}

[[ $# -eq 3 ]] || usage

SAMPLESHEET="$1"
OUTDIR="$2"
LAST_STAGE="$3"

STAGES=(validate qc_raw trim align postprocess quantify merge analyze qc_report publish)

log() {
    # progress messages go to stderr; stdout stays clean for data
    echo "[$(date -u +%FT%TZ)] $*" >&2
}

stage_validate() {
    log "stage 0 (validate): checking samplesheet and inputs"
    # TODO: check samplesheet exists, required columns present,
    # every sample's FASTQ(s) exist and are not truncated,
    # no duplicate sample_id, collect ALL problems before exiting.
    :
}

stage_qc_raw()      { log "stage 1 (qc_raw): TODO - FastQC on raw FASTQ"; }
stage_trim()        { log "stage 2 (trim): TODO - fastp adapter/quality trim"; }
stage_align()       { log "stage 3 (align): TODO - BWA-MEM against full GRCh38"; }
stage_postprocess() { log "stage 4 (postprocess): TODO - sort, index, mark duplicates"; }
stage_quantify()    { log "stage 5 (quantify): TODO - HaplotypeCaller -ERC GVCF -L chr20:1-10000000"; }
stage_merge()       { log "stage 6 (merge): TODO - GenomicsDBImport + GenotypeGVCFs"; }
stage_analyze()     { log "stage 7 (analyze): TODO - VariantFiltration + annotate"; }
stage_qc_report()   { log "stage 8 (qc_report): TODO - MultiQC across the cohort"; }
stage_publish()     { log "stage 9 (publish): TODO - tidy TSVs + manifest.json"; }

mkdir -p "$OUTDIR"

for stage in "${STAGES[@]}"; do
    "stage_${stage}"
    if [[ "$stage" == "$LAST_STAGE" ]]; then
        log "stopping after requested stage: $LAST_STAGE"
        break
    fi
done
