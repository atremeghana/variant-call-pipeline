// Stage 5 · quantify — per-sample GVCF calling, restricted to the call region.
// Outputs are plain paths, not [meta, path] tuples: stage 6 collects them as two
// lists of files, and a collect() of [meta, file] items hands a path input the
// maps too, which GATK's sample-name-map build cannot use.
process HAPLOTYPECALLER {
    tag "${meta.id}"
    container params.containers.gatk

    input:
    tuple val(meta), path(bam), path(bai)
    path ref
    path ref_index
    path ref_dict
    val  ref_name
    val  region

    output:
    path "${meta.id}.g.vcf.gz",     emit: gvcf
    path "${meta.id}.g.vcf.gz.tbi", emit: tbi

    script:
    """
    gatk HaplotypeCaller \\
        -R ${ref_name} \\
        -I ${bam} \\
        -O ${meta.id}.g.vcf.gz \\
        -ERC GVCF \\
        -L ${region} \\
        --native-pair-hmm-threads ${task.cpus}
    """
}
