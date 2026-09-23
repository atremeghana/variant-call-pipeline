# Assignment 1 — A germline variant-calling pipeline in Bash

**Due:** Wednesday 30 September, 23:59 · **Worth:** 6 % of the course grade

Build a ten-stage variant-calling pipeline in Bash. It is the same architecture as the RNA-seq
pipeline built in class, applied to a different biological question — so the structure transfers and
none of the code does.

**It has to run end to end on your own laptop.** This week you run all ten stages on a small smoke
dataset and hand in what the run produced. Next week the same code runs on the real cohort on
Explorer.

You get the acceptance tests that grade it. Run them before you submit.

---

## What you are building

Eight human genomes in, one filtered cohort VCF out.

| Stage | What it does | Tool |
|---|---|---|
| 0 `validate` | check the samplesheet and every input file **before any compute** | bash |
| 1 `qc_raw` | QC metrics from the raw FASTQ | FastQC |
| 2 `trim` | adapter and quality trimming | fastp |
| 3 `align` | align to the reference | BWA-MEM |
| 4 `postprocess` | sort, index, **mark duplicates** | samtools, GATK |
| 5 `quantify` | per-sample variant calling into a GVCF | GATK HaplotypeCaller `-ERC GVCF` |
| 6 `merge` | **joint genotyping** across every sample | GATK GenomicsDBImport + GenotypeGVCFs |
| 7 `analyze` | hard-filter | GATK VariantFiltration |
| 8 `qc_report` | one report across the cohort | MultiQC |
| 9 `publish` | tidy TSVs + `manifest.json` | bash |

Stages 0, 1, 2, 8 and 9 are structurally identical to the demo. Stages 3–7 are not. That split is
the point of the assignment: **architecture transfers between problems, code does not.**

---

## Two ways to run a pipeline before it meets the real data

### The normal way: a slice of the real reads, against the whole reference

In practice you develop against a small slice of the real reads — a few thousand per sample — and
align it to the complete reference. The slice keeps each run short. The reference stays whole
because an aligner can only report that a read is unique among the sequences you gave it. Align to a
subset, and reads whose true home is on a missing chromosome pile up on the ones you kept — with high
mapping quality, because within that subset they really are unique. Measured: a subset reference
produced 106 confident alignments in a region where the sample had no such sequence. So you restrict
the *calling region* with `-L`, and leave the reference alone.

The cost is the reference itself. The whole GRCh38 and its BWA index are about 9 GB to download,
and `bwa mem` needs about 6 GB of free memory to load the index — more than a laptop with 8 GB of
memory has to spare.

### The smoke test: a tiny reference, and reads simulated from it

A smoke dataset is a complete miniature input: a small reference, reads made from that reference, and
a record of what the reads contain. The one for this assignment is 1,000,000 bases of real GRCh38,
renamed `smoke_1mb` so that nothing computed from it can be mistaken for a result about a
chromosome, and three samples simulated from it with `wgsim`, which planted SNVs and small indels in
each and wrote down where.

The small reference is safe here for a specific reason: every read was simulated from those
1,000,000 bases, so no read has a true home outside the reference, and the misplacement described
above cannot happen. What you get is all ten stages in about a minute and a half on a laptop with
8 GB of memory, and an answer to check your VCF against. What you do not get is anything about real
data: the reads are simulated and the reference is not a chromosome.

### This assignment uses both, in that order

| | This week, on your laptop | Next week, on Explorer |
|---|---|---|
| Reads | the smoke dataset: 3 samples, simulated | the cohort: 8 samples, `chr20:1–10 Mb` at about 37× |
| Reference | `smoke.fa`, 1 Mb, inside the smoke dataset | the whole GRCh38, already on Explorer |
| Calling region | `smoke_1mb` | `chr20:1-10000000` |
| What it tells you | the code runs end to end and finds the planted variants | the real answer |

Only the reference and the calling region change between the two runs. Put `REF` and `REGION` in
`conf/pipeline.env`, never in a stage script, and switching runs is a two-line edit.

### The smoke dataset: this week

<!-- FILE:w01-smoke-dataset.zip -->

It unpacks to `smoke/`, 30 MB, with its own `README.txt`:

| | |
|---|---|
| `samplesheet.csv` | six columns: `smoke_01` and `smoke_02` paired-end, `smoke_03` single-end |
| `smoke.fa`, `.fai`, `.dict` and the BWA index | the reference, already indexed |
| `smoke_0N_R1.fastq.gz` (and `_R2`) | the reads |
| `smoke_0N.truth.txt` | the variants planted in each sample |

Run your pipeline from inside `smoke/`, because the FASTQ paths in its samplesheet are relative to
that folder, with the reference and the region set to the smoke values:

```bash
cd smoke
REF=$PWD/smoke.fa REGION=smoke_1mb bash ~/your-repo/run_pipeline.sh samplesheet.csv ~/smoke-out
```

If your pipeline takes `REF` and `REGION` from `conf/pipeline.env` rather than from the environment,
set them there instead. The sample names in your VCF must be the `sample_id` values — set `SM` in the
read group you give `bwa mem` — because that is how each column is matched to its answer.

When all ten stages have finished, copy two files from the run into your repository and commit them:

```bash
mkdir -p ~/your-repo/smoke-run
cp ~/smoke-out/<your stage-7 VCF>       ~/your-repo/smoke-run/cohort.filtered.vcf.gz
cp ~/smoke-out/<your stage-9 manifest>  ~/your-repo/smoke-run/manifest.json
```

A complete pipeline runs all ten stages on this data in about a minute and a half on a laptop with
8 GB of memory, and finds between 92 % and 100 % of each sample's planted SNVs — the single-end
sample, at about 9× depth, is the low one. The acceptance test asks for 80 % of each sample's.

### The real run: next week, on Explorer

The reference is the 1000 Genomes GRCh38 analysis set, `GRCh38_full_analysis_set_plus_decoy_hla.fa`,
the reference the 1000 Genomes Project aligned these eight samples to. Its chromosome names carry the
`chr` prefix (`chr20`), which is what `-L chr20:1-10000000` expects. It is ready on Explorer, with its
`.fai`, `.dict` and BWA index beside it. Point your configuration at this path; do not copy it:

```
/courses/BINF6610.202710/data/refs/grch38-1000g/GRCh38_full_analysis_set_plus_decoy_hla.fa
```

**Optional, not graded: the normal way on your own laptop.** If your laptop has 16 GB of memory or
more, you can download the same reference — about 9 GB — and develop against a slice of real reads:

```bash
mkdir -p ~/refs/grch38-1000g && cd ~/refs/grch38-1000g
BASE=https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome
for ext in fa fa.fai dict fa.amb fa.ann fa.bwt fa.pac fa.sa; do
    curl -fLO -C - "${BASE}/GRCh38_full_analysis_set_plus_decoy_hla.${ext}"
done
```

`-C -` resumes an interrupted download, so if the loop stops, run it again. For the slice you do not
need the whole run: ENA serves each FASTQ gzipped over HTTP, so you can read the front of the stream
and stop.

```bash
mkdir -p dev
URL=ftp.sra.ebi.ac.uk/vol1/fastq/ERR166/081/ERR16657781/ERR16657781_1.fastq.gz
curl -s "https://${URL}" | gzip -dc | head -16000 | gzip > dev/NA12878_R1.fastq.gz
```

`head` stops after 16,000 lines — 4,000 records — and closing the pipe stops the download: about
640 KB and three seconds for both mates, out of a 19.3 GB file. Do the same with `_2.fastq.gz`; the
two files are in the same order. Every sample's FASTQ links are listed by ENA's file report — replace
the accession with the `run` column of the cohort table:

```
https://www.ebi.ac.uk/ena/portal/api/filereport?accession=ERR3989341&result=read_run&fields=fastq_ftp
```

The first reads of a FASTQ come from the edge of the flowcell and are not a random sample of the
library, so a slice like this is for testing code, not for measuring anything.

---

## The data

Eight samples from the 1000 Genomes Project. The full table — accessions, read lengths, layout,
sex and the pedigree — is here, and the accessions were checked against live ENA:

<!-- FILE:variant-call-cohort.tsv -->

You build your `samplesheet.csv` from it. `library_type` is what your pipeline branches on.

**The cohort's reads are already on Explorer.** They are at

```
/courses/BINF6610.202710/data/fastq-variant/
```

— eight samples, 1.3 GB in total, extracted by region from the 1000 Genomes aligned CRAMs so that
they cover `chr20:1–10,000,000` at about 37×. That is the copy you run the pipeline against **next
week, on the cluster**, and it is the reason you never have to move sequencing data anywhere.

**This week, on your laptop, you do not use them**: you run the smoke dataset above. The `run` column
is each sample's ENA accession.

| | |
|---|---|
| Samples | 8 — `NA12878`, `NA12891`, `NA12892`, `NA07357`, `NA12003`, `NA10851`, `NA12813`, `NA12873` |
| Sex | 4 female, 4 male |
| Libraries | 6 paired-end, 2 single-end |
| Read length | 150–151 bp |

> **The `phenotype` column is synthetic and every row says so.** `is_synthetic_phenotype` is `true`
> for all eight. These are healthy reference genomes; nobody in this cohort is affected by anything.
> The column exists so the pipeline has a two-level factor to group by, which is what stages 6 and 7
> need. Never present a synthetic label as a finding, and never build a pipeline that lets one pass
> unmarked.

**`NA12878` must stay in your cohort.** It is the Genome in a Bottle benchmark sample, which means
there is a published truth set for it — so your variant calls can be scored for precision and
recall rather than merely inspected. Later modules use that.

### Two samples are single-end

`NA12892` and `NA12003` have an empty `r2_fastq`. That empty field is the authoritative signal, and
your pipeline must branch on the samplesheet rather than on the sample's name. A pipeline that says
`if [[ $sample == NA12892 ]]` fails the acceptance test that swaps which samples are single-end.

---

## What to submit

```
your-repo/
├── run_pipeline.sh          # the driver
├── lib/                     # your libraries
├── stages/                  # one script per stage
├── conf/pipeline.env        # configuration, no secrets
├── samplesheet.csv          # the eight samples
├── TROUBLESHOOTING.md       # see below
├── smoke-run/               # COMMIT THESE TWO — from your full run on the smoke dataset
│   ├── cohort.filtered.vcf.gz     your stage-7 VCF
│   └── manifest.json              your stage-9 manifest
└── results/                 # DO NOT COMMIT — .gitignore it
```

> **That is the layout you hand in, not the one you start with.** Week 1's demo is a single
> file and so is the first thing you should write — one script, one function per stage, run
> in order. Splitting it into `lib/` and `stages/` is week 2's work, and week 2 gives you the
> reason: a Slurm job array runs *stages 0–5 for one sample*, which needs a per-sample entry
> point, and eight copies running at once need the logging and the sheet reading to live in
> one place.
>
> Split it before you have that reason and you get a broken script and no lesson.

**`run_pipeline.sh` may take its arguments either way, and both are accepted.** The demo takes
three positional arguments and one slide in the lecture writes the same thing as flags:

```bash
./run_pipeline.sh samplesheet.csv out validate                        # positional, like the demo
./run_pipeline.sh --samplesheet samplesheet.csv --outdir out --to validate   # flags
```

Pick one and be consistent. The acceptance harness reads your driver once, calls it the way you
wrote it, and prints which form it detected in its first two lines. The third argument is the
**last stage to run** — being able to stop after `validate` is what gives you a one-second
edit-run loop, and most of the tests depend on it.

Submit a link to a Git repository. Do not commit FASTQ files, BAMs or the reference. The only VCF you
commit is the smoke run's, in `smoke-run/`.

### Set the repository up first — before your first run

This repository is where the whole course lives: every week adds to it, and week 8 automates it.
Create it now, on GitHub, and **make one commit before you run the pipeline for the first time**:

```bash
git init
git add .
git commit -m "week 1: pipeline skeleton"
```

The reason is one line in `results/manifest.json`. Your pipeline records `git_sha` — the commit
your code was on when it ran — and that is why this assignment asks for a repository link instead
of a zip file. A zip says what you produced; the sha says which code produced it.

Run before you commit and the field reads `unknown`. That is honest, and useless.

There is a third value, and it is the one worth knowing about now. If you commit, then edit a
script, then run without committing again, the manifest records **`<sha>-dirty`**. It is telling
you that the sha no longer describes the code that ran — somebody checking out that commit would
get something different from what you executed. Seeing `-dirty` in your own manifest is not an
error to fix; it is the pipeline being straight with you about what it can and cannot vouch for.

---

## How it is graded

**90 points — nine acceptance tests.** In `tests/`. You run them; they are the same file used to
grade. **Every one of them checks something week 1 taught**, and when one fails it says what to go
back to.

| Pts | Test | Full marks | Partial |
|---:|---|---|---|
| 20 | the whole pipeline ran on the smoke dataset | `smoke-run/` holds your VCF, with a column for each of the three samples and at least 80 % of each sample's planted SNVs, and the manifest from the same run | **10** — the VCF is there, but a sample is missing or below 80 %, or the manifest is missing |
| 20 | stage 0 reports every problem together | four samples, three of them broken, non-zero exit, all three named | **10** — it fails, but names only the first problem it met |
| 10 | survives a sample named `Donor 3-rep1` | the name is carried through intact | — |
| 10 | catches a truncated `.fastq.gz` | fails in stage 0 **and** names the sample | **5** — caught, but the message never says which sample |
| 10 | rejects a duplicate `sample_id` | non-zero exit **and** the message names it | **5** — rejected, but never names the duplicate |
| 5 | single-end read from `library_type` | branches on the column, not on the sample's name | — |
| 5 | `set -euo pipefail` in every script | all three flags, in every `.sh` you ship — the files you `source` included | — |
| 5 | progress messages go to stderr | stage 0 reports on stderr and leaves stdout empty | — |
| 5 | no sample is named in the code | none of the eight ids appears outside a comment | — |

The partial bands are transcriptions of what the harness printed, not estimates of how nearly
something worked. The rows without one are worth 5 points, or the harness cannot tell two failures
apart there, and an invented middle rating would turn a measurement into an argument.

Run them:

```bash
bash tests/run_acceptance.sh /path/to/your-repo
```

Eight of them need no sequencing data: they run in seconds against fixtures the harness builds
itself, so there is no excuse for finding out at submission time. The smoke test reads `smoke-run/`
in your repository, so it passes once you have copied your smoke run's two files there. The other
eight invoke your driver as

```bash
./run_pipeline.sh <samplesheet.csv> <outdir> validate
```

three positional arguments, the same as the demo. **If you wrote a `--samplesheet/--outdir/--to`
driver instead, that works too** — the harness reads your driver once and calls it the way you wrote
it, and prints which form it detected. Either way it hands you the six-column samplesheet the demo
reads.

**10 points — `TROUBLESHOOTING.md`.** Half a page. What broke, how you found it, what the fix was.

| Pts | |
|---:|---|
| 10 | **Specific and diagnostic** — symptom, the evidence that located the cause, the cause, the fix |
| 8 | **Specific, thin on method** — what broke and what fixed it, but not how you found it |
| 5 | **General** — "I had problems with paths and fixed them" |
| 2 | **Present only** — a sentence or two, or a list of commands |
| 0 | **Absent** |

Specific, not general. Not *"I had a path bug and fixed it."* More like: *"stage 3 produced an empty
BAM for NA12003; the log showed bwa exited 0; I found the pipeline was missing `pipefail`, so
samtools masked bwa's failure; added it, and the run failed properly."*

The tests check that your pipeline works. The log shows you know why it works. They are not the same
thing, and only one of them survives contact with the next problem.

The same criteria are the Canvas rubric on this page, so what you see below the description is what
you are marked against — nothing is hidden and nothing is held back.

---

## Getting started

1. **Read the demo pipeline first.** It is on Canvas: one file, about 290 lines, ten functions
   run in order. Everything you need structurally is in there.
2. **Copy the architecture, not the code.** The samplesheet as the only input, stage 0
   collecting every problem before anything computes, a check after every tool, messages on
   stderr — all of that transfers. None of the tool calls do.
3. **Download the smoke dataset, and put `REF` and `REGION` in `conf/pipeline.env`** with the smoke
   values. Every run you do this week is against that folder.
4. **Build stage 0 first, and run it constantly.** Six of the nine tests run through stage 0, and
   three of those six are gated on it: they check how a sample is *handled*, so the harness first
   confirms your driver reads the samplesheet at all before it will award them. It is also the stage
   that saves you the most time while you develop.
5. **Then one stage at a time, on one smoke sample**, before you run all three.
6. **Run all ten stages on the smoke dataset, copy the two files into `smoke-run/`, and commit.**
   Check your VCF against `smoke_0N.truth.txt` yourself before the test does.

### How long this should take to run

**Seconds for the edit-run loop.** Stage 0 on the smoke samplesheet takes a second, and the
acceptance tests run in about ten.

**About a minute and a half for a full smoke run**, all ten stages, on a laptop with 8 GB of memory.

**The full cohort is next week's run, on Explorer.** Measured there on one sample of the prepared
read set: 97 seconds for BWA-MEM on 8 cores, 6.3 GB of memory, a 104 MB BAM. Eight of those as a
job array is minutes, not hours.

What this means for how you work: **do not wait until you have real output to find out whether your
pipeline is correct.** You can run all nine tests yourself before you submit — eight of them before
you have aligned a single read.

> **`set -euo pipefail` is necessary and not sufficient.** Six places where `-e` does not fire were
> covered in the lecture, and at least two of them are reachable in this assignment. Assertions on
> your data — the record count divides by four, R1 and R2 agree, the output is not empty — are what
> you actually rely on.
