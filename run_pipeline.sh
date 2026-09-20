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

REQUIRED_COLS=(sample_id r1_fastq r2_fastq library_type sex is_synthetic_phenotype)

stage_validate() {
    log "stage 0 (validate): checking samplesheet and inputs"

    local -a errors=()
    local -A seen_ids=()

    if [[ ! -f "$SAMPLESHEET" ]]; then
        log "samplesheet not found: $SAMPLESHEET"
        return 1
    fi

    # --- header: confirm every required column is present, in any order ---
    local header
    header="$(head -n1 -- "$SAMPLESHEET")"
    header="${header%$'\r'}"

    local -a cols
    IFS=',' read -r -a cols <<< "$header"

    local -A col_index=()
    local i
    for i in "${!cols[@]}"; do
        col_index["${cols[$i]}"]="$i"
    done

    local col
    for col in "${REQUIRED_COLS[@]}"; do
        if [[ -z "${col_index[$col]+x}" ]]; then
            errors+=("samplesheet header missing required column: $col")
        fi
    done

    if (( ${#errors[@]} > 0 )); then
        # can't safely index rows without the columns we need
        local e
        for e in "${errors[@]}"; do
            log "VALIDATION ERROR: $e"
        done
        return 1
    fi

    local idx_sample_id=${col_index[sample_id]}
    local idx_r1=${col_index[r1_fastq]}
    local idx_r2=${col_index[r2_fastq]}

    # --- body: check every row, collecting every problem before exiting ---
    local line_no=1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        [[ -z "$line" ]] && continue

        line="${line%$'\r'}"

        local -a fields
        IFS=',' read -r -a fields <<< "$line"

        local sample_id="${fields[$idx_sample_id]:-}"
        local r1="${fields[$idx_r1]:-}"
        local r2="${fields[$idx_r2]:-}"

        if [[ -z "$sample_id" ]]; then
            errors+=("row $line_no: empty sample_id")
            continue
        fi

        # duplicate sample_id
        if [[ -n "${seen_ids[$sample_id]+x}" ]]; then
            errors+=("duplicate sample_id: '$sample_id' (rows ${seen_ids[$sample_id]} and $line_no)")
        else
            seen_ids["$sample_id"]="$line_no"
        fi

        # r1 is required for every sample, single- or paired-end
        if [[ -z "$r1" ]]; then
            errors+=("sample '$sample_id': r1_fastq is empty")
        elif [[ ! -f "$r1" ]]; then
            errors+=("sample '$sample_id': r1_fastq not found: $r1")
        elif [[ "$r1" == *.gz ]] && ! gzip -t -- "$r1" 2>/dev/null; then
            errors+=("sample '$sample_id': r1_fastq is truncated or corrupt: $r1")
        fi

        # r2 is optional (empty = single-end, per the samplesheet, never per the name)
        if [[ -n "$r2" ]]; then
            if [[ ! -f "$r2" ]]; then
                errors+=("sample '$sample_id': r2_fastq not found: $r2")
            elif [[ "$r2" == *.gz ]] && ! gzip -t -- "$r2" 2>/dev/null; then
                errors+=("sample '$sample_id': r2_fastq is truncated or corrupt: $r2")
            fi
        fi
    done < <(tail -n +2 -- "$SAMPLESHEET")

    if (( ${#errors[@]} > 0 )); then
        log "stage 0: ${#errors[@]} problem(s) found"
        local e
        for e in "${errors[@]}"; do
            log "VALIDATION ERROR: $e"
        done
        return 1
    fi

    log "stage 0: all samples validated OK"
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
