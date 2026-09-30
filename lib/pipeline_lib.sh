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

# SCRIPT_DIR used to live here as a second name for REPO_ROOT, read only by the
# hand-rolled git provenance in stage_publish. lib/write_manifest.sh works the
# commit out from its own location instead, so nothing reads it any more.

: "${PIPELINE_STARTED_AT:=$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# lib/write_manifest.sh reads the start time from RUN_STARTED, and warns to
# stderr and records the finish time instead if it is missing. Same instant,
# second name, exported from the one place every driver passes through - so
# run_pipeline.sh and run_cohort.sh cannot disagree about when the run began.
export RUN_STARTED="$PIPELINE_STARTED_AT"

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

# --- Explorer defaults, and why they are LAST ---------------------------------
# The whole cohort run uses one reference and one region, and naming them here
# means neither .sbatch script has to carry a path. But they are applied only
# after all four precedence levels above have had their turn, so they can do
# nothing except fill a gap that everything else left empty:
#
#   REF=$PWD/smoke.fa REGION=smoke_1mb bash run_pipeline.sh ...
#
# still runs against the smoke reference, because REF set in the environment is
# level 1 and has already won by the time these two lines execute. `:-` rather
# than `=` matters as much: conf/pipeline.env ships REFERENCE_FASTA="" (set, but
# empty), and only `:-` treats that as the gap it plainly is.
REFERENCE_FASTA=${REFERENCE_FASTA:-/courses/BINF6610.202710/data/refs/grch38-1000g/GRCh38_full_analysis_set_plus_decoy_hla.fa}
CALL_REGION=${CALL_REGION:-chr20:1-10000000}

# --- where relative FASTQ paths point -----------------------------------------
# A samplesheet may store its FASTQ paths relative rather than absolute:
# smoke/samplesheet.csv does, and says so in smoke/README.txt ("FASTQ paths are
# relative to this folder"). Until now that only worked if you happened to be
# standing in the right directory, which is why the brief's smoke command opens
# with `cd smoke`. Under Slurm you are not standing there: the job's working
# directory is $SLURM_SUBMIT_DIR, so the same sheet would resolve every path
# against the repository root and stage 0 would report eight missing files.
#
# FASTQ_ROOT names the directory those relative paths hang off. Unset, it is the
# SAMPLESHEET'S OWN directory, which is the reading smoke/README.txt documents
# and makes `cd smoke` optional instead of required. An absolute path in the
# sheet is never touched, so the cohort sheet and the acceptance fixtures (both
# absolute) are unaffected either way.
FASTQ_ROOT=${FASTQ_ROOT:-}

# fastq_root -> the directory relative FASTQ paths resolve against
fastq_root() {
    if [[ -n "${FASTQ_ROOT:-}" ]]; then
        printf '%s' "$FASTQ_ROOT"
    else
        dirname -- "$SAMPLESHEET"
    fi
}

# root_fastq <root> <path> -> sets REPLY to <path> made absolute against <root>
# Sets REPLY rather than printing, so that reading a sheet costs no subshell per
# field. An empty path stays empty: that is how the sheet spells single-end.
root_fastq() {
    local root=$1 p=$2
    if [[ -z "$p" || "$p" == /* ]]; then
        REPLY="$p"
    else
        REPLY="$root/$p"
    fi
}

# --- scratch space ----------------------------------------------------------
# Both .sbatch scripts point TMPDIR at the compute node's own disk and remove
# it from a trap. Until now nothing read it, so the two tools that spill did
# what they do by default: samtools sort drops its temp chunks NEXT TO THE
# OUTPUT, and GATK uses java.io.tmpdir. On Explorer "next to the output" is
# /scratch, shared with every other job on the filesystem - eight array tasks
# writing and deleting spill files there buys nothing and costs everyone.
#
# Resolved once, here, so that every stage below uses the same directory and a
# laptop run (no TMPDIR set) still works.
PIPE_TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$PIPE_TMPDIR"

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

# --- resume: the two halves of it, which only work as a pair ----------------
#
# Every stage that writes a file now does two things: it skips the work when
# its output is already there, and it writes under a temporary name so that a
# file under the REAL name is only ever a finished one.
#
# Neither half is safe alone. A skip-if-exists test over a tool that writes
# straight to its final path is WORSE than no test: `scancel`, a --time
# TIMEOUT or an OOM kill during stage 3 leaves a truncated BAM under the name
# the next run tests for, so the rerun skips it and every stage downstream
# quietly analyses a half-written file. That is precisely the failure mode
# Assignment 2's deliverable 4 asks us to provoke and report on.
#
# The temporary name keeps the real extension (`.partial.bam`, not `.bam.tmp`):
# GATK picks its output format from the extension and refuses to write a file
# it cannot classify.
#
# partial_name <final> <marker> -> the sibling temp path for <final>
# Inserts <marker> before the extension-bearing tail, so the tool still sees a
# name it understands. Same directory as the final file, which is what makes
# the later `mv` a rename within one filesystem, and so atomic.
partial_name() {
    local final=$1 marker=${2:-partial} dir base
    dir=$(dirname -- "$final")
    base=$(basename -- "$final")
    case "$base" in
        *.g.vcf.gz)  printf '%s/%s.%s.g.vcf.gz' "$dir" "${base%.g.vcf.gz}"  "$marker" ;;
        *.vcf.gz)    printf '%s/%s.%s.vcf.gz'   "$dir" "${base%.vcf.gz}"    "$marker" ;;
        *.bam)       printf '%s/%s.%s.bam'      "$dir" "${base%.bam}"       "$marker" ;;
        *)           printf '%s.%s'             "$final" "$marker" ;;
    esac
}

# discard_partial <path...> - remove leftovers from a killed run before reusing
# the name. A stale .partial from last time is never trusted, only deleted.
discard_partial() {
    local p
    for p in "$@"; do
        rm -f -- "$p" "$p".tbi "$p".bai "$p".idx
    done
    return 0
}

# publish_atomic <partial> <final>
# Renames the finished output into place, sidecar index FIRST and the data file
# LAST. That order is the whole point: <final> is the name every skip-if-exists
# guard tests, so it must be the last name to appear. A kill between the two
# renames leaves an index with no BAM/VCF beside it, the guard sees nothing,
# and the rerun redoes the work - which is the safe direction to fail in.
publish_atomic() {
    local partial=$1 final=$2 ext
    for ext in .tbi .bai .idx; do
        if [[ -e "${partial}${ext}" ]]; then
            mv -f -- "${partial}${ext}" "${final}${ext}"
        fi
    done
    mv -f -- "$partial" "$final"
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

    # The same rooting read_samples() applies, because stage 0 parses the sheet
    # itself and never calls it. Without this, a relative sheet would have
    # stage 0 reporting files as missing that every later stage resolves fine.
    local root
    root=$(fastq_root)

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
        local lib="${fields[$idx_lib]:-}"
        local r1 r2
        root_fastq "$root" "${fields[$idx_r1]:-}"; r1="$REPLY"
        root_fastq "$root" "${fields[$idx_r2]:-}"; r2="$REPLY"

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

    local root
    root=$(fastq_root)

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

        # Rooted here, once, so that no stage ever handles a relative path and
        # none of them has to know where the sheet came from.
        local v_r1
        root_fastq "$root" "${row[$idx_r1]:-}"; v_r1="$REPLY"
        root_fastq "$root" "$v_r2";            v_r2="$REPLY"

        SAMPLE_IDS+=("${row[$idx_id]:-}")
        R1_LIST+=("$v_r1")
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

        if [[ -s "$bam" ]]; then
            log "align: $sample_id already done, skipping"
            continue
        fi
        log "align: $sample_id"

        local bam_part
        bam_part=$(partial_name "$bam")
        discard_partial "$bam_part"

        # `| samtools view` is only safe because pipefail is on: without it bwa
        # could die and samtools would still exit 0 on the empty stream.
        if [[ -n "$r2" ]]; then
            bwa mem -t "$threads" -R "$rg" "$REFERENCE_FASTA" "$r1" "$r2" 2> "$sample_dir/bwa.log" \
                | samtools view -b -o "$bam_part" - \
                || { log "bwa/samtools failed for sample '$sample_id'"; return 1; }
        else
            bwa mem -t "$threads" -R "$rg" "$REFERENCE_FASTA" "$r1" 2> "$sample_dir/bwa.log" \
                | samtools view -b -o "$bam_part" - \
                || { log "bwa/samtools failed for sample '$sample_id'"; return 1; }
        fi

        [[ -s "$bam_part" ]] || { log "align produced an empty BAM for sample '$sample_id'"; return 1; }
        publish_atomic "$bam_part" "$bam"
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

        # The stage's real product is the deduplicated BAM AND its index: every
        # stage downstream needs both, so a rerun that found only the BAM would
        # skip and then fail in stage 5. Test for the pair.
        if [[ -s "$dedup_bam" && -s "${dedup_bam}.bai" ]]; then
            log "postprocess: $sample_id already done, skipping"
            continue
        fi
        log "postprocess: $sample_id"

        [[ -s "$align_bam" ]] \
            || { log "postprocess: no aligned BAM for sample '$sample_id' (expected $align_bam - run stage align first)"; return 1; }

        # The sort has its own guard: it is the expensive half, and a job killed
        # during MarkDuplicates should not pay for it twice.
        if [[ -s "$sorted_bam" ]]; then
            log "postprocess: $sample_id sort already done, reusing"
        else
            local sorted_part
            sorted_part=$(partial_name "$sorted_bam")
            discard_partial "$sorted_part"
            # -T keeps the spill chunks on node-local disk instead of beside the
            # output. The sample id is in the prefix as well as $$ so that two
            # samples sorted by the SAME process (the laptop path, where all of
            # them run in one) cannot collide over a previous sort's leftovers.
            samtools sort -@ "$threads" -T "$PIPE_TMPDIR/sort.${sample_id}.$$" \
                -o "$sorted_part" "$align_bam" \
                > "$sample_dir/sort.log" 2>&1 \
                || { log "samtools sort failed for sample '$sample_id'"; return 1; }
            publish_atomic "$sorted_part" "$sorted_bam"
        fi

        local dedup_part
        dedup_part=$(partial_name "$dedup_bam")
        discard_partial "$dedup_part"

        # MarkDuplicates holds read ends in memory and spills the overflow; on
        # this cohort that spill is the largest temp write in the pipeline.
        #
        # --TMP_DIR, not --tmp-dir. MarkDuplicates is one of the Picard tools
        # GATK wraps and it keeps Picard's SHOUTING_SNAKE_CASE argument names;
        # every other gatk call below is a GATK-engine tool and takes
        # --tmp-dir. Measured: --tmp-dir here exits 1 with "tmp-dir is not a
        # recognized option" after printing its entire usage, so the mistake is
        # cheap to make and expensive to read.
        gatk MarkDuplicates \
            -I "$sorted_bam" \
            -O "$dedup_part" \
            -M "$metrics" \
            --TMP_DIR "$PIPE_TMPDIR" \
            > "$sample_dir/markdup.log" 2>&1 \
            || { log "gatk MarkDuplicates failed for sample '$sample_id'"; return 1; }

        # Index the partial, so that the .bai is already in place beside the
        # real name the instant the BAM gets it.
        samtools index "$dedup_part" \
            > "$sample_dir/index.log" 2>&1 \
            || { log "samtools index failed for sample '$sample_id'"; return 1; }

        [[ -s "$dedup_part" ]] || { log "postprocess produced an empty BAM for sample '$sample_id'"; return 1; }
        publish_atomic "$dedup_part" "$dedup_bam"
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

        # GVCF and .tbi both, for the same reason as the BAM above: stage 6
        # hands GenomicsDBImport the GVCF path and it reads the index next to it.
        if [[ -s "$gvcf" && -s "${gvcf}.tbi" ]]; then
            log "quantify: $sample_id already done, skipping"
            continue
        fi
        log "quantify: $sample_id"

        [[ -s "$dedup_bam" ]] \
            || { log "quantify: no deduplicated BAM for sample '$sample_id' (expected $dedup_bam - run stage postprocess first)"; return 1; }

        local gvcf_part
        gvcf_part=$(partial_name "$gvcf")
        discard_partial "$gvcf_part"

        gatk HaplotypeCaller \
            -R "$REFERENCE_FASTA" \
            -I "$dedup_bam" \
            -O "$gvcf_part" \
            -ERC GVCF \
            -L "$CALL_REGION" \
            --tmp-dir "$PIPE_TMPDIR" \
            > "$sample_dir/haplotypecaller.log" 2>&1 \
            || { log "gatk HaplotypeCaller failed for sample '$sample_id'"; return 1; }

        [[ -s "$gvcf_part" ]] || { log "quantify produced an empty GVCF for sample '$sample_id'"; return 1; }
        publish_atomic "$gvcf_part" "$gvcf"
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

    local cohort_vcf="$merge_dir/cohort.vcf.gz"

    # Cohort stages guard the whole function, not a loop body: there is one
    # output and it is all-or-nothing. Skipping here also means the `rm -rf`
    # below is never reached on a rerun, so a finished GenomicsDB workspace is
    # not destroyed just to rebuild the VCF that was already made from it.
    if [[ -s "$cohort_vcf" && -s "${cohort_vcf}.tbi" ]]; then
        log "stage 6: cohort VCF already present, skipping merge - $cohort_vcf"
        return 0
    fi

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

    # The workspace goes on the NODE'S disk, not under OUTDIR.
    #
    # GenomicsDBImport writes this folder and GenotypeGVCFs reads it straight
    # back, and on Explorer OUTDIR is /scratch - a network mount. The course's
    # week-2 page measured the pair of steps over these eight GVCFs at 36, 58
    # and 96 minutes with the workspace on /scratch, against 8 minutes with it
    # in ${TMPDIR}, for the same 36,853 records. It is the single largest
    # difference in the whole cohort job.
    #
    # It is also purely intermediate: both steps that touch it run inside this
    # one function, so nothing outside stage 6 ever needs it, and the job's
    # trap removing ${TMPDIR} takes it away for free. A cohort job killed
    # between the two steps loses the workspace and rebuilds it, which is
    # correct - the guard above keys off the cohort VCF, never off the
    # workspace, so a half-built one can never be mistaken for a finished one.
    local db_dir="$PIPE_TMPDIR/genomicsdb"
    rm -rf "$db_dir"   # GenomicsDBImport refuses to write into an existing workspace

    log "merge: importing ${#SAMPLE_IDS[@]} sample(s) into GenomicsDB"
    gatk GenomicsDBImport \
        --sample-name-map "$map_file" \
        --genomicsdb-workspace-path "$db_dir" \
        --intervals "$CALL_REGION" \
        --tmp-dir "$PIPE_TMPDIR" \
        > "$merge_dir/genomicsdbimport.log" 2>&1 \
        || { log "gatk GenomicsDBImport failed"; return 1; }

    log "merge: joint genotyping across the cohort"
    local cohort_part
    cohort_part=$(partial_name "$cohort_vcf")
    discard_partial "$cohort_part"

    gatk GenotypeGVCFs \
        -R "$REFERENCE_FASTA" \
        -V "gendb://$db_dir" \
        -O "$cohort_part" \
        -L "$CALL_REGION" \
        --tmp-dir "$PIPE_TMPDIR" \
        > "$merge_dir/genotypegvcfs.log" 2>&1 \
        || { log "gatk GenotypeGVCFs failed"; return 1; }

    [[ -s "$cohort_part" ]] || { log "merge produced an empty cohort VCF"; return 1; }
    publish_atomic "$cohort_part" "$cohort_vcf"

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

    local analyze_dir="$OUTDIR/analyze"
    mkdir -p "$analyze_dir"
    local filtered_vcf="$analyze_dir/cohort.filtered.vcf.gz"

    # Guarded before the input check on purpose: if this stage's own output is
    # already complete there is nothing to say about stage 6's, and a rerun
    # should not fail over an input it no longer needs.
    if [[ -s "$filtered_vcf" && -s "${filtered_vcf}.tbi" ]]; then
        log "stage 7: filtered cohort VCF already present, skipping analyze - $filtered_vcf"
        _analyze_synthetic_note
        return 0
    fi

    local cohort_vcf="$OUTDIR/merge/cohort.vcf.gz"
    [[ -s "$cohort_vcf" ]] \
        || { log "analyze: no cohort VCF found (expected $cohort_vcf - run stage merge first)"; return 1; }

    # Standard GATK germline hard-filter thresholds, applied as one combined
    # pass rather than the usual separate SNP/indel split - a reasonable
    # simplification at this scale (10Mb, 8 samples).
    log "analyze: applying hard filters"
    local filtered_part
    filtered_part=$(partial_name "$filtered_vcf")
    discard_partial "$filtered_part"

    gatk VariantFiltration \
        -R "$REFERENCE_FASTA" \
        -V "$cohort_vcf" \
        -O "$filtered_part" \
        --filter-expression "QD < 2.0"             --filter-name "QD2" \
        --filter-expression "FS > 60.0"             --filter-name "FS60" \
        --filter-expression "MQ < 40.0"             --filter-name "MQ40" \
        --filter-expression "MQRankSum < -12.5"     --filter-name "MQRankSum-12.5" \
        --filter-expression "ReadPosRankSum < -8.0" --filter-name "ReadPosRankSum-8" \
        --filter-expression "SOR > 3.0"             --filter-name "SOR3" \
        --tmp-dir "$PIPE_TMPDIR" \
        > "$analyze_dir/variantfiltration.log" 2>&1 \
        || { log "gatk VariantFiltration failed"; return 1; }

    [[ -s "$filtered_part" ]] || { log "analyze produced an empty filtered VCF"; return 1; }
    publish_atomic "$filtered_part" "$filtered_vcf"

    log "stage 7: analyze complete - filtered/annotated cohort VCF at $filtered_vcf"
    _analyze_synthetic_note
}

# Said on every path through stage 7, including the one that skips the work.
# A resumed run produces the same VCF as a fresh one and so owes the reader the
# same warning about what 'condition' in it actually is; losing the caveat
# because the file happened to be cached already is exactly the wrong failure.
_analyze_synthetic_note() {
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
    log "stage 9 (publish): tidy TSVs + qc metrics + manifest.json"

    # read_samples() carries condition/replicate as well as the FASTQ columns,
    # so the tidy TSV stays row-aligned with SAMPLE_IDS even when a filter is
    # active. Parsing the sheet a second time here used to be safe only
    # because nothing filtered; it would misalign the moment one did.
    read_samples

    # --- tidy TSVs -----------------------------------------------------------
    # Written BEFORE the manifest, because write_manifest.sh checksums every
    # file it can find under OUTDIR: anything produced after it runs is simply
    # invisible to it. It already knows a file called samples.tsv is stage
    # "publish", type "samples", which is exactly what this is.
    local tsv_dir="$OUTDIR/publish/tsv"
    mkdir -p "$tsv_dir"
    {
        printf 'sample_id\tcondition\treplicate\tlibrary_type\n'
        local i lib
        for i in "${!SAMPLE_IDS[@]}"; do
            lib="paired"; [[ -z "${R2_LIST[$i]}" ]] && lib="single"
            printf '%s\t%s\t%s\t%s\n' \
                   "${SAMPLE_IDS[$i]}" "${COND_LIST[$i]:-}" "${REPL_LIST[$i]:-}" "$lib"
        done
    } > "$tsv_dir/samples.tsv"

    # --- db/qc_metrics.tsv ---------------------------------------------------
    # The same two metrics this stage has always measured, now handed over in
    # the long format write_manifest.sh reads rather than formatted into JSON
    # here. It looks for db/qc_metrics.tsv (then qc_metrics.tsv) under OUTDIR
    # and turns every numeric row into one manifest metrics[] entry. An empty
    # sample_id marks a cohort-level metric and becomes JSON null.
    mkdir -p "$OUTDIR/db"
    {
        printf 'sample_id\tmetric\tvalue\tunit\tstage\n'
        local sid r1 reads
        for i in "${!SAMPLE_IDS[@]}"; do
            sid="${SAMPLE_IDS[$i]}"; r1="${R1_LIST[$i]}"
            [[ -f "$r1" ]] || continue
            reads=$(zcat -- "$r1" 2>/dev/null | wc -l); reads=$(( reads / 4 ))
            printf '%s\treads_raw\t%s\tcount\tqc_raw\n' "$sid" "$reads"
        done
        local filtered_vcf="$OUTDIR/analyze/cohort.filtered.vcf.gz" n_pass
        if [[ -s "$filtered_vcf" ]]; then
            n_pass=$(zcat -- "$filtered_vcf" 2>/dev/null | awk -F'\t' '!/^#/ && $7 == "PASS"' | wc -l)
            printf '\tn_variants_pass\t%s\tcount\tanalyze\n' "$n_pass"
        fi
    } > "$OUTDIR/db/qc_metrics.tsv"

    # --- manifest.json -------------------------------------------------------
    # The course's script, unmodified, in place of the JSON this function used
    # to build by hand. It writes "$OUTDIR/manifest.json" - the results
    # directory it is handed, with no subfolder of its own - so the manifest no
    # longer sits under publish/.
    #
    # REPO_ROOT rather than a HERE from the driver: run_cohort.sh runs this
    # stage too and defines no such variable, and under set -u that would be a
    # crash on the cluster path rather than a manifest.
    bash "$REPO_ROOT/lib/write_manifest.sh" \
         "$OUTDIR" "$SAMPLESHEET" "${REFERENCE_FASTA:-}" "${CALL_REGION:-}"

    local manifest="$OUTDIR/manifest.json"
    [[ -s "$manifest" ]] || { log "publish: write_manifest.sh wrote no manifest.json"; return 1; }

    log "stage 9: publish complete - manifest at $manifest, tidy TSVs at $tsv_dir"
    log "NOTE: is_synthetic_phenotype is true for this whole cohort - 'condition' is a synthetic grouping factor for pipeline testing, never a real clinical finding."
}
