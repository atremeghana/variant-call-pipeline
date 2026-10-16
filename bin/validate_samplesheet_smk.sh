#!/usr/bin/env bash
#=============================================================================
# validate_samplesheet.sh — stage 0: check the samplesheet, every FASTQ, and
# the reference's indexes, before anything computes. Report every problem
# together.
#
#   validate_samplesheet.sh <samplesheet.csv> <reference.fa>
#
# Unlike the Nextflow version, Snakemake links nothing into a task folder: a
# file runs where it is. So every FASTQ is opened at the path the samplesheet
# gives (resolved against the sheet's own folder, same as the Snakefile's
# resolve()), not by its basename.
#=============================================================================
set -euo pipefail

SHEET=${1:?usage: validate_samplesheet.sh <samplesheet.csv> <reference.fa>}
REF=${2:?usage: validate_samplesheet.sh <samplesheet.csv> <reference.fa>}
SHEET_DIR=$(dirname -- "$SHEET")

log() { printf '[validate] %s\n' "$*" >&2; }

resolve() {
    local p=$1
    if [[ -z "$p" || "$p" == /* ]]; then
        printf '%s' "$p"
    else
        printf '%s/%s' "$SHEET_DIR" "$p"
    fi
}

problems=0

header="$(head -n1 -- "$SHEET")"
header="${header%$'\r'}"
IFS=',' read -r -a cols <<< "$header"
declare -A col_index=()
for i in "${!cols[@]}"; do col_index["${cols[$i]}"]="$i"; done

for col in sample_id condition replicate library_type r1_fastq r2_fastq; do
    if [[ -z "${col_index[$col]+x}" ]]; then
        log "samplesheet header missing required column: $col"
        problems=$(( problems + 1 ))
    fi
done

if (( problems > 0 )); then
    log "validation failed with ${problems} problem(s)"
    exit 65
fi

idx_id=${col_index[sample_id]}
idx_lib=${col_index[library_type]}
idx_r1=${col_index[r1_fastq]}
idx_r2=${col_index[r2_fastq]}

declare -A seen_ids=()
line_no=1
while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ -z "$line" ]] && continue
    line="${line%$'\r'}"
    IFS=',' read -r -a fields <<< "$line"

    sample_id="${fields[$idx_id]:-}"
    lib="${fields[$idx_lib]:-}"
    r1=$(resolve "${fields[$idx_r1]:-}")
    r2_raw="${fields[$idx_r2]:-}"
    r2=""
    [[ -n "$r2_raw" ]] && r2=$(resolve "$r2_raw")

    if [[ -z "$sample_id" ]]; then
        log "row $line_no: empty sample_id"; problems=$(( problems + 1 )); continue
    fi

    if [[ -n "${seen_ids[$sample_id]+x}" ]]; then
        log "duplicate sample_id: '$sample_id' (rows ${seen_ids[$sample_id]} and $line_no)"
        problems=$(( problems + 1 ))
    else
        seen_ids["$sample_id"]="$line_no"
    fi

    if [[ -z "$r1" ]]; then
        log "sample '$sample_id': r1_fastq is empty"; problems=$(( problems + 1 ))
    elif [[ ! -f "$r1" ]]; then
        log "sample '$sample_id': r1_fastq not found: $r1"; problems=$(( problems + 1 ))
    elif [[ "$r1" == *.gz ]] && ! gzip -t -- "$r1" 2>/dev/null; then
        log "sample '$sample_id': r1_fastq is truncated or corrupt: $r1"; problems=$(( problems + 1 ))
    fi

    if [[ -z "$r2" ]]; then
        if [[ "$lib" == "paired" ]]; then
            log "sample '$sample_id': library_type is paired but r2_fastq is empty (no mate)"
            problems=$(( problems + 1 ))
        fi
    else
        if [[ ! -f "$r2" ]]; then
            log "sample '$sample_id': r2_fastq not found: $r2"; problems=$(( problems + 1 ))
        elif [[ "$r2" == *.gz ]] && ! gzip -t -- "$r2" 2>/dev/null; then
            log "sample '$sample_id': r2_fastq is truncated or corrupt: $r2"; problems=$(( problems + 1 ))
        fi
    fi

    if [[ -n "$r1" && -n "$r2" && -f "$r1" && -f "$r2" ]]; then
        n1=$(zcat -f -- "$r1" 2>/dev/null | wc -l) || n1=""
        n2=$(zcat -f -- "$r2" 2>/dev/null | wc -l) || n2=""
        if [[ -n "$n1" && -n "$n2" && "$n1" != "$n2" ]]; then
            log "sample '$sample_id': R1/R2 record count mismatch ($((n1 / 4)) vs $((n2 / 4)) reads)"
            problems=$(( problems + 1 ))
        fi
    fi
done < <(tail -n +2 -- "$SHEET")

[[ -s "$REF" ]] || { log "reference FASTA not found: $REF"; problems=$(( problems + 1 )); }

missing_idx=()
for ext in amb ann bwt pac sa fai; do
    [[ -s "${REF}.${ext}" ]] || missing_idx+=("$ext")
done
if (( ${#missing_idx[@]} > 0 )); then
    log "reference index incomplete (missing: ${missing_idx[*]})"
    problems=$(( problems + 1 ))
fi

dict="${REF%.*}.dict"
[[ -s "$dict" ]] || { log "reference sequence dictionary missing: $dict"; problems=$(( problems + 1 )); }

if (( problems > 0 )); then
    log "validation failed with ${problems} problem(s)"
    exit 65
fi

log "validation passed: $(awk 'NR > 1' "$SHEET" | wc -l | tr -d ' ') samples"
