#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_manifest.sh — the receipt a run writes when it finishes.
#
#   run_manifest.sh <published_dir> <samplesheet>  > manifest.json
#
# It runs as the publish rule, possibly in an image, which has no git. So the
# facts about the run arrive from the workflow engine as environment variables,
# which the Snakefile's publish rule sets:
#
#   NAME, VERSION    the pipeline's name and version, from the manifest block of nextflow.config
#   REVISION, COMMIT the branch or tag and the commit, when whoever launched the run gave
#                    them; "none" otherwise
#   RUN_NAME         a name for this run
#   STARTED_AT       when the run started
#   LAUNCH_DIR       the folder the run was launched in; relative paths in PARAMS start here
#   ENGINE           the workflow engine and its version, e.g. "snakemake 9.27.0"; its first
#                    word is the manifest's "implementation"
#   PLATFORM         where the tasks ran: docker-local, singularity-hpc, ...
#   EXECUTOR         what submitted them: local, slurm, ...
#   PARAMS           every parameter the run was given, "name=value name=value ..."
#   CONTAINERS       every image the run used, "name=image name=image ...", or empty when
#                    the rules ran with the tools installed on the machine
#
# The outputs are every file in <published_dir>, each with its sha256.
#-----------------------------------------------------------------------------
set -euo pipefail
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'run_manifest.sh: bash >= 4.3 required, found %s\n' "${BASH_VERSION}" >&2; exit 70
fi
PUB=${1:?usage: run_manifest.sh <published_dir> <samplesheet>}
SHEET=${2:?usage: run_manifest.sh <published_dir> <samplesheet>}
: "${NAME:?} ${VERSION:?} ${REVISION:?} ${COMMIT:?} ${RUN_NAME:?} ${STARTED_AT:?} ${LAUNCH_DIR:?} ${ENGINE:?} ${PLATFORM:?} ${EXECUTOR:?} ${PARAMS:?} ${CONTAINERS?}"

js() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

samples_json() {
    awk -F, '
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        { printf "%s\n    {\"sample_id\": \"%s\", \"library_type\": \"%s\", \"condition\": \"%s\"}",
                 (n++ ? "," : ""), $col["sample_id"], $col["library_type"], $col["condition"] }
        END { if (n) printf "\n  " }' "$SHEET"
}

# sha256sum is GNU's; a Mac before macOS 15 has only shasum. Week 5 runs this on the laptop with no
# image around it, so both are allowed, as week 1's write_manifest.sh does.
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'; }

outputs_json() {
    local f sep=''
    while IFS= read -r f; do
        printf '%s\n    {"path": %s, "checksum": "sha256:%s"}' "$sep" "$(js "$f")" "$(sha256_of "$PUB/$f")"
        sep=','
    done < <(cd "$PUB" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
    [[ -z "$sep" ]] || printf '\n  '
}

pairs_json() {         # pairs_json <indent> "name=value name=value ..." -> the members of a JSON object
    local pad=$1 pair sep=''
    for pair in $2; do
        printf '%s\n%s  %s: %s' "$sep" "$pad" "$(js "${pair%%=*}")" "$(js "${pair#*=}")"
        sep=','
    done
    [[ -z "$sep" ]] || printf '\n%s' "$pad"
}

printf '{\n'
printf '  "pipeline": {\n'
printf '    "name": %s,\n'         "$(js "$NAME")"
printf '    "version": %s,\n'      "$(js "$VERSION")"
printf '    "implementation": %s,\n' "$(js "${ENGINE%% *}")"
printf '    "revision": %s,\n'     "$(js "$REVISION")"
printf '    "git_sha": %s,\n'      "$(js "$COMMIT")"
printf '    "run_id": %s,\n'       "$(js "$RUN_NAME")"
printf '    "started_at": %s,\n'   "$(js "$STARTED_AT")"
printf '    "launch_dir": %s,\n'   "$(js "$LAUNCH_DIR")"
printf '    "finished_at": %s,\n'  "$(js "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
printf '    "exit_status": "success"\n'
printf '  },\n'
printf '  "params": {%s},\n'     "$(pairs_json '  ' "$PARAMS")"
printf '  "platform": {\n'
printf '    "kind": %s,\n'         "$(js "$PLATFORM")"
printf '    "executor": %s,\n'     "$(js "$EXECUTOR")"
printf '    "engine": %s,\n'       "$(js "$ENGINE")"
printf '    "containers": {%s}\n'  "$(pairs_json '    ' "$CONTAINERS")"
printf '  },\n'
printf '  "samples": [%s],\n'      "$(samples_json)"
printf '  "outputs": [%s]\n'       "$(outputs_json)"
printf '}\n'
