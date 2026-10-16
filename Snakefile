import csv
import os
import re

configfile: "config.yaml"

KNOWN = {"samplesheet", "ref", "region", "outdir", "platform", "executor", "containers"}
unknown = sorted(set(config) - KNOWN)
if unknown:
    raise ValueError(f"unknown config key(s): {', '.join(unknown)}")

PIPELINE = {"name": "variant-call", "version": "1.0.0"}
OUT = config["outdir"]
BIN = os.path.join(workflow.basedir, "bin")       # bin/ is not on the PATH: call scripts by their path
IMAGES = {name: f"docker://{image}" for name, image in config["containers"].items()}

REF = config["ref"]                                                      # the FASTA
REF_FAI = REF + ".fai"
REF_BWA = [REF + ext for ext in (".amb", ".ann", ".bwt", ".pac", ".sa")]  # bwa's index
REF_DICT = os.path.splitext(REF)[0] + ".dict"                            # smoke.dict, not smoke.fa.dict
REGION = config["region"]

SHEET = config["samplesheet"]
with open(SHEET) as fh:
    ROWS = list(csv.DictReader(fh))
SAMPLES = [row["sample_id"] for row in ROWS]
PAIRED = [row["sample_id"] for row in ROWS if row["library_type"] == "paired"]
SINGLE = [row["sample_id"] for row in ROWS if row["library_type"] == "single"]


def resolve(path):
    return path if os.path.isabs(path) else os.path.join(os.path.dirname(SHEET), path)


READS = {
    row["sample_id"]: [resolve(row["r1_fastq"])]
    + ([resolve(row["r2_fastq"])] if row["library_type"] == "paired" else [])
    for row in ROWS
}


def one_of(names):
    """A wildcard pattern matching exactly
    these sample names, or nothing at all."""
    return "|".join(map(re.escape, names)) \
        if names else "(?!)"


rule all:
    input:
        f"{OUT}/cohort.filtered.vcf.gz",
        f"{OUT}/variants.tsv",
        f"{OUT}/multiqc_report.html",
        f"{OUT}/samples.tsv",
        f"{OUT}/manifest.json",


# --- stage 0: validate --------------------------------------------------------
# A rule runs only when a file someone asked for needs its output. This check
# makes a file - a copy of the samplesheet, made only once the checks pass - so
# that every per-sample rule can depend on it and nothing starts before it.
rule validate:
    input:
        sheet=SHEET,
        fastqs=[fq for reads in READS.values() for fq in reads],
        ref=REF,
        ref_index=[REF_FAI] + REF_BWA,
        ref_dict=REF_DICT,
    output:
        "work/validate/samplesheet.csv",
    log:
        "logs/validate.log",
    container: IMAGES["tools"]
    shell:
        "({BIN}/validate_samplesheet_smk.sh {input.sheet} {input.ref} && cp {input.sheet} {output}) 2> {log}"


# --- stage 1: qc_raw -----------------------------------------------------------
rule fastqc:
    input:
        reads=lambda wc: READS[wc.sample],
        checked=rules.validate.output,
    output:
        directory("work/fastqc/{sample}"),
    log:
        "logs/fastqc/{sample}.log",
    container: IMAGES["fastqc"]
    shell:
        "mkdir -p {output} && fastqc --quiet -o {output} {input.reads} 2> {log}"


# --- stage 2: trim ---------------------------------------------------------
# Two rules, one per library type, because a rule's outputs are fixed: a paired
# sample makes two trimmed files, a single-end sample makes one.
rule fastp_paired:
    input:
        reads=lambda wc: READS[wc.sample],
        checked=rules.validate.output,
    output:
        r1="work/trim/{sample}_R1.trim.fastq.gz",
        r2="work/trim/{sample}_R2.trim.fastq.gz",
        json="work/trim/{sample}.fastp.json",
        html="work/trim/{sample}.fastp.html",
    log:
        "logs/trim/{sample}.log",
    container: IMAGES["fastp"]
    wildcard_constraints:
        sample=one_of(PAIRED),
    shell:
        "fastp -i {input.reads[0]} -I {input.reads[1]} "
        "-o {output.r1} -O {output.r2} "
        "--json {output.json} --html {output.html} 2> {log}"


rule fastp_single:
    input:
        reads=lambda wc: READS[wc.sample],
        checked=rules.validate.output,
    output:
        r1="work/trim/{sample}_R1.trim.fastq.gz",
        json="work/trim/{sample}.fastp.json",
        html="work/trim/{sample}.fastp.html",
    log:
        "logs/trim/{sample}.log",
    container: IMAGES["fastp"]
    wildcard_constraints:
        sample=one_of(SINGLE),
    shell:
        "fastp -i {input.reads[0]} "
        "-o {output.r1} "
        "--json {output.json} --html {output.html} 2> {log}"


def trimmed(wildcards):
    s = wildcards.sample
    if s in PAIRED:
        return [f"work/trim/{s}_R1.trim.fastq.gz", f"work/trim/{s}_R2.trim.fastq.gz"]
    return [f"work/trim/{s}_R1.trim.fastq.gz"]


# --- stage 3: align -------------------------------------------------------
rule bwa_mem:
    input:
        reads=trimmed,
        ref=REF,
        ref_index=REF_BWA,
    output:
        bam="work/align/{sample}.bam",
    log:
        "logs/align/{sample}.log",
    container: IMAGES["bwa"]
    threads: 8
    params:
        rg=lambda wc: f"@RG\\tID:{wc.sample}\\tSM:{wc.sample}\\tPL:ILLUMINA",
    shell:
        "(bwa mem -t {threads} -R '{params.rg}' {input.ref} {input.reads} "
        "| samtools view -b -o {output.bam} -) 2> {log}"


# --- stage 4: postprocess --------------------------------------------------
rule markduplicates:
    input:
        bam="work/align/{sample}.bam",
    output:
        bam="work/postprocess/{sample}.dedup.bam",
        bai="work/postprocess/{sample}.dedup.bam.bai",
        metrics="work/postprocess/{sample}.dup_metrics.txt",
    log:
        "logs/postprocess/{sample}.log",
    container: IMAGES["gatk"]
    threads: 8
    shell:
        r"""
        (samtools sort -@ {threads} -o work/postprocess/{wildcards.sample}.sorted.bam {input.bam}
         gatk MarkDuplicates -I work/postprocess/{wildcards.sample}.sorted.bam \
             -O {output.bam} -M {output.metrics}
         samtools index {output.bam}) 2> {log}
        """


# --- stage 5: quantify -----------------------------------------------------
rule haplotypecaller:
    input:
        bam="work/postprocess/{sample}.dedup.bam",
        bai="work/postprocess/{sample}.dedup.bam.bai",
        ref=REF,
        ref_fai=REF_FAI,
        ref_dict=REF_DICT,
    output:
        gvcf="work/gvcf/{sample}.g.vcf.gz",
        tbi="work/gvcf/{sample}.g.vcf.gz.tbi",
    log:
        "logs/quantify/{sample}.log",
    container: IMAGES["gatk"]
    threads: 8
    shell:
        "gatk HaplotypeCaller -R {input.ref} -I {input.bam} -O {output.gvcf} "
        "-ERC GVCF -L {REGION} --native-pair-hmm-threads {threads} 2> {log}"


# --- stage 6: merge --------------------------------------------------------
# The barrier: its input lists every sample's GVCF, so it waits for the last
# haplotypecaller job. The GenomicsDB workspace goes on the node's own /tmp,
# not under work/ (a network mount on Explorer) - week 2's own measurement
# found the GenomicsDBImport + GenotypeGVCFs pair taking 36-96 minutes on
# network storage against 8 minutes on node-local disk, for this same cohort.
rule joint_genotype:
    input:
        gvcfs=expand("work/gvcf/{sample}.g.vcf.gz", sample=SAMPLES),
        tbis=expand("work/gvcf/{sample}.g.vcf.gz.tbi", sample=SAMPLES),
        ref=REF,
        ref_fai=REF_FAI,
        ref_dict=REF_DICT,
    output:
        vcf="work/merge/cohort.vcf.gz",
        tbi="work/merge/cohort.vcf.gz.tbi",
    log:
        "logs/merge.log",
    container: IMAGES["gatk"]
    params:
        variants=lambda wc, input: " ".join(f"-V {g}" for g in input.gvcfs),
    shell:
        r"""
        (ws=/tmp/genomicsdb_$$
         rm -rf "$ws"
         gatk GenomicsDBImport {params.variants} \
             --genomicsdb-workspace-path "$ws" --intervals {REGION} --tmp-dir /tmp
         gatk GenotypeGVCFs -R {input.ref} -V gendb://"$ws" -O {output.vcf} \
             -L {REGION} --tmp-dir /tmp
         rm -rf "$ws") 2> {log}
        """


# --- stage 7: analyze -------------------------------------------------------
rule filter:
    input:
        vcf="work/merge/cohort.vcf.gz",
        tbi="work/merge/cohort.vcf.gz.tbi",
        ref=REF,
        ref_fai=REF_FAI,
        ref_dict=REF_DICT,
    output:
        vcf=f"{OUT}/cohort.filtered.vcf.gz",
        tbi=f"{OUT}/cohort.filtered.vcf.gz.tbi",
        table=f"{OUT}/variants.tsv",
    log:
        "logs/filter.log",
    container: IMAGES["gatk"]
    shell:
        r"""
        (gatk VariantFiltration -R {input.ref} -V {input.vcf} -O {output.vcf} \
            --filter-expression "QD < 2.0"             --filter-name "QD2" \
            --filter-expression "FS > 60.0"             --filter-name "FS60" \
            --filter-expression "MQ < 40.0"             --filter-name "MQ40" \
            --filter-expression "MQRankSum < -12.5"     --filter-name "MQRankSum-12.5" \
            --filter-expression "ReadPosRankSum < -8.0" --filter-name "ReadPosRankSum-8" \
            --filter-expression "SOR > 3.0"             --filter-name "SOR3"
         printf 'chrom\tpos\tref\talt\tqual\tfilter\n' > {output.table}
         bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%QUAL\t%FILTER\n' {output.vcf} >> {output.table}
        ) 2> {log}
        """


# --- stage 8: qc_report ------------------------------------------------------
rule multiqc:
    input:
        expand("work/fastqc/{sample}", sample=SAMPLES),
        expand("work/trim/{sample}.fastp.json", sample=SAMPLES),
    output:
        f"{OUT}/multiqc_report.html",
    log:
        "logs/multiqc.log",
    container: IMAGES["multiqc"]
    shell:
        "multiqc -q -f -o {OUT} {input} 2> {log}"


# --- stage 9: publish ---------------------------------------------------------
PUBLISH_SHEET = rules.validate.output
PUBLISH_RESULTS = [*rules.filter.output, *rules.multiqc.output]

include: "rules/publish.smk"
