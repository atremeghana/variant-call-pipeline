# Troubleshooting Log — Week 5, Snakemake

Four failures caused on purpose, each with the command, what Snakemake printed, and the fix.
Earlier weeks' entries (bash pipeline bugs, Slurm-array failures, container failures,
Nextflow failures) are not repeated here — they stay in this repository's Git history,
under the TROUBLESHOOTING.md of their own commits.

## Failure 1 · Ctrl-C mid-run, then rerun

**Break it:** started the smoke run, let a few jobs finish, pressed Ctrl-C while three
`fastqc` jobs were mid-flight.

```bash
snakemake --profile profiles/laptop \
    --config samplesheet=~/smoke/samplesheet.csv ref=~/smoke/smoke.fa region=smoke_1mb
```

**What Snakemake said at the moment of Ctrl-C:** the three running `fastqc` jobs were
killed with exit status 130 (SIGINT), and the run reported the jobs it knew had
completed before that point (`validate`, both `fastp` rules):

```
[Fri Oct 16 10:46:16 2026]
Finished jobid: 15 (Rule: fastp_single)
3 of 21 steps (14%) done
Terminating processes on user request, this might take some time.
WorkflowError:
At least one job did not complete successfully.
```

**Running the exact same command again, without any extra flag:**
```
IncompleteFilesException:
The files below seem to be incomplete. If you are sure that certain files are not
incomplete, mark them as complete with

    snakemake --cleanup-metadata <filenames>

To re-generate the files rerun your command with the --rerun-incomplete flag.
Incomplete files:
work/fastqc/smoke_01
work/fastqc/smoke_02
work/fastqc/smoke_03
```
Snakemake refuses to trust the three `fastqc` output folders left behind by the killed
jobs, and names the exact option to add: `--rerun-incomplete`.

**How many jobs ran with the flag added:**
```bash
snakemake --profile profiles/laptop --rerun-incomplete \
    --config samplesheet=~/smoke/samplesheet.csv ref=~/smoke/smoke.fa region=smoke_1mb
```
```
Job stats:
job                count
---------------  -------
bwa_mem                3
fastp_paired            1
fastqc                  3
markduplicates          3
multiqc                 1
haplotypecaller         3
joint_genotype          1
filter                  1
publish                 1
all                     1
total                  18
```
18 jobs ran, not 21 — the 3 that had genuinely finished before the interrupt
(`validate`, `fastp_paired smoke_02`, `fastp_single smoke_03`) were correctly left alone,
and only the incomplete `fastqc` jobs reran (`reason: Forced execution`) along with
everything downstream of them.

## Failure 2 · a stage-3 log without {sample}

**Break it:** in the Snakefile, changed `bwa_mem`'s `log:` from `"logs/align/{sample}.log"`
to `"logs/bwa_mem.log"`, dropping the wildcard, and ran a dry run.

```bash
snakemake -n --profile profiles/laptop \
    --config samplesheet=~/smoke/samplesheet.csv ref=~/smoke/smoke.fa region=smoke_1mb
```

**The error:**
```
RuleException in file "Snakefile", line 142:
Not all output, log and benchmark files of rule bwa_mem contain the same wildcards.
This is crucial though, in order to avoid that two or more jobs write to the same file.
```

**Why Snakemake refuses it:** `bwa_mem`'s output, `work/align/{sample}.bam`, still has
the `{sample}` wildcard, but the log no longer does. Three samples — three jobs — would
all try to write to the identical `logs/bwa_mem.log` at once, each one silently
overwriting or corrupting the others' log. Snakemake catches this before any job runs,
rather than letting three concurrent writers collide on one file.

**The fix:** restored `log: "logs/align/{sample}.log"`. Confirmed with `diff` against the
committed Snakefile — no difference.

## Failure 3 · both wildcard_constraints removed from stage 2

**Break it:** deleted the `wildcard_constraints:` block from both `fastp_paired` and
`fastp_single`, and ran a dry run.

```bash
snakemake -n --profile profiles/laptop \
    --config samplesheet=~/smoke/samplesheet.csv ref=~/smoke/smoke.fa region=smoke_1mb
```

**The exception, naming the exact two rules and the exact file:**
```
AmbiguousRuleException:
Rules fastp_single and fastp_paired are ambiguous for the file work/trim/smoke_01_R1.trim.fastq.gz.
Consider starting rule output with a unique prefix, constrain your wildcards, or use the
ruleorder directive.
Wildcards:
        fastp_single: sample=smoke_01
        fastp_paired: sample=smoke_01
Expected output files:
        fastp_single: work/trim/smoke_01_R1.trim.fastq.gz work/trim/smoke_01.fastp.json work/trim/smoke_01.fastp.html
        fastp_paired: work/trim/smoke_01_R1.trim.fastq.gz work/trim/smoke_01_R2.trim.fastq.gz work/trim/smoke_01.fastp.json work/trim/smoke_01.fastp.html
```
Without the constraints, both rules claim they can produce `smoke_01`'s R1 trimmed file
(`fastp_single` ignoring R2 entirely, `fastp_paired` producing both), and Snakemake has no
way to know which one is actually meant for a paired sample versus a single-end one — so
it refuses to guess and stops before building the DAG.

**The fix:** restored both `wildcard_constraints:` blocks (`sample=one_of(PAIRED)` and
`sample=one_of(SINGLE)`). Confirmed with `diff` against the committed Snakefile — no
difference.

## Failure 4 · software-deployment-method: apptainer removed, on Explorer

**Break it:** removed `software-deployment-method: apptainer` from
`profiles/explorer/profile.yaml`, then submitted the head job.

```bash
sbatch slurm/snakemake.sbatch
```

**Which rule failed:** `validate` itself needs no tool beyond plain bash, so it ran fine
without a container. The first real failures were `fastp_paired` (sample NA10851) and
`fastp_single` (samples NA12003 and NA12892) — the first rules whose commands call a tool
(`fastp`) that only exists inside the image:
```
[Fri Oct 16 11:49:44 2026]
Error in rule fastp_single:
    message: SLURM-job '11137706' failed, SLURM status is: 'FAILED'. Reason: Unknown.
    jobid: 15
    shell:
        fastp -i .../NA12892_R1.fastq.gz -o work/trim/NA12892_R1.trim.fastq.gz ...
        (command exited with non-zero exit code)
```

**The exit status, from the job's own Slurm log** (`.snakemake/slurm_logs/rule_fastp_single/NA12892/11137706.log`):
```
RuleException:
CalledProcessError in file "Snakefile", line 131:
Command '...' returned non-zero exit status 127.
```
Confirmed independently with `sacct`:
```
$ sacct -j 11137706 --format=JobID,State,ExitCode
11137706         FAILED      1:0
11137706.0       FAILED      1:0
```

**What the rule's own log says** (`logs/trim/NA12892.log`):
```
/usr/bin/bash: line 1: fastp: command not found
```
`command not found`, exactly — the bare compute node has no `fastp` on its PATH at all;
without Apptainer, Snakemake runs the shell command directly on the node instead of
inside the image, and the tool simply isn't there.

**The fix:** restored `software-deployment-method: apptainer` in
`profiles/explorer/profile.yaml`. Confirmed with `grep` that the line is back, and the
real submitted run (job `11136679`, committed in `cluster-run-smk/`) completed all 46
jobs successfully with it in place. Did not resubmit a dedicated verification run for
this specific restoration, since the real graded cluster run already demonstrates the
working configuration.
