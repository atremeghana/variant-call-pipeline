// Stage 6 · merge — joint genotyping across the cohort (GenomicsDBImport + GenotypeGVCFs).
// This is the barrier: its inputs are the collected lists of every sample's GVCF and
// its index, so it starts only after the last stage-5 task has finished.
//
// The GenomicsDB workspace goes on the NODE's own disk (/tmp), not in the task's own
// work/ directory: on Explorer, work/ is under $HOME, a network mount, and the course's
// own week-2 measurement found the GenomicsDBImport + GenotypeGVCFs pair taking 36-96
// minutes there against 8 minutes on node-local disk, for this same eight-sample cohort.
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

    ws=/tmp/genomicsdb_\$\$
    rm -rf "\$ws"

    gatk GenomicsDBImport \\
        --sample-name-map sample_map.tsv \\
        --genomicsdb-workspace-path "\$ws" \\
        --intervals ${region} \\
        --tmp-dir /tmp

    gatk GenotypeGVCFs \\
        -R ${ref_name} \\
        -V gendb://"\$ws" \\
        -O cohort.vcf.gz \\
        -L ${region} \\
        --tmp-dir /tmp

    rm -rf "\$ws"
    """
}
