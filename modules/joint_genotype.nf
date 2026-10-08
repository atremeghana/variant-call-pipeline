// Stage 6 · merge — joint genotyping across the cohort (GenomicsDBImport + GenotypeGVCFs).
// This is the barrier: its inputs are the collected lists of every sample's GVCF and
// its index, so it starts only after the last stage-5 task has finished.
process JOINT_GENOTYPE {
    container params.containers.gatk

    input:
    path gvcfs
    path tbis
    path ref
    path ref_index
    path ref_dict
    val  ref_name
    val  region

    output:
    path 'cohort.vcf.gz',     emit: vcf
    path 'cohort.vcf.gz.tbi', emit: tbi

    script:
    """
    : > sample_map.tsv
    for g in ${gvcfs}; do
        id=\$(basename "\$g" .g.vcf.gz)
        printf '%s\\t%s\\n' "\$id" "\$g" >> sample_map.tsv
    done

    rm -rf genomicsdb
    gatk GenomicsDBImport \\
        --sample-name-map sample_map.tsv \\
        --genomicsdb-workspace-path genomicsdb \\
        --intervals ${region} \\
        --tmp-dir .

    gatk GenotypeGVCFs \\
        -R ${ref_name} \\
        -V gendb://genomicsdb \\
        -O cohort.vcf.gz \\
        -L ${region} \\
        --tmp-dir .
    """
}
