// Stage 0 · validate — the samplesheet, every FASTQ, and the reference's indexes,
// before any compute. Every FASTQ is an input, so Nextflow puts each one in this
// task's folder and the check opens the same files the later stages will.
process VALIDATE {
    container params.containers.tools

    input:
    path samplesheet
    path fastqs
    path ref
    path ref_index
    path ref_dict
    val  ref_name

    output:
    path samplesheet, emit: sheet

    script:
    """
    validate_samplesheet.sh ${samplesheet} ${ref_name}
    """
}
