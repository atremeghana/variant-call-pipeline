#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# write_manifest.sh — the receipt your pipeline writes when it finishes.
#
#   bash write_manifest.sh <results_dir> <samplesheet> <reference> [region]
#
# Put this file in your pipeline's repository at lib/write_manifest.sh, and add
# two lines near the top of run_pipeline.sh, after `set -euo pipefail`:
#
#   HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   export RUN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Then make this the last thing stage 9 does:
#
#   bash "${HERE}/lib/write_manifest.sh" "${RES}" "${SHEET}" "${REF}" "${REGION}"
#
# It writes <results_dir>/manifest.json in the course's manifest format
# (manifest.schema.json): which code ran, when, on which machine, on which
# samples and reference, and every file it published, with a checksum.
#
#   pipeline.git_sha    the commit your code was on; "-dirty" on the end means a
#                       committed file had been edited since; "unknown" means the
#                       code is not in a git repository, or has no commit yet
#   platform            laptop, slurm, or singularity-hpc, worked out from where
#                       it runs; the host, the Slurm job, and the .sif if any
#   samples             read from your samplesheet: sample_id, library_type and
#                       condition
#   outputs             every file under <results_dir>, with its sha256
#   metrics             results/db/qc_metrics.tsv, if your pipeline writes one
#   tools               the version each course tool on PATH reports about itself
#
# Nothing in it needs changing from week to week. The pipeline's name, version
# and implementation have defaults for the assignment; override them with
# PIPELINE_NAME, PIPELINE_VERSION and PIPELINE_IMPLEMENTATION if you need to,
# and set ANNOTATION to record an annotation file as well.
#-----------------------------------------------------------------------------
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'write_manifest.sh: bash >= 4.3 required, found %s\n' "${BASH_VERSION}" >&2; exit 70
fi
[[ $# -ge 3 ]] || { printf 'usage: bash write_manifest.sh <results_dir> <samplesheet> <reference> [region]\n' >&2; exit 64; }

RES=$1 SHEET=$2 REFERENCE=$3 REGION=${4:-}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -d "${RES}" ]]   || { printf 'write_manifest.sh: no results directory: %s\n' "${RES}" >&2; exit 66; }
[[ -s "${SHEET}" ]] || { printf 'write_manifest.sh: no samplesheet: %s\n' "${SHEET}" >&2; exit 66; }

# A JSON string: backslashes and double quotes escaped.
js() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "${s}"; }

# --- when --------------------------------------------------------------------
FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STARTED=${RUN_STARTED:-}
if [[ -z "${STARTED}" ]]; then
    printf 'write_manifest.sh: RUN_STARTED is not set, so started_at is recorded as the finish time.\n' >&2
    printf '                   Add  export RUN_STARTED=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)  to run_pipeline.sh.\n' >&2
    STARTED=${FINISHED}
fi

# --- which code: the repository this script lives in ---------------------------
git_sha() {
    local sha
    sha=$(git -C "${HERE}" rev-parse HEAD 2>/dev/null) || { echo unknown; return; }
    if [[ -n "$(git -C "${HERE}" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        echo "${sha}-dirty"
    else
        echo "${sha}"
    fi
}
SHA=$(git_sha)

# --- where: a container, a Slurm job, or neither ---------------------------------
if [[ -n "${APPTAINER_CONTAINER:-}" ]]; then
    KIND=singularity-hpc; IMPL=singularity
elif [[ -n "${SLURM_JOB_ID:-}" ]]; then
    KIND=slurm; IMPL=slurm
else
    KIND=laptop; IMPL=bash
fi
IMPL=${PIPELINE_IMPLEMENTATION:-${IMPL}}

# --- samples: sample_id, library_type, condition, found by column name -----------
samples_json() {
    awk -F, '
        NR == 1 { for (i = 1; i <= NF; i++) { gsub(/\r/, "", $i); col[$i] = i }
                  if (!("sample_id" in col)) { print "no sample_id column" > "/dev/stderr"; exit 65 }
                  next }
        /^[[:space:]]*$/ { next }
        {   gsub(/\r/, "")
            id   = $col["sample_id"]
            lib  = ("library_type" in col) ? $col["library_type"] : "paired"
            cond = ("condition" in col) ? $col["condition"] : "unknown"
            printf "%s\n    {\"sample_id\": \"%s\", \"library_type\": \"%s\", \"condition\": \"%s\"}", \
                   (n++ ? "," : ""), id, lib, cond }
        END { if (n) printf "\n  " }' "${SHEET}"
}

# --- outputs: every file the run published, with the stage that made it ----------
stage_and_type() {
    case ${1##*/} in
        *.vcf.gz|*.vcf)          echo "analyze vcf" ;;
        *.tbi|*.csi)             echo "analyze vcf_index" ;;
        variants.tsv)            echo "analyze variant_table" ;;
        genotypes.tsv)           echo "analyze genotype_table" ;;
        de_results.tsv)          echo "analyze de_results" ;;
        expression.tsv)          echo "merge counts_matrix" ;;
        qc_metrics.tsv)          echo "qc_report qc_metrics" ;;
        multiqc_report.html)     echo "qc_report multiqc" ;;
        samples.tsv)             echo "publish samples" ;;
        *)                       echo "publish file" ;;
    esac
}
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'; }
outputs_json() {
    local rel st ty sep=''
    while IFS= read -r rel; do
        read -r st ty <<< "$(stage_and_type "${rel}")"
        printf '%s\n    {"stage": "%s", "type": "%s", "path": %s, "checksum": "sha256:%s"}' \
               "${sep}" "${st}" "${ty}" "$(js "${rel}")" "$(sha256_of "${RES}/${rel}")"
        sep=','
    done < <(cd "${RES}" && find . -type f ! -name 'manifest.json*' ! -path './multiqc_data/*' | sed 's|^\./||' | LC_ALL=C sort)
    [[ -n "${sep}" ]] && printf '\n  '
}

# --- metrics: long format, from qc_metrics.tsv if there is one --------------------
metrics_json() {
    local tsv
    for tsv in "${RES}/db/qc_metrics.tsv" "${RES}/qc_metrics.tsv"; do
        [[ -s "${tsv}" ]] || continue
        awk -F'\t' '
            NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
            ("metric" in col) && ("value" in col) && $col["value"] ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/ {
                s = ("sample_id" in col && $col["sample_id"] != "") ? "\"" $col["sample_id"] "\"" : "null"
                u = ("unit" in col) ? $col["unit"] : ""
                g = ("stage" in col) ? $col["stage"] : "qc_report"
                printf "%s\n    {\"sample_id\": %s, \"metric\": \"%s\", \"value\": %s, \"unit\": \"%s\", \"stage\": \"%s\"}", \
                       (n++ ? "," : ""), s, $col["metric"], $col["value"], u, g }
            END { if (n) printf "\n  " }' "${tsv}"
        return
    done
}

# --- tools: what each course tool on PATH says about itself -----------------------
TOOLS=(
    "bwa|bwa 2>&1 | awk '/^Version/ { print \$2 }'"
    "samtools|samtools --version 2>/dev/null | awk 'NR == 1 { print \$2 }'"
    "bcftools|bcftools --version 2>/dev/null | awk 'NR == 1 { print \$2 }'"
    "gatk|gatk --version 2>&1 | awk '/Toolkit/ { sub(/^v/, \"\", \$NF); print \$NF }'"
    "fastqc|fastqc --version 2>/dev/null | awk '{ sub(/^v/, \"\", \$2); print \$2 }'"
    "fastp|fastp --version 2>&1 | awk '{ print \$2 }'"
    "multiqc|multiqc --version 2>/dev/null | awk '{ print \$NF }'"
    "hisat2|hisat2 --version 2>/dev/null | awk 'NR == 1 { for (i = 1; i < NF; i++) if (\$i == \"version\") print \$(i + 1) }'"
    "featureCounts|featureCounts -v 2>&1 | awk '/featureCounts v/ { sub(/^v/, \"\", \$2); print \$2 }'"
)
tools_json() {
    local entry name cmd ver sep=''
    for entry in "${TOOLS[@]}"; do
        name=${entry%%|*}; cmd=${entry#*|}
        command -v "${name}" >/dev/null 2>&1 || continue
        # `|| true`: some tools exit non-zero when asked their version (bwa with no
        # arguments exits 1), and under set -e and pipefail that would end the script.
        ver=$(eval "${cmd}" | head -1) || true
        printf '%s\n    %s: %s' "${sep}" "$(js "${name}")" "$(js "${ver:-unknown}")"
        sep=','
    done
    [[ -n "${sep}" ]] && printf '\n  '
}

# --- write it, then move it into place ---------------------------------------------
OUT="${RES}/manifest.json"
{
    printf '{\n'
    printf '  "pipeline": {\n'
    printf '    "name": %s,\n'           "$(js "${PIPELINE_NAME:-variant-call}")"
    printf '    "version": %s,\n'        "$(js "${PIPELINE_VERSION:-1.0.0}")"
    printf '    "implementation": %s,\n' "$(js "${IMPL}")"
    printf '    "git_sha": %s,\n'        "$(js "${SHA}")"
    printf '    "run_id": %s,\n'         "$(js "${STARTED}-${SHA:0:7}")"
    printf '    "started_at": %s,\n'     "$(js "${STARTED}")"
    printf '    "finished_at": %s,\n'    "$(js "${FINISHED}")"
    printf '    "exit_status": "success"\n'
    printf '  },\n'
    printf '  "platform": {\n'
    printf '    "kind": %s,\n'           "$(js "${KIND}")"
    printf '    "region": %s,\n'         "$(js "${REGION:-none}")"
    printf '    "host": %s,\n'           "$(js "$(hostname)")"
    printf '    "slurm_job_id": %s,\n'   "$(js "${SLURM_JOB_ID:-none}")"
    printf '    "slurm_cpus": %s,\n'     "$(js "${SLURM_CPUS_PER_TASK:-none}")"
    printf '    "container": %s\n'       "$(js "${APPTAINER_CONTAINER:-none}")"
    printf '  },\n'
    printf '  "reference": {"genome": %s' "$(js "${REFERENCE}")"
    [[ -n "${ANNOTATION:-}" ]] && printf ', "annotation": %s' "$(js "${ANNOTATION}")"
    printf '},\n'
    printf '  "samples": [%s],\n'  "$(samples_json)"
    printf '  "outputs": [%s],\n'  "$(outputs_json)"
    printf '  "metrics": [%s],\n'  "$(metrics_json)"
    printf '  "tools": {%s}\n'     "$(tools_json)"
    printf '}\n'
} > "${OUT}.tmp" && mv -- "${OUT}.tmp" "${OUT}"
