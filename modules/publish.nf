// Stage 9 · publish — say what produced these results.
// The task runs in an image, on a machine that is not where the run was launched,
// so everything run_manifest.sh records about the run is handed to it here, from Nextflow.
// Course-provided, and the same file for every pipeline: nothing here names a parameter.
process PUBLISH {
    container params.containers.tools
    cache false         // -resume would reuse last run's manifest; a receipt is written fresh every run

    input:
    path samplesheet
    path results        // the files this manifest describes; also makes PUBLISH wait for them

    output:
    path 'manifest.json', emit: manifest
    path 'samples.tsv',   emit: samples

    script:
    def images = params.containers.collect { name, image -> "${name}=${image}" }.join(' ')
    def given  = params.findAll { _name, value -> !(value instanceof Map) }       // all but the image table
                       .collect { name, value -> "${name}=${value}" }.join(' ')
    """
    printf 'sample_id\\tcondition\\n' > samples.tsv
    awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) col[\$i] = i; next }
             { print \$col["sample_id"] "\\t" \$col["condition"] }' ${samplesheet} >> samples.tsv

    # The inputs are links; the manifest checksums real copies of what this run published.
    mkdir published
    cp -L ${results} samples.tsv published/

    NAME='${workflow.manifest.name}' VERSION='${workflow.manifest.version}' \\
    REVISION='${workflow.revision ?: 'none'}' COMMIT='${workflow.commitId ?: 'none'}' \\
    RUN_NAME='${workflow.runName}' STARTED_AT='${workflow.start}' LAUNCH_DIR='${workflow.launchDir}' \\
    ENGINE='nextflow ${nextflow.version}' PLATFORM='${params.platform}' EXECUTOR='${task.executor}' \\
    PARAMS='${given}' CONTAINERS='${images}' \\
        run_manifest.sh published ${samplesheet} > manifest.json
    """
}
