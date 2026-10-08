// Stage 7 · analyze — hard-filter the cohort VCF, and write variants.tsv from its records.
process FILTER {
    container params.containers.gatk

    input:
    path vcf
    path tbi
    path ref
    path ref_index
    path ref_dict
    val  ref_name

    output:
    path 'cohort.filtered.vcf.gz',     emit: vcf
    path 'cohort.filtered.vcf.gz.tbi', emit: tbi
    path 'variants.tsv',               emit: table

    script:
    """
    gatk VariantFiltration \\
        -R ${ref_name} \\
        -V ${vcf} \\
        -O cohort.filtered.vcf.gz \\
        --filter-expression "QD < 2.0"             --filter-name "QD2" \\
        --filter-expression "FS > 60.0"             --filter-name "FS60" \\
        --filter-expression "MQ < 40.0"             --filter-name "MQ40" \\
        --filter-expression "MQRankSum < -12.5"     --filter-name "MQRankSum-12.5" \\
        --filter-expression "ReadPosRankSum < -8.0" --filter-name "ReadPosRankSum-8" \\
        --filter-expression "SOR > 3.0"             --filter-name "SOR3"

    printf 'chrom\\tpos\\tref\\talt\\tqual\\tfilter\\n' > variants.tsv
    bcftools query -f '%CHROM\\t%POS\\t%REF\\t%ALT\\t%QUAL\\t%FILTER\\n' cohort.filtered.vcf.gz >> variants.tsv
    """
}
