// Stage 1 · qc_raw — FastQC on the reads as they arrived.
process FASTQC {
    tag "${meta.id}"
    container params.containers.fastqc

    input:
    tuple val(meta), path(reads)

    output:
    path '*_fastqc.zip', emit: zip

    script:
    """
    fastqc --quiet -o . ${reads}
    """
}
