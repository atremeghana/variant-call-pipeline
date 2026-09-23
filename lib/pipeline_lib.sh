#!/usr/bin/env bash
set -euo pipefail

# pipeline_lib.sh - every stage implementation, shared by all three entry points.
#
#   run_pipeline.sh   all samples, stages 0-9        (the week-1 interface)
#   run_sample.sh     ONE sample, stages 0-5         (one Slurm array task)
#   run_cohort.sh     all samples, stages 6-9        (one job, after the array)
#
# This file is sourced, never executed. Callers must set SAMPLESHEET and OUTDIR
# before calling any stage_* function.
#
# ONLY_SAMPLE_ID is the whole reason this file exists. A Slurm array runs each
# sample as a separate task, so the per-sample stages need to be restricted to
# one row of the samplesheet without forking the stage logic. Set it and every
# per-sample stage sees a one-row cohort; leave it unset and nothing changes.
# The filter lives in read_samples() so it cannot be applied inconsistently.

PIPELINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PIPELINE_LIB_DIR/.." && pwd)"

# stage_publish reports the commit the run's code was on; that is the repo root.
SCRIPT_DIR="$REPO_ROOT"

: "${PIPELINE_STARTED_AT:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Pull in cluster/reference config. Safe to be missing on a laptop dev run -
# stage 0 reports that as one complaint, not a crash.
#
# Anything already set in the environment WINS over the file. That matters on
# the cluster: the batch script exports THREADS from the scheduler's CPU
# allocation, and a blind `source` would silently overwrite it with the file's
# laptop default.
#
# REF and REGION are the short names the assignment brief puts on the command
# line for the smoke run:
#
#     REF=$PWD/smoke.fa REGION=smoke_1mb bash run_pipeline.sh samplesheet.csv out
#
# REFERENCE_FASTA and CALL_REGION are the names every stage below reads, and
# the names conf/pipeline.env has always used. They are the same two values
# under two names, so both spellings are accepted from both places and
# collapsed into the canonical pair here, once, before any stage runs. No stage
# ever sees REF or REGION.
#
# Precedence, highest first:
#   1. REF / REGION                   in the environment   (the brief's form)
#   2. REFERENCE_FASTA / CALL_REGION  in the environment
#   3. REF / REGION                   in conf/pipeline.env
#   4. REFERENCE_FASTA / CALL_REGION  in conf/pipeline.env
_env_ref="${REF:-}"
_env_region="${REGION:-}"
_env_reference_fasta="${REFERENCE_FASTA:-}"
_env_call_region="${CALL_REGION:-}"
_env_threads="${THREADS:-}"

# Cleared so that a REF the FILE sets can be told apart from a REF the CALLER
# set - without this, step 3 below could not distinguish them and the file
# would appear to outrank the environment.
unset REF REGION

CONF_FILE="$REPO_ROOT/conf/pipeline.env"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

# 3: the file's short names, but only to fill a gap its canonical names left.
[[ -z "${REFERENCE_FASTA:-}" && -n "${REF:-}"    ]] && REFERENCE_FASTA="$REF"
[[ -z "${CALL_REGION:-}"     && -n "${REGION:-}" ]] && CALL_REGION="$REGION"

# 2 then 1: the environment beats the file, and REF beats REFERENCE_FASTA.
[[ -n "$_env_reference_fasta" ]] && REFERENCE_FASTA="$_env_reference_fasta"
[[ -n "$_env_call_region"     ]] && CALL_REGION="$_env_call_region"
[[ -n "$_env_ref"             ]] && REFERENCE_FASTA="$_env_ref"
[[ -n "$_env_region"          ]] && CALL_REGION="$_env_region"
[[ -n "$_env_threads"         ]] && THREADS="$_env_threads"

# Two names for one value, set to two different things, is a mistake worth a
# word rather than a silent winner - the run would otherwise use a reference
# the caller can see no trace of.
if [[ -n "$_env_ref" && -n "$_env_reference_fasta" && "$_env_ref" != "$_env_reference_fasta" ]]; then
    echo "warning: both REF and REFERENCE_FASTA are set and differ; using REF=$_env_ref" >&2
fi
if [[ -n "$_env_region" && -n "$_env_call_region" && "$_env_region" != "$_env_call_region" ]]; then
    echo "warning: both REGION and CALL_REGION are set and differ; using REGION=$_env_region" >&2
fi

unset _env_ref _env_region _env_reference_fasta _env_call_region _env_threads

# The full pipeline, in order, and the two halves the cluster splits it into.
STAGES=(validate qc_raw trim align postprocess quantify merge analyze qc_report publish)
PER_SAMPLE_STAGES=(validate qc_raw trim align postprocess quantify)
COHORT_STAGES=(merge analyze qc_report publish)

log() {
    # progress messages go to stderr; stdout stays clean for data
    echo "[$(date -u +%FT%TZ)] $*" >&2
}

# in_list <needle> <haystack...>
in_list() {
    local want=$1 s
    shift
    for s in "$@"; do
        [[ "$s" == "$want" ]] && return 0
    done
    return 1
}

# run_stage_range <last_stage> <stage...>
# Runs the listed stages in order and stops after <last_stage>. Shared by all
# three entry points so "stop after stage X" behaves identically everywhere.
run_stage_range() {
    local last=$1
    shift
    local stage
    for stage in "$@"; do
        "stage_${stage}"
        if [[ "$stage" == "$last" ]]; then
            log "stopping after requested stage: $last"
            return 0
        fi
    done
}

REQUIRED_COLS=(sample_id condition replicate library_type r1_fastq r2_fastq)

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
    local idx_lib=${col_index[library_type]}

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
        local lib="${fields[$idx_lib]:-}"

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

        # r2 is only optional when library_type says single-end. A paired row
        # with no mate is broken, not single-end-by-accident.
        if [[ -z "$r2" ]]; then
            if [[ "$lib" == "paired" ]]; then
                errors+=("sample '$sample_id': library_type is paired but r2_fastq is empty (no mate)")
            fi
        else
            if [[ ! -f "$r2" ]]; then
                errors+=("sample '$sample_id': r2_fastq not found: $r2")
            elif [[ "$r2" == *.gz ]] && ! gzip -t -- "$r2" 2>/dev/null; then
                errors+=("sample '$sample_id': r2_fastq is truncated or corrupt: $r2")
            fi
        fi

        # Mates must carry the same number of records. Each file can be a
        # perfectly valid gzip stream and the pair still be broken - losing the
        # tail of R1 during a copy leaves exactly this signature, and gzip -t
        # has nothing to complain about. Every aligner downstream will happily
        # produce garbage from mates that are out of sync.
        if [[ -n "$r1" && -n "$r2" && -f "$r1" && -f "$r2" ]]; then
            local n1 n2
            n1=$(zcat -f -- "$r1" 2>/dev/null | wc -l) || n1=""
            n2=$(zcat -f -- "$r2" 2>/dev/null | wc -l) || n2=""
            if [[ -n "$n1" && -n "$n2" && "$n1" != "$n2" ]]; then
                errors+=("sample '$sample_id': R1/R2 record count mismatch ($((n1 / 4)) vs $((n2 / 4)) reads) - mates are out of sync: $r1 / $r2")
            fi
        fi
    done < <(tail -n +2 -- "$SAMPLESHEET")

    # Reference check: one complaint, never tied to a sample. A GRCh38 index
    # is 5GB and an hour to build - nobody is expected to have it on a laptop
    # yet, but it's still worth reporting clearly, once, on its own.
    if [[ -z "${REFERENCE_FASTA:-}" ]]; then
        errors+=("REFERENCE_FASTA is not set (check conf/pipeline.env)")
    elif [[ ! -f "$REFERENCE_FASTA" ]]; then
        errors+=("reference FASTA not found: $REFERENCE_FASTA")
    else
        local ext missing_idx=()
        for ext in amb ann bwt pac sa; do
            [[ -f "${REFERENCE_FASTA}.${ext}" ]] || missing_idx+=("$ext")
        done
        if (( ${#missing_idx[@]} > 0 )); then
            errors+=("BWA index incomplete for reference (missing: ${missing_idx[*]}) - run 'bwa index $REFERENCE_FASTA'")
        fi
    fi

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

# Populates SAMPLE_IDS, R1_LIST, R2_LIST, LIB_TYPES, COND_LIST, REPL_LIST
# (parallel arrays, same row order as the samplesheet). Used by every
# per-sample stage so the parsing logic lives in one place.
#
# If ONLY_SAMPLE_ID is set, every array is filtered down to that one sample
# before returning, and an id that is not in the sheet is a hard error. Doing
# the filter here - rather than in each caller - is what keeps a Slurm array
# task from silently processing the whole cohort.
read_samples() {
    SAMPLE_IDS=()
    R1_LIST=()
    R2_LIST=()
    LIB_TYPES=()
    COND_LIST=()
    REPL_LIST=()

    if [[ ! -f "$SAMPLESHEET" ]]; then
        log "samplesheet not found: $SAMPLESHEET"
        return 1
    fi

    local header
    header="$(head -n1 -- "$SAMPLESHEET")"
    header="${header%$'\r'}"

    local -a cols
    IFS=',' read -r -a cols <<< "$header"

    local -A idx=()
    local i
    for i in "${!cols[@]}"; do
        idx["${cols[$i]}"]="$i"
    done

    # sample_id and r1_fastq are the two this function cannot work without.
    local c
    for c in sample_id r1_fastq; do
        if [[ -z "${idx[$c]+x}" ]]; then
            log "samplesheet header missing required column: $c"
            return 1
        fi
    done

    local idx_id=${idx[sample_id]} idx_r1=${idx[r1_fastq]}
    local idx_r2="${idx[r2_fastq]:-}" idx_lib="${idx[library_type]:-}"
    local idx_cond="${idx[condition]:-}" idx_repl="${idx[replicate]:-}"

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        line="${line%$'\r'}"
        local -a row
        IFS=',' read -r -a row <<< "$line"
        # A column that is absent from the header yields an empty value rather
        # than an unbound-variable crash under `set -u`.
        local v_r2="" v_lib="" v_cond="" v_repl=""
        [[ -n "$idx_r2"   ]] && v_r2="${row[$idx_r2]:-}"
        [[ -n "$idx_lib"  ]] && v_lib="${row[$idx_lib]:-}"
        [[ -n "$idx_cond" ]] && v_cond="${row[$idx_cond]:-}"
        [[ -n "$idx_repl" ]] && v_repl="${row[$idx_repl]:-}"

        SAMPLE_IDS+=("${row[$idx_id]:-}")
        R1_LIST+=("${row[$idx_r1]:-}")
        R2_LIST+=("$v_r2")
        LIB_TYPES+=("$v_lib")
        COND_LIST+=("$v_cond")
        REPL_LIST+=("$v_repl")
    done < <(tail -n +2 -- "$SAMPLESHEET")

    [[ -z "${ONLY_SAMPLE_ID:-}" ]] && return 0

    # --- restrict every parallel array to the one requested sample ---
    local -a f_ids=() f_r1=() f_r2=() f_lib=() f_cond=() f_repl=()
    for i in "${!SAMPLE_IDS[@]}"; do
        if [[ "${SAMPLE_IDS[$i]}" == "$ONLY_SAMPLE_ID" ]]; then
            f_ids+=("${SAMPLE_IDS[$i]}")
            f_r1+=("${R1_LIST[$i]}")
            f_r2+=("${R2_LIST[$i]}")
            f_lib+=("${LIB_TYPES[$i]}")
            f_cond+=("${COND_LIST[$i]}")
            f_repl+=("${REPL_LIST[$i]}")
        fi
    done

    if (( ${#f_ids[@]} == 0 )); then
        log "sample_id '$ONLY_SAMPLE_ID' is not in the samplesheet: $SAMPLESHEET"
        log "       available: ${SAMPLE_IDS[*]}"
        return 1
    fi

    SAMPLE_IDS=("${f_ids[@]}")
    R1_LIST=("${f_r1[@]}")
    R2_LIST=("${f_r2[@]}")
    LIB_TYPES=("${f_lib[@]}")
    COND_LIST=("${f_cond[@]}")
    REPL_LIST=("${f_repl[@]}")
}

stage_qc_raw() {
    log "stage 1 (qc_raw): FastQC on raw FASTQ"
    command -v fastqc >/dev/null 2>&1 || { log "fastqc not found on PATH"; return 1; }

    read_samples
    local qc_dir="$OUTDIR/qc_raw"
    mkdir -p "$qc_dir"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}" r1="${R1_LIST[$i]}" r2="${R2_LIST[$i]}"
        local sample_dir="$qc_dir/$sample_id"
        mkdir -p "$sample_dir"
        log "qc_raw: $sample_id"

        if [[ -n "$r2" ]]; then
            fastqc --quiet -o "$sample_dir" "$r1" "$r2" \
                > "$sample_dir/fastqc.log" 2>&1 \
                || { log "fastqc failed for sample '$sample_id'"; return 1; }
        else
            fastqc --quiet -o "$sample_dir" "$r1" \
                > "$sample_dir/fastqc.log" 2>&1 \
                || { log "fastqc failed for sample '$sample_id'"; return 1; }
        fi
    done

    log "stage 1: qc_raw complete for ${#SAMPLE_IDS[@]} sample(s)"
}

stage_trim() {
    log "stage 2 (trim): fastp adapter/quality trim"
    command -v fastp >/dev/null 2>&1 || { log "fastp not found on PATH"; return 1; }

    read_samples
    local trim_dir="$OUTDIR/trim"
    mkdir -p "$trim_dir"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}" r1="${R1_LIST[$i]}" r2="${R2_LIST[$i]}"
        local sample_dir="$trim_dir/$sample_id"
        mkdir -p "$sample_dir"
        log "trim: $sample_id"

        if [[ -n "$r2" ]]; then
            fastp \
                -i "$r1" -I "$r2" \
                -o "$sample_dir/${sample_id}_R1.trimmed.fastq.gz" \
                -O "$sample_dir/${sample_id}_R2.trimmed.fastq.gz" \
                --json "$sample_dir/fastp.json" \
                --html "$sample_dir/fastp.html" \
                > "$sample_dir/fastp.log" 2>&1 \
                || { log "fastp failed for sample '$sample_id'"; return 1; }
        else
            fastp \
                -i "$r1" \
                -o "$sample_dir/${sample_id}_R1.trimmed.fastq.gz" \
                --json "$sample_dir/fastp.json" \
                --html "$sample_dir/fastp.html" \
                > "$sample_dir/fastp.log" 2>&1 \
                || { log "fastp failed for sample '$sample_id'"; return 1; }
        fi

        [[ -s "$sample_dir/${sample_id}_R1.trimmed.fastq.gz" ]] \
            || { log "trim produced an empty R1 for sample '$sample_id'"; return 1; }
    done

    log "stage 2: trim complete for ${#SAMPLE_IDS[@]} sample(s)"
}

stage_align() {
    log "stage 3 (align): BWA-MEM against full GRCh38"
    command -v bwa >/dev/null 2>&1 || { log "bwa not found on PATH"; return 1; }
    command -v samtools >/dev/null 2>&1 || { log "samtools not found on PATH"; return 1; }

    if [[ -z "${REFERENCE_FASTA:-}" ]]; then
        log "REFERENCE_FASTA is not set (check conf/pipeline.env)"
        return 1
    fi
    if [[ ! -f "$REFERENCE_FASTA" ]]; then
        log "reference FASTA not found: $REFERENCE_FASTA"
        return 1
    fi
    local ext
    for ext in amb ann bwt pac sa; do
        if [[ ! -f "${REFERENCE_FASTA}.${ext}" ]]; then
            log "BWA index missing (.${ext}) for reference: $REFERENCE_FASTA - run 'bwa index $REFERENCE_FASTA'"
            return 1
        fi
    done

    read_samples
    local align_dir="$OUTDIR/align"
    mkdir -p "$align_dir"
    local threads="${THREADS:-4}"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}" r1="${R1_LIST[$i]}" r2="${R2_LIST[$i]}"
        local sample_dir="$align_dir/$sample_id"
        mkdir -p "$sample_dir"
        local bam="$sample_dir/${sample_id}.bam"
        local rg="@RG\tID:${sample_id}\tSM:${sample_id}\tPL:ILLUMINA"
        log "align: $sample_id"

        if [[ -n "$r2" ]]; then
            bwa mem -t "$threads" -R "$rg" "$REFERENCE_FASTA" "$r1" "$r2" 2> "$sample_dir/bwa.log" \
                | samtools view -b -o "$bam" - \
                || { log "bwa/samtools failed for sample '$sample_id'"; return 1; }
        else
            bwa mem -t "$threads" -R "$rg" "$REFERENCE_FASTA" "$r1" 2> "$sample_dir/bwa.log" \
                | samtools view -b -o "$bam" - \
                || { log "bwa/samtools failed for sample '$sample_id'"; return 1; }
        fi

        [[ -s "$bam" ]] || { log "align produced an empty BAM for sample '$sample_id'"; return 1; }
    done

    log "stage 3: align complete for ${#SAMPLE_IDS[@]} sample(s)"
}

stage_postprocess() {
    log "stage 4 (postprocess): sort, index, mark duplicates"
    command -v samtools >/dev/null 2>&1 || { log "samtools not found on PATH"; return 1; }
    command -v gatk >/dev/null 2>&1 || { log "gatk not found on PATH"; return 1; }

    read_samples
    local pp_dir="$OUTDIR/postprocess"
    mkdir -p "$pp_dir"
    local threads="${THREADS:-4}"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}"
        local align_bam="$OUTDIR/align/$sample_id/${sample_id}.bam"
        local sample_dir="$pp_dir/$sample_id"
        mkdir -p "$sample_dir"
        local sorted_bam="$sample_dir/${sample_id}.sorted.bam"
        local dedup_bam="$sample_dir/${sample_id}.dedup.bam"
        local metrics="$sample_dir/${sample_id}.dup_metrics.txt"
        log "postprocess: $sample_id"

        [[ -s "$align_bam" ]] \
            || { log "postprocess: no aligned BAM for sample '$sample_id' (expected $align_bam - run stage align first)"; return 1; }

        samtools sort -@ "$threads" -o "$sorted_bam" "$align_bam" \
            > "$sample_dir/sort.log" 2>&1 \
            || { log "samtools sort failed for sample '$sample_id'"; return 1; }

        gatk MarkDuplicates \
            -I "$sorted_bam" \
            -O "$dedup_bam" \
            -M "$metrics" \
            > "$sample_dir/markdup.log" 2>&1 \
            || { log "gatk MarkDuplicates failed for sample '$sample_id'"; return 1; }

        samtools index "$dedup_bam" \
            > "$sample_dir/index.log" 2>&1 \
            || { log "samtools index failed for sample '$sample_id'"; return 1; }

        [[ -s "$dedup_bam" ]] || { log "postprocess produced an empty BAM for sample '$sample_id'"; return 1; }
    done

    log "stage 4: postprocess complete for ${#SAMPLE_IDS[@]} sample(s)"
}

stage_quantify() {
    log "stage 5 (quantify): per-sample GVCF calling, restricted to \$CALL_REGION"
    command -v gatk >/dev/null 2>&1 || { log "gatk not found on PATH"; return 1; }

    if [[ -z "${REFERENCE_FASTA:-}" ]]; then
        log "REFERENCE_FASTA is not set (check conf/pipeline.env)"
        return 1
    fi
    if [[ ! -f "$REFERENCE_FASTA" ]]; then
        log "reference FASTA not found: $REFERENCE_FASTA"
        return 1
    fi
    if [[ ! -f "${REFERENCE_FASTA}.fai" ]]; then
        log "reference .fai index missing - run 'samtools faidx $REFERENCE_FASTA'"
        return 1
    fi
    local dict="${REFERENCE_FASTA%.*}.dict"
    if [[ ! -f "$dict" ]]; then
        log "reference sequence dictionary missing - run 'gatk CreateSequenceDictionary -R $REFERENCE_FASTA'"
        return 1
    fi
    if [[ -z "${CALL_REGION:-}" ]]; then
        log "CALL_REGION is not set (check conf/pipeline.env) - e.g. chr20:1-10000000"
        return 1
    fi

    read_samples
    local q_dir="$OUTDIR/quantify"
    mkdir -p "$q_dir"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}"
        local dedup_bam="$OUTDIR/postprocess/$sample_id/${sample_id}.dedup.bam"
        local sample_dir="$q_dir/$sample_id"
        mkdir -p "$sample_dir"
        local gvcf="$sample_dir/${sample_id}.g.vcf.gz"
        log "quantify: $sample_id"

        [[ -s "$dedup_bam" ]] \
            || { log "quantify: no deduplicated BAM for sample '$sample_id' (expected $dedup_bam - run stage postprocess first)"; return 1; }

        gatk HaplotypeCaller \
            -R "$REFERENCE_FASTA" \
            -I "$dedup_bam" \
            -O "$gvcf" \
            -ERC GVCF \
            -L "$CALL_REGION" \
            > "$sample_dir/haplotypecaller.log" 2>&1 \
            || { log "gatk HaplotypeCaller failed for sample '$sample_id'"; return 1; }

        [[ -s "$gvcf" ]] || { log "quantify produced an empty GVCF for sample '$sample_id'"; return 1; }
    done

    log "stage 5: quantify complete for ${#SAMPLE_IDS[@]} sample(s)"
}

stage_merge() {
    log "stage 6 (merge): joint genotyping across the cohort (GenomicsDBImport + GenotypeGVCFs)"
    command -v gatk >/dev/null 2>&1 || { log "gatk not found on PATH"; return 1; }

    if [[ -z "${REFERENCE_FASTA:-}" ]]; then
        log "REFERENCE_FASTA is not set (check conf/pipeline.env)"; return 1
    fi
    if [[ ! -f "$REFERENCE_FASTA" ]]; then
        log "reference FASTA not found: $REFERENCE_FASTA"; return 1
    fi
    if [[ -z "${CALL_REGION:-}" ]]; then
        log "CALL_REGION is not set (check conf/pipeline.env)"; return 1
    fi

    read_samples
    local merge_dir="$OUTDIR/merge"
    mkdir -p "$merge_dir"

    local map_file="$merge_dir/sample_map.tsv"
    : > "$map_file"

    local i
    for i in "${!SAMPLE_IDS[@]}"; do
        local sample_id="${SAMPLE_IDS[$i]}"
        local gvcf="$OUTDIR/quantify/$sample_id/${sample_id}.g.vcf.gz"
        [[ -s "$gvcf" ]] \
            || { log "merge: no GVCF for sample '$sample_id' (expected $gvcf - run stage quantify first)"; return 1; }
        printf '%s\t%s\n' "$sample_id" "$gvcf" >> "$map_file"
    done

    local db_dir="$merge_dir/genomicsdb"
    rm -rf "$db_dir"   # GenomicsDBImport refuses to write into an existing workspace

    log "merge: importing ${#SAMPLE_IDS[@]} sample(s) into GenomicsDB"
    gatk GenomicsDBImport \
        --sample-name-map "$map_file" \
        --genomicsdb-workspace-path "$db_dir" \
        --intervals "$CALL_REGION" \
        > "$merge_dir/genomicsdbimport.log" 2>&1 \
        || { log "gatk GenomicsDBImport failed"; return 1; }

    local cohort_vcf="$merge_dir/cohort.vcf.gz"
    log "merge: joint genotyping across the cohort"
    gatk GenotypeGVCFs \
        -R "$REFERENCE_FASTA" \
        -V "gendb://$db_dir" \
        -O "$cohort_vcf" \
        -L "$CALL_REGION" \
        > "$merge_dir/genotypegvcfs.log" 2>&1 \
        || { log "gatk GenotypeGVCFs failed"; return 1; }

    [[ -s "$cohort_vcf" ]] || { log "merge produced an empty cohort VCF"; return 1; }

    log "stage 6: merge complete - cohort VCF at $cohort_vcf"
}

stage_analyze() {
    log "stage 7 (analyze): hard-filter and annotate the cohort VCF"
    command -v gatk >/dev/null 2>&1 || { log "gatk not found on PATH"; return 1; }

    if [[ -z "${REFERENCE_FASTA:-}" ]]; then
        log "REFERENCE_FASTA is not set (check conf/pipeline.env)"; return 1
    fi
    if [[ ! -f "$REFERENCE_FASTA" ]]; then
        log "reference FASTA not found: $REFERENCE_FASTA"; return 1
    fi

    local cohort_vcf="$OUTDIR/merge/cohort.vcf.gz"
    [[ -s "$cohort_vcf" ]] \
        || { log "analyze: no cohort VCF found (expected $cohort_vcf - run stage merge first)"; return 1; }

    local analyze_dir="$OUTDIR/analyze"
    mkdir -p "$analyze_dir"
    local filtered_vcf="$analyze_dir/cohort.filtered.vcf.gz"

    # Standard GATK germline hard-filter thresholds, applied as one combined
    # pass rather than the usual separate SNP/indel split - a reasonable
    # simplification at this scale (10Mb, 8 samples).
    log "analyze: applying hard filters"
    gatk VariantFiltration \
        -R "$REFERENCE_FASTA" \
        -V "$cohort_vcf" \
        -O "$filtered_vcf" \
        --filter-expression "QD < 2.0"             --filter-name "QD2" \
        --filter-expression "FS > 60.0"             --filter-name "FS60" \
        --filter-expression "MQ < 40.0"             --filter-name "MQ40" \
        --filter-expression "MQRankSum < -12.5"     --filter-name "MQRankSum-12.5" \
        --filter-expression "ReadPosRankSum < -8.0" --filter-name "ReadPosRankSum-8" \
        --filter-expression "SOR > 3.0"             --filter-name "SOR3" \
        > "$analyze_dir/variantfiltration.log" 2>&1 \
        || { log "gatk VariantFiltration failed"; return 1; }

    [[ -s "$filtered_vcf" ]] || { log "analyze produced an empty filtered VCF"; return 1; }

    log "stage 7: analyze complete - filtered/annotated cohort VCF at $filtered_vcf"
    log "NOTE: is_synthetic_phenotype is true for every sample in this cohort. 'condition' is a synthetic grouping factor for pipeline testing only, never a real clinical finding - carry this forward into any downstream report."
}

stage_qc_report() {
    log "stage 8 (qc_report): MultiQC across the cohort"
    command -v multiqc >/dev/null 2>&1 || { log "multiqc not found on PATH"; return 1; }

    local report_dir="$OUTDIR/qc_report"
    mkdir -p "$report_dir"

    log "qc_report: aggregating QC outputs from $OUTDIR"
    multiqc "$OUTDIR" \
        -o "$report_dir" \
        --force \
        -x "$report_dir" \
        > "$report_dir/multiqc.log" 2>&1 \
        || { log "multiqc failed"; return 1; }

    [[ -s "$report_dir/multiqc_report.html" ]] \
        || { log "qc_report: multiqc did not produce multiqc_report.html"; return 1; }

    log "stage 8: qc_report complete - report at $report_dir/multiqc_report.html"
}

stage_publish() {
    log "stage 9 (publish): tidy TSVs + manifest.json"

    local pub_dir="$OUTDIR/publish"
    mkdir -p "$pub_dir"

    # --- git provenance: the commit this run's code was on, and whether it's dirty ---
    local git_sha="unknown"
    if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        git_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
        if ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null || ! git -C "$SCRIPT_DIR" diff --cached --quiet 2>/dev/null; then
            git_sha="${git_sha}-dirty"
        fi
    fi

    local run_id finished_at started_at platform_kind genome_desc
    run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(printf '%04x' $((RANDOM % 65536)))"
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    started_at="${PIPELINE_STARTED_AT:-$finished_at}"
    platform_kind="laptop"
    [[ -n "${SLURM_JOB_ID:-}" ]] && platform_kind="slurm"
    # Name the reference this run actually used, not a hardcoded "GRCh38" -
    # the smoke run's reference is smoke.fa, and a manifest that called it
    # GRCh38 would be recording a genome the run never touched.
    local ref_desc="unknown"
    if [[ -n "${REFERENCE_FASTA:-}" ]]; then
        ref_desc="$(basename -- "$REFERENCE_FASTA")"
        ref_desc="${ref_desc%.fa}"; ref_desc="${ref_desc%.fasta}"; ref_desc="${ref_desc%.fna}"
    fi
    genome_desc="${ref_desc}.${CALL_REGION:-unknown}"

    json_escape() {
        local s=$1
        s=${s//\\/\\\\}
        s=${s//\"/\\\"}
        printf '%s' "$s"
    }
    checksum() {
        local f=$1
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$f" | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$f" | awk '{print $1}'
        else
            printf '%064d' 0
        fi
    }

    # read_samples() now carries condition/replicate too, so the manifest and
    # the tidy TSV stay row-aligned with SAMPLE_IDS even when a filter is
    # active. Parsing the sheet a second time here used to be safe only
    # because nothing filtered; it would misalign the moment one did.
    read_samples

    # --- samples[] ---
    local samples_json="" i
    for i in "${!SAMPLE_IDS[@]}"; do
        [[ -n "$samples_json" ]] && samples_json+=","
        local sid lib cond
        sid=$(json_escape "${SAMPLE_IDS[$i]}")
        lib="paired"; [[ -z "${R2_LIST[$i]}" ]] && lib="single"
        cond=$(json_escape "${COND_LIST[$i]:-unknown}")
        samples_json+="{\"sample_id\":\"$sid\",\"library_type\":\"$lib\",\"condition\":\"$cond\"}"
    done

    # --- outputs[] : every artifact that actually exists, checksummed ---
    local outputs_json=""
    add_output() {
        local stage=$1 type=$2 path=$3
        [[ -s "$path" ]] || return 0
        local rel="${path#"$OUTDIR"/}"
        local sum; sum=$(checksum "$path")
        [[ -n "$outputs_json" ]] && outputs_json+=","
        outputs_json+="{\"stage\":\"$stage\",\"type\":\"$type\",\"path\":\"$(json_escape "$rel")\",\"checksum\":\"sha256:$sum\"}"
    }
    for i in "${!SAMPLE_IDS[@]}"; do
        local sid="${SAMPLE_IDS[$i]}"
        add_output "align"       "bam"  "$OUTDIR/align/$sid/${sid}.bam"
        add_output "postprocess" "bam"  "$OUTDIR/postprocess/$sid/${sid}.dedup.bam"
        add_output "quantify"    "gvcf" "$OUTDIR/quantify/$sid/${sid}.g.vcf.gz"
    done
    add_output "merge"     "cohort_vcf" "$OUTDIR/merge/cohort.vcf.gz"
    add_output "analyze"   "cohort_vcf" "$OUTDIR/analyze/cohort.filtered.vcf.gz"
    add_output "qc_report" "multiqc"    "$OUTDIR/qc_report/multiqc_report.html"

    # --- metrics[] : long format, sample_id null for cohort-level ---
    local metrics_json=""
    add_metric() {
        local sid=$1 metric=$2 value=$3 unit=$4 stage=$5
        [[ -n "$metrics_json" ]] && metrics_json+=","
        local sid_field="null"
        [[ -n "$sid" ]] && sid_field="\"$(json_escape "$sid")\""
        metrics_json+="{\"sample_id\":$sid_field,\"metric\":\"$metric\",\"value\":$value,\"unit\":\"$unit\",\"stage\":\"$stage\"}"
    }
    for i in "${!SAMPLE_IDS[@]}"; do
        local sid="${SAMPLE_IDS[$i]}" r1="${R1_LIST[$i]}"
        if [[ -f "$r1" ]]; then
            local reads; reads=$(zcat -- "$r1" 2>/dev/null | wc -l); reads=$(( reads / 4 ))
            add_metric "$sid" "reads_raw" "$reads" "count" "qc_raw"
        fi
    done
    local filtered_vcf="$OUTDIR/analyze/cohort.filtered.vcf.gz"
    if [[ -s "$filtered_vcf" ]]; then
        local n_pass
        n_pass=$(zcat -- "$filtered_vcf" 2>/dev/null | awk -F'\t' '!/^#/ && $7 == "PASS"' | wc -l)
        add_metric "" "n_variants_pass" "$n_pass" "count" "analyze"
    fi

    # --- write manifest.json ---
    local manifest="$pub_dir/manifest.json"
    cat > "$manifest" <<JSON
{
  "pipeline": {
    "name": "variant-call",
    "version": "1.0.0",
    "implementation": "bash",
    "git_sha": "$git_sha",
    "run_id": "$run_id",
    "started_at": "$started_at",
    "finished_at": "$finished_at",
    "exit_status": "success"
  },
  "platform": {
    "kind": "$platform_kind"
  },
  "reference": {
    "genome": "$genome_desc"
  },
  "samples": [$samples_json],
  "outputs": [$outputs_json],
  "metrics": [$metrics_json]
}
JSON
    [[ -s "$manifest" ]] || { log "publish: failed to write manifest.json"; return 1; }

    # --- tidy TSVs ---
    local tsv_dir="$pub_dir/tsv"
    mkdir -p "$tsv_dir"
    {
        printf 'sample_id\tcondition\treplicate\tlibrary_type\n'
        for i in "${!SAMPLE_IDS[@]}"; do
            local lib="paired"; [[ -z "${R2_LIST[$i]}" ]] && lib="single"
            printf '%s\t%s\t%s\t%s\n' "${SAMPLE_IDS[$i]}" "${COND_LIST[$i]:-}" "${REPL_LIST[$i]:-}" "$lib"
        done
    } > "$tsv_dir/samples.tsv"

    log "stage 9: publish complete - manifest at $manifest (git_sha=$git_sha), tidy TSVs at $tsv_dir"
    log "NOTE: is_synthetic_phenotype is true for this whole cohort - 'condition' is a synthetic grouping factor for pipeline testing, never a real clinical finding."
}
