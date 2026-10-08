// Stage 3 · align — BWA-MEM against the full reference, piped straight into a BAM.
process BWA_MEM {
    tag "${meta.id}"
    container params.containers.bwa

    input:
    tuple val(meta), path(reads)
    path ref
    path ref_index
    val  ref_name

    output:
    tuple val(meta), path("${meta.id}.bam"), emit: bam

    script:
    def mates = meta.single_end ? "${reads}" : "${reads[0]} ${reads[1]}"
    def rg    = "@RG\\tID:${meta.id}\\tSM:${meta.id}\\tPL:ILLUMINA"
    """
    bwa mem -t ${task.cpus} -R "${rg}" ${ref_name} ${mates} \\
        | samtools view -b -o ${meta.id}.bam -
    """
}
