// Stage 2 · trim — adapters and low-quality tails.
// The branch is on meta.single_end, read from the samplesheet, never on the sample's name.
process FASTP {
    tag "${meta.id}"
    container params.containers.fastp

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path('*.trimmed.fastq.gz'), emit: reads
    path "${meta.id}.fastp.json",                 emit: json

    script:
    if (meta.single_end)
        """
        fastp -i ${reads} -o ${meta.id}_R1.trimmed.fastq.gz \\
              --json ${meta.id}.fastp.json --html ${meta.id}.fastp.html
        """
    else
        """
        fastp -i ${reads[0]} -I ${reads[1]} \\
              -o ${meta.id}_R1.trimmed.fastq.gz -O ${meta.id}_R2.trimmed.fastq.gz \\
              --json ${meta.id}.fastp.json --html ${meta.id}.fastp.html
        """
}
