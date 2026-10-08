// Stage 4 · postprocess — sort, mark duplicates, index.
process MARKDUPLICATES {
    tag "${meta.id}"
    container params.containers.gatk

    input:
    tuple val(meta), path(bam)

    output:
    tuple val(meta), path("${meta.id}.dedup.bam"), path("${meta.id}.dedup.bam.bai"), emit: bam

    script:
    """
    samtools sort -@ ${task.cpus} -o ${meta.id}.sorted.bam ${bam}
    gatk MarkDuplicates -I ${meta.id}.sorted.bam -O ${meta.id}.dedup.bam -M ${meta.id}.dup_metrics.txt
    samtools index ${meta.id}.dedup.bam
    """
}
