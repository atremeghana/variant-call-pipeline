# Troubleshooting Log — Week 4, Nextflow

Four failures caused on purpose, each with the command, what it printed, and the fix.
Earlier weeks' entries (Assignment 1's development bugs, Assignment 2's Slurm-array
failures, Assignment 3's container failures) are not repeated here — they stay in this
repository's Git history, under the TROUBLESHOOTING.md of their own commits.

## Failure 1 · Ctrl-C mid-run, then -resume

**Break it:** started the smoke run, let it get partway through, pressed Ctrl-C.

```bash
nextflow run main.nf -profile docker \
    --samplesheet smoke/samplesheet.csv --ref smoke/smoke.fa --region smoke_1mb
```

**State at the moment of Ctrl-C:**
```
executor >  local (9)
[92/34b44d] VALIDATE           | 1 of 1 ✔
[13/92416e] FASTQC (smoke_01)  | 2 of 3
[12/a62dc6] FASTP (smoke_02)   | 3 of 3 ✔
[a0/0df889] BWA_MEM (smoke_03) | 0 of 3
WARN: Killing running tasks (3)
```
VALIDATE and FASTP were fully done; FASTQC had 2 of 3 samples done; BWA_MEM had not
actually started any sample yet.

**Resubmitted with -resume:**
```bash
nextflow run main.nf -profile docker \
    --samplesheet smoke/samplesheet.csv --ref smoke/smoke.fa --region smoke_1mb -resume
```

**What was cached and what ran again:**
```
[92/34b44d] VALIDATE                   | 1 of 1, cached: 1 ✔
[52/754a79] FASTQC (smoke_01)          | 3 of 3, cached: 2 ✔
[12/a62dc6] FASTP (smoke_02)           | 3 of 3, cached: 3 ✔
...
Succeeded   : 14
Cached      : 6
```
Exactly the 6 tasks that had genuinely finished before the interrupt — VALIDATE (1) + FASTP
(3) + FASTQC (2) — were reused without rerunning. The one FASTQC sample that was mid-flight
when Ctrl-C landed, and everything downstream (BWA_MEM onward, which had not started a
single sample), ran fresh. Nextflow's cache keys on a task having actually completed, not on
whether it had started — a half-finished task leaves no cache entry to reuse.

## Failure 2 · the reference as a queue channel in BWA_MEM

**Break it:** in `main.nf`, changed BWA_MEM's call from the value channel `ref` to a queue
channel built fresh each time:

```
BWA_MEM(FASTP.out.reads, channel.fromPath(params.ref), ref_index, ref_name)
```

then ran the smoke dataset (3 samples) normally.

**What happened — no error anywhere, and the run reported success:**
```
[44/a02be3] BWA_MEM (smoke_03)         | 1 of 1 ✔
...
Succeeded   : 14
```
**How many samples BWA_MEM actually ran: one**, not three. The final VCF confirms it:
```
$ zcat results/cohort.filtered.vcf.gz | grep "^#CHROM"
#CHROM  POS  ID  REF  ALT  QUAL  FILTER  INFO  FORMAT  smoke_03
```
smoke_01 and smoke_02 are simply absent — no error, no warning, a complete and plausible
cohort VCF with one sample instead of three.

**Why:** `channel.fromPath(params.ref)` makes the reference a *queue* channel — a stream with
exactly one item, consumed once. Nextflow pairs queue-channel inputs positionally, so the
first sample to arrive consumes the reference, and every sample after it has nothing left to
pair with and is silently dropped from that process. A value channel (`file()`), as the real
pipeline uses, is re-offered to every task instead of being consumed.

**The fix:** restored `ref` (the value channel built with `file(params.ref)`) in the BWA_MEM
call. Confirmed the real `main.nf` uses `BWA_MEM(FASTP.out.reads, ref, ref_index, ref_name)`.

## Failure 3 · the backslash removed from one \$(...)

**Break it:** in `modules/joint_genotype.nf`, removed the backslash from one `\$(basename ...)`
call, leaving the rest of the file untouched:
```
id=$(basename "\$g" .g.vcf.gz)       # was: id=\$(basename "\$g" .g.vcf.gz)
```
then ran the smoke dataset.

**What happened — the error is at the right line, but the cause is not what it looks like:**
```
Command error:
  .command.sh: line 4: syntax error near unexpected token `)'
```
Reading `.command.sh` directly shows why, and it is far stranger than a single broken line:
```bash
for g in smoke_03.g.vcf.gz smoke_02.g.vcf.gz smoke_01.g.vcf.gz; do
    id=smoke_1mbbasename "$g" .g.vcf.gz)
    printf '%s\t%s\n' "$id" "$g" >> sample_map.tsv
done
...
gatk GenomicsDBImport \
    --sample-name-map sample_map.tsv \
    --genomicsdb-workspace-path genomicsdb \
    --intervals smoke.fa \
    --tmp-dir .

gatk GenotypeGVCFs \
    -R smoke_1mb \
    -V gendb://genomicsdb \
    -O cohort.vcf.gz \
    -L  \
    --tmp-dir .
```
Removing the backslash made Nextflow interpolate `$(` itself at that point, as if it were a
Groovy expression — so `id=$(basename...` was consumed as part of Nextflow's own string
processing, and every `${ref_name}` and `${region}` substitution *after* that point in the
file shifted by one position: `--intervals` received the reference's filename (`smoke.fa`)
instead of the region, `-R` received the region (`smoke_1mb`) instead of the reference, and
`-L` received nothing at all. Bash's syntax error is almost a lucky break here — a shorter or
differently-shaped script could easily have taken these scrambled values and run anyway,
producing a silently wrong cohort VCF rather than a loud crash. This matches the assignment's
own warning that this failure "behaves differently with other dollar signs": a bash variable
such as `\$n` stops Nextflow immediately with `n is not defined`, which is the far safer
failure to have.

**The fix:** restored the backslash. Confirmed `modules/joint_genotype.nf` now matches the
version committed with the rest of the pipeline, with `diff` showing no difference.

## Failure 4 · too-short time limit on HaplotypeCaller, on the first Explorer run

**Break it:** before the first real Explorer submission, set `time = '2m'` for
`HAPLOTYPECALLER` in the explorer profile of `nextflow.config`, then submitted.

**What Nextflow reported** (job `10927661`, head log):
```
ERROR ~ Error executing process > 'HAPLOTYPECALLER (NA12878)'
Caused by:
  Process `HAPLOTYPECALLER (NA12878)` terminated with an error exit status (140)
```
GATK's own log shows it was genuinely mid-traversal when killed, 0.8 minutes in — real work
in progress, not stuck:
```
21:10:26.209 INFO  ProgressMeter -  chr20:1553517  0.8  7900  9454.5
```

**What sacct actually recorded — not TIMEOUT, as the naive guess would be, but FAILED**,
because Nextflow's own signal handling intercepts Slurm's 30-second warning before the hard
kill lands:
```
$ sacct --starttime today --format=JobID,JobName,State,ExitCode,Elapsed,Timelimit | grep -i HAPLO
10927831     nf-HAPLOT+     FAILED     12:0   00:01:24   00:02:00
10927842     nf-HAPLOT+     FAILED     12:0   00:01:13   00:02:00
10927844     nf-HAPLOT+     FAILED     12:0   00:01:06   00:02:00
10927845     nf-HAPLOT+     FAILED     12:0   00:01:02   00:02:00
```
Four of the eight samples' HaplotypeCaller tasks shown here, all `FAILED` with `ExitCode=12:0`,
all killed between 1:02 and 1:24 elapsed — under the 2-minute limit.

**The fix:** restored `time = '1h'` for HAPLOTYPECALLER and resubmitted with `-resume`.
Because `-resume` compares task scripts and inputs, not resource requests, it did not skip
HaplotypeCaller just because the earlier attempt had "already tried" it — every sample's
HaplotypeCaller genuinely reran and completed under the restored limit, and the run proceeded
normally through JOINT_GENOTYPE, FILTER, MULTIQC and PUBLISH.
