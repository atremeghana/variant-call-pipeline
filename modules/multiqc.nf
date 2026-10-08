// Stage 8 · qc_report — one report across the cohort.
process MULTIQC {
    container params.containers.multiqc

    input:
    path qc_files

    output:
    path 'multiqc_report.html'

    script:
    """
    multiqc -q .
    """
}
