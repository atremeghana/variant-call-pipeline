#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_acceptance.sh — the tests that grade Assignment 1.
#
#   bash tests/run_acceptance.sh /path/to/your-repo
#   bash tests/run_acceptance.sh /path/to/your-repo name    # only matching tests
#
# This is the same file used for grading. Nothing is hidden, and you should run
# it constantly rather than once at the end.
#
# EVERY CHECK HERE IS SOMETHING WEEK 1 TAUGHT. If a test surprises you, the
# lecture covered it and the demo pipeline shows it — go back to that slide.
#
# NO SEQUENCING DATA IS REQUIRED. Every fixture is built here, in a temp
# directory, out of a handful of synthetic reads, so the whole suite runs in
# seconds and there is no excuse for discovering a failure at submission time.
#
# HOW YOUR PIPELINE IS INVOKED
#
#     ./run_pipeline.sh <samplesheet.csv> <outdir> validate
#
# Three positional arguments, exactly like the demo: the sheet, where to write,
# and the last stage to run. `validate` must run stage 0 and stop. If your
# driver cannot stop after a named stage it will fail most of these tests — and
# it is the thing you will want most while developing, because it is how you
# test stage 0 without waiting for an alignment.
#
# THE SAMPLESHEET THESE TESTS HAND YOU
#
# Six columns, no quoting, the same contract as the demo:
#
#     sample_id,condition,replicate,library_type,r1_fastq,r2_fastq
#
# WHAT THIS SUITE CANNOT SEE
#
# One test reads your code rather than running it — `set -euo pipefail` is
# checked by looking for it, because proving it fires needs a real alignment to
# kill. It says so in its own output. Passing it is necessary, not sufficient.
#
# Three tests pass when stage 0 raises no complaint, so they are gated behind a
# positive control that proves your driver reads the samplesheet at all. See
# `sheet_is_read` below for why.
#-----------------------------------------------------------------------------
set -uo pipefail        # NOT -e: a failing assertion must not stop the suite

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'error: bash >= 4.3 required to run these tests, found %s\n' "${BASH_VERSION}" >&2
    printf '       on macOS: brew install bash, then run with /opt/homebrew/bin/bash\n' >&2
    exit 70
fi

REPO=${1:-.}
FILTER=${2:-}
REPO=$(cd -- "${REPO}" && pwd) || { printf 'error: no such directory: %s\n' "${1:-.}" >&2; exit 66; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/binf6610-accept.XXXXXX") || exit 70
trap 'rm -rf "${WORK}"' EXIT

pass=0 fail=0
declare -a FAILURES=()

if [[ -t 1 ]]; then
    C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'
    C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else
    C_OK='' C_BAD='' C_DIM='' C_RST=''
fi

want() { [[ -z "${FILTER}" ]] || [[ "$1" == *"${FILTER}"* ]]; }

ok()   { pass=$(( pass + 1 )); printf '  %sPASS%s  %s\n' "${C_OK}"  "${C_RST}" "$1"; }
no()   { fail=$(( fail + 1 )); FAILURES+=( "$1" )
         printf '  %sFAIL%s  %s\n' "${C_BAD}" "${C_RST}" "$1"
         [[ -n "${2:-}" ]] && printf '        %s%s%s\n' "${C_DIM}" "$2" "${C_RST}"; }
note() { printf '        %s%s%s\n' "${C_DIM}" "$1" "${C_RST}"; }

#-----------------------------------------------------------------------------
# Fixtures. Four-line records, real gzip, deliberately tiny.
#-----------------------------------------------------------------------------
fq() {                       # fq <path> <n_records>
    local path=$1 n=$2 i
    { for (( i = 1; i <= n; i++ )); do
          printf '@read%d/1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n' "${i}"
      done
    } | gzip -c > "${path}"
}

FQ="${WORK}/fastq"
mkdir -p "${FQ}"
for s in NA12878 NA12891 NA12892; do
    fq "${FQ}/${s}_R1.fastq.gz" 4
    fq "${FQ}/${s}_R2.fastq.gz" 4
done
fq "${FQ}/shortmate_R1.fastq.gz" 5
fq "${FQ}/shortmate_R2.fastq.gz" 4          # one mate short
fq "${FQ}/Donor 3-rep1_R1.fastq.gz" 4       # a space and a hyphen, on purpose
fq "${FQ}/Donor 3-rep1_R2.fastq.gz" 4

# A real gzip stream with its tail cut off: `gzip -t` must reject it.
fq "${FQ}/whole.fastq.gz" 20
head -c 120 "${FQ}/whole.fastq.gz" > "${FQ}/cut_R1.fastq.gz"
cp "${FQ}/NA12891_R2.fastq.gz"            "${FQ}/cut_R2.fastq.gz"

# The contract, and nothing else. Six columns, unquoted — the same sheet the
# demo pipeline reads, so `while IFS=, read -r id cond rep lt r1 r2` works.
HDR='sample_id,condition,replicate,library_type,r1_fastq,r2_fastq'

sheet() {                    # sheet <name> <rows...>  -> prints the path
    local name=$1; shift
    local p="${WORK}/${name}.csv"
    printf '%s\n' "${HDR}" > "${p}"
    printf '%s\n' "$@" >> "${p}"
    printf '%s' "${p}"
}

row() {                      # row <id> <condition> <rep> <libtype> <r1> [r2]
    printf '%s,%s,%s,%s,%s,%s' "$1" "$2" "$3" "$4" "$5" "${6:-}"
}

GOOD=$(sheet good \
    "$(row NA12878 affected   1 paired "${FQ}/NA12878_R1.fastq.gz" "${FQ}/NA12878_R2.fastq.gz")" \
    "$(row NA12891 unaffected 2 paired "${FQ}/NA12891_R1.fastq.gz" "${FQ}/NA12891_R2.fastq.gz")")

DUP=$(sheet duplicate \
    "$(row NA12878 affected   1 paired "${FQ}/NA12878_R1.fastq.gz" "${FQ}/NA12878_R2.fastq.gz")" \
    "$(row NA12878 unaffected 2 paired "${FQ}/NA12891_R1.fastq.gz" "${FQ}/NA12891_R2.fastq.gz")")

CUT=$(sheet cutgzip \
    "$(row NA12878 affected   1 paired "${FQ}/NA12878_R1.fastq.gz" "${FQ}/NA12878_R2.fastq.gz")" \
    "$(row NA12891 unaffected 2 paired "${FQ}/cut_R1.fastq.gz"     "${FQ}/cut_R2.fastq.gz")")

WEIRD=$(sheet weirdname \
    "$(row 'Donor 3-rep1' affected 1 paired "${FQ}/Donor 3-rep1_R1.fastq.gz" "${FQ}/Donor 3-rep1_R2.fastq.gz")" \
    "$(row NA12891 unaffected 2 paired "${FQ}/NA12891_R1.fastq.gz" "${FQ}/NA12891_R2.fastq.gz")")

# The single-end sample here is NOT one of the two that are single-end in the real
# cohort. A pipeline that hard-codes which samples are single-end passes on the
# real sheet and fails right here, which is the entire point of the test.
SINGLE=$(sheet singleend \
    "$(row NA12878 affected   1 single "${FQ}/NA12878_R1.fastq.gz" "")" \
    "$(row NA12891 unaffected 2 paired "${FQ}/NA12891_R1.fastq.gz" "${FQ}/NA12891_R2.fastq.gz")")

# Three different problems, in three different samples, all at once. A stage 0
# that dies on the first one names only BADPATH.
MANY=$(sheet manyproblems \
    "$(row BADPATH  affected   1 paired "${FQ}/does_not_exist_R1.fastq.gz" "${FQ}/does_not_exist_R2.fastq.gz")" \
    "$(row NOMATE   unaffected 2 paired "${FQ}/NA12891_R1.fastq.gz" "")" \
    "$(row CUTGZIP  affected   3 paired "${FQ}/cut_R1.fastq.gz"     "${FQ}/cut_R2.fastq.gz")" \
    "$(row NA12892  unaffected 4 paired "${FQ}/NA12892_R1.fastq.gz" "${FQ}/NA12892_R2.fastq.gz")")

#-----------------------------------------------------------------------------
# validate <sheet> <outdir> -> prints "<exit>|<combined output>"
#-----------------------------------------------------------------------------
# HOW YOUR DRIVER IS CALLED, and why there are two ways.
#
# The demo pipeline takes three positional arguments and the brief documents
# that. One slide in the lecture writes the same thing as `--to validate`. Both
# readings are defensible, so this harness does not pick a winner: it reads your
# driver once and calls it the way you wrote it. Whichever you chose, every test
# below runs against it.
INVOKE=positional
if grep -qE -- '--samplesheet|--outdir|--to[[:space:]]|--to=' "${REPO}/run_pipeline.sh" 2>/dev/null \
   || grep -rqE -- '--samplesheet|--outdir' "${REPO}/lib" 2>/dev/null; then
    INVOKE=flags
fi

run_validate() {
    local sheet=$1 outdir=$2 out rc
    if [[ "${INVOKE}" == flags ]]; then
        out=$( cd "${REPO}" && bash ./run_pipeline.sh \
                 --samplesheet "${sheet}" --outdir "${outdir}" --to validate 2>&1 )
    else
        out=$( cd "${REPO}" && bash ./run_pipeline.sh "${sheet}" "${outdir}" validate 2>&1 )
    fi
    rc=$?
    printf '%s|%s' "${rc}" "${out}"
}

# Stage 0 validates the REFERENCE as well as the samplesheet, and it is right to.
# But a GRCh38 index is five gigabytes and an hour to build, so these tests must
# not require one. A positive test therefore asserts that stage 0 raised no
# complaint ABOUT THE SAMPLE — a reference that is not built yet is reported once,
# on its own, rather than showing up as several mysterious failures.
ref_complaint() {
    [[ "$1" == *"index"* || "$1" == *"GTF"* || "$1" == *"reference"* \
       || "$1" == *"genome"* || "$1" == *"FASTA"* || "$1" == *"fasta"* ]]
}
# sample_ok <output> <sample_id> -> 0 if nothing was said against that sample
sample_ok() {
    local out=$1 id=$2 line
    while IFS= read -r line; do
        [[ "${line}" == *"${id}"* ]] || continue
        [[ "${line}" == *ERROR* || "${line}" == *error* ]] || continue
        ref_complaint "${line}" && continue
        return 1
    done <<< "${out}"
    return 0
}

# A POSITIVE CONTROL, because silence is not evidence.
#
# Stage 0's correct answer to a good sample is to say nothing about it. Several
# tests therefore pass when the output holds no complaint naming the sample —
# which is exactly what a driver that never opens the samplesheet also produces.
# Measured 2026-09-07: a two-line `run_pipeline.sh` whose whole body was
# `echo hello` scored 4 of 9 on the previous version of this suite, and three of
# those four were these tests. That is a check reporting PASS while measuring
# nothing, which is the failure this course exists to teach.
#
# The weakest fair control is the one used here: a pipeline that reads the sheet
# must answer DIFFERENTLY when handed one that is not there. It asks for nothing
# the brief does not already require.
SHEET_IS_READ=-1
sheet_is_read() {
    if (( SHEET_IS_READ < 0 )); then
        local with_sheet without_sheet
        with_sheet=$(run_validate    "${GOOD}"                         "${WORK}/probe-with")
        without_sheet=$(run_validate "${WORK}/no-such-samplesheet.csv" "${WORK}/probe-without")
        if [[ "${with_sheet}" != "${without_sheet}" ]]; then
            SHEET_IS_READ=1
        else
            SHEET_IS_READ=0
        fi
    fi
    (( SHEET_IS_READ == 1 ))
}
NOT_READING='your driver answered a real samplesheet and a samplesheet that does not exist
        identically, so nothing has shown that stage 0 reads the sheet. This test
        checks how a sample is HANDLED, and it cannot mean anything until something
        handles it. Build stage 0 first.'

# Every shell script in the repo, comments stripped, for the two tests that read
# code. Layout-agnostic on purpose: the brief lets you start as one file.
shell_files() {
    ( cd "${REPO}" && find . -name '*.sh' -not -path './.git/*' -not -path './tests/*' | sort )
}
uncommented() {   # uncommented <file> -> the file with # comments removed
    sed 's/[[:space:]]*#.*$//' "${REPO}/$1"
}

printf '\n%sBINF6610 Assignment 1 — acceptance tests%s\n' "${C_DIM}" "${C_RST}"
printf '%srepo: %s%s\n' "${C_DIM}" "${REPO}" "${C_RST}"
printf '%sdriver called as: %s%s\n\n' "${C_DIM}" \
       "$( [[ "${INVOKE}" == flags ]] && echo './run_pipeline.sh --samplesheet S --outdir D --to validate' \
                                      || echo './run_pipeline.sh S D validate' )" "${C_RST}"

[[ -f "${REPO}/run_pipeline.sh" ]] || {
    printf '  %sFAIL%s  run_pipeline.sh not found in %s\n' "${C_BAD}" "${C_RST}" "${REPO}"
    printf '\n  Nothing else can run without it.\n\n'
    exit 1
}

#-- 1 · 20 marks -------------------------------------------------------------
# Stage 0 reports every problem it finds, together.
if want everything; then
    r=$(run_validate "${MANY}" "${WORK}/out-many"); rc=${r%%|*}; out=${r#*|}
    missed=()
    for id in BADPATH NOMATE CUTGZIP; do
        [[ "${out}" == *"${id}"* ]] || missed+=( "${id}" )
    done
    if (( rc == 0 )); then
        no "stage 0 reports every problem together" \
           "four samples, three of them broken, and stage 0 exited 0. It has to fail."
    elif (( ${#missed[@]} > 0 )); then
        no "stage 0 reports every problem together" \
           "exited ${rc}, but never named: ${missed[*]}. A stage 0 that dies on the first
        problem costs one run per typo. Collect them, then exit once."
    else
        ok "stage 0 reports every problem together (exit ${rc})"
        note 'a missing file, a paired row with no R2, and a corrupt gzip — all three named.'
    fi
fi

#-- 2 · 15 marks -------------------------------------------------------------
# A sample name with a space in it.
if want name; then
    if ! sheet_is_read; then
        no "survives a sample named 'Donor 3-rep1'" "${NOT_READING}"
    else
        r=$(run_validate "${WEIRD}" "${WORK}/out-weird"); out=${r#*|}
        if sample_ok "${out}" 'Donor 3-rep1'; then
            ok "survives a sample named 'Donor 3-rep1'"
        else
            no "survives a sample named 'Donor 3-rep1'" \
               "an unquoted \$id or \$r1 split on the space. Every expansion needs quotes:
        \"\$r1\", not \$r1."
        fi
    fi
fi

#-- 3 · 10 marks -------------------------------------------------------------
# A corrupt gzip stream.
if want truncated; then
    r=$(run_validate "${CUT}" "${WORK}/out-cut"); rc=${r%%|*}; out=${r#*|}
    if (( rc != 0 )) && [[ "${out}" == *NA12891* ]]; then
        ok "catches a truncated .fastq.gz in stage 0"
    elif (( rc != 0 )); then
        no "catches a truncated .fastq.gz in stage 0" \
           "it failed, but never named NA12891 — say which sample, or nobody can fix it."
    else
        no "catches a truncated .fastq.gz in stage 0" \
           "NA12891's R1 is a gzip stream with its tail cut off and stage 0 accepted it.
        \`gzip -t\` is the check; the file opens fine and ends in the middle."
    fi
fi

#-- 4 · 10 marks -------------------------------------------------------------
# The same sample_id twice.
if want duplicate; then
    r=$(run_validate "${DUP}" "${WORK}/out-dup"); rc=${r%%|*}; out=${r#*|}
    if (( rc != 0 )) && [[ "${out}" == *NA12878* ]]; then
        ok "rejects a duplicate sample_id"
    elif (( rc != 0 )); then
        no "rejects a duplicate sample_id" \
           "it failed, but never named NA12878 — an error that does not say which row is
        wrong is not actionable. Partial credit."
    else
        no "rejects a duplicate sample_id" \
           "NA12878 appears on two rows. Whichever runs second overwrites the first, and
        the cohort is quietly one sample smaller. The demo does it with
        \`awk -F, 'NR>1 { print \$1 }' \"\$SHEET\" | sort | uniq -d\`."
    fi
fi

#-- 5 · 10 marks -------------------------------------------------------------
# Single-end decided by the column, not by the name.
if want single; then
    if ! sheet_is_read; then
        no "single-end read from library_type, not from the name" "${NOT_READING}"
    else
        r=$(run_validate "${SINGLE}" "${WORK}/out-single"); out=${r#*|}
        if sample_ok "${out}" NA12878; then
            ok "single-end read from library_type, not from the name"
        else
            no "single-end read from library_type, not from the name" \
               "NA12878 is single-end HERE and paired in the real cohort. If your code
        decides from the sample's name it passes on the real sheet and fails on
        this one. Branch on \$lt."
        fi
    fi
fi

#-- 6 · 10 marks -------------------------------------------------------------
# set -euo pipefail, read from the code.
if want strict; then
    without=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        body=$(uncommented "${f}")
        has_e=0 has_u=0 has_p=0
        [[ "${body}" =~ set\ -[a-z]*e || "${body}" == *"set -o errexit"*  ]] && has_e=1
        [[ "${body}" =~ set\ -[a-z]*u || "${body}" == *"set -o nounset"*  ]] && has_u=1
        [[ "${body}" == *"pipefail"* ]]                                      && has_p=1
        (( has_e && has_u && has_p )) || without+=( "${f}" )
    done < <(shell_files)

    if (( ${#without[@]} == 0 )); then
        ok "set -euo pipefail in every script"
        note 'read from your code, not proven by killing a run. Necessary, not sufficient.'
    else
        no "set -euo pipefail in every script" \
           "missing -e, -u or pipefail in: ${without[*]}
        pipefail is the one that matters most here: without it a dead gzip feeding a
        happy wc gives you a count of 0 and an exit status of 0."
    fi
fi

#-- 7 · 10 marks -------------------------------------------------------------
# Progress to stderr, stdout left clean.
if want stderr; then
    if ! sheet_is_read; then
        no "progress messages go to stderr" "${NOT_READING}"
    else
        if [[ "${INVOKE}" == flags ]]; then
            sout=$( cd "${REPO}" && bash ./run_pipeline.sh --samplesheet "${GOOD}" \
                      --outdir "${WORK}/out-fd"  --to validate 2>/dev/null )
            serr=$( cd "${REPO}" && bash ./run_pipeline.sh --samplesheet "${GOOD}" \
                      --outdir "${WORK}/out-fd2" --to validate 2>&1 >/dev/null )
        else
            sout=$( cd "${REPO}" && bash ./run_pipeline.sh "${GOOD}" "${WORK}/out-fd"  validate 2>/dev/null )
            serr=$( cd "${REPO}" && bash ./run_pipeline.sh "${GOOD}" "${WORK}/out-fd2" validate 2>&1 >/dev/null )
        fi
        if [[ -z "${serr//[[:space:]]/}" ]]; then
            no "progress messages go to stderr" \
               "stage 0 said nothing at all on stderr. It should report what it checked."
        elif [[ -n "${sout//[[:space:]]/}" ]]; then
            no "progress messages go to stderr" \
               "stdout carried: $(printf '%s' "${sout}" | head -1)
        Channel 1 is for data a later stage will read. Messages go to channel 2:
        \`echo \"...\" >&2\`. A VCF with a log line in it is not a VCF."
        else
            ok "progress messages go to stderr, stdout stays clean"
        fi
    fi
fi

#-- 8 · 5 marks --------------------------------------------------------------
# No sample named in the code.
if want samplesheet; then
    named=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        body=$(uncommented "${f}")
        for id in NA12878 NA12891 NA12892 NA07357 NA12003 NA10851 NA12813 NA12873; do
            [[ "${body}" == *"${id}"* ]] && { named+=( "${f}:${id}" ); break; }
        done
    done < <(shell_files)

    if (( ${#named[@]} == 0 )); then
        ok "no sample is named in the code"
    else
        no "no sample is named in the code" \
           "found: ${named[*]}
        The samplesheet is the only input. Adding a sample or changing a condition
        must need no change to the code."
    fi
fi

#-- 9 · 10 marks, read by a person -------------------------------------------
if want troubleshooting; then
    tfile=""
    for cand in TROUBLESHOOTING.md troubleshooting.md docs/TROUBLESHOOTING.md; do
        [[ -f "${REPO}/${cand}" ]] && { tfile="${cand}"; break; }
    done
    if [[ -z "${tfile}" ]]; then
        no "TROUBLESHOOTING.md is present" \
           "half a page: what broke, how you found it, the fix. It is worth 10 marks and
        it is the part no automated test can grade."
    elif (( $(wc -c < "${REPO}/${tfile}") < 200 )); then
        no "TROUBLESHOOTING.md is present" \
           "${tfile} is under 200 characters. Marks come from reading it, not from its
        existence — say what broke, how you found it, and what the fix was."
    else
        ok "TROUBLESHOOTING.md is present (${tfile})"
        note 'the marks for this one come from reading it, not from this check.'
    fi
fi

#-----------------------------------------------------------------------------
printf '\n  %d passed, %d failed\n' "${pass}" "${fail}"
if (( fail )); then
    printf '\n  failing:\n'
    for f in "${FAILURES[@]}"; do printf '    - %s\n' "${f}"; done
    printf '\n'
    exit 1
fi
printf '\n'
