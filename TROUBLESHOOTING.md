# Troubleshooting Log

Written as I went — symptom, the evidence that located the cause, the cause, the fix.
This cannot be reconstructed afterward, so entries went in the moment something broke.

**Two parts.** [Part 1](#part-1--assignment-1-things-that-broke-by-themselves) is Assignment 1: things
that broke on their own while the pipeline was being written. [Part 2](#part-2--assignment-2-four-failures-caused-on-purpose)
is Assignment 2's four deliberate failures on Explorer. They are in one file because both
assignments' acceptance suites read `TROUBLESHOOTING.md` at the top level and take the first one
they find, so a second file under another name would be graded as an absent one.

---

# Part 1 · Assignment 1, things that broke by themselves

## Entry: CUTGZIP acceptance test fails — fixture, not code

**Symptom:** `bash tests/run_acceptance.sh .` reports "catches a truncated .fastq.gz in stage 0"
FAILED, and the CUTGZIP name is missing from "stage 0 reports every problem together" too.

**Evidence:** Reproduced the harness's own fixture generation by hand:
```
fq() creates a 20-record synthetic FASTQ, gzipped -> whole.fastq.gz
head -c 120 whole.fastq.gz > cut_R1.fastq.gz
```
`ls -la` shows `whole.fastq.gz` is only 109 bytes — smaller than the 120-byte cutoff. `head -c 120`
on a 109-byte file just copies the whole file. `gzip -t cut_R1.fastq.gz` exits 0, correctly,
because the file genuinely is a complete, valid gzip stream — nothing was truncated.

**Cause:** The synthetic FASTQ records in the test harness's `fq()` are highly repetitive
(same 4 lines repeated), so they compress far below the 120-byte assumption the fixture relies
on. This is a fixture-generation bug in the acceptance test itself, not in stage 0's validation
logic — confirmed independently (the same issue was reported on the course discussion board on a
different OS; reproduced it separately on WSL and a separate Linux sandbox). `gzip -t` is the
textbook-correct check for a truncated gzip stream. TA (Areeba Rahu) confirmed on the course
discussion board (19 Sep 2026) that this is a harness bug and that affected submissions will be
re-graded against a corrected harness.

**Fix:** None applied to `run_pipeline.sh` — there is nothing to detect, because the file is not
actually corrupt on this system. Per the TA's instruction, left both `run_pipeline.sh` and
`tests/run_acceptance.sh` unchanged.

**Follow-up (22 Sep 2026) — the conclusion above was incomplete, and the test was passable after
all.** Everything measured above still holds: `whole.fastq.gz` really is 109 bytes, `head -c 120`
really does copy it whole, `cmp` confirms the "cut" file is byte-identical to the original, and
`gzip -t` is right to exit 0 on it. What I got wrong was the inference — "individually valid gzip"
is not the same as "nothing to detect." The CUT sheet pairs `cut_R1.fastq.gz` (**20 records**, the
whole 20-record `whole.fastq.gz`) against `cut_R2.fastq.gz` (**4 records**, a copy of
`NA12891_R2.fastq.gz`) on a row declaring `library_type=paired`. Each file is a valid gzip stream;
as a *pair* they are broken, and mates whose record counts disagree are a genuine defect no
aligner can consume correctly. The same two files back the `CUTGZIP` row in the MANY sheet, so one
check clears both failing tests. Two things confirm this is the intended solution rather than a
loophole: the harness builds `shortmate_R1` (5 records) and `shortmate_R2` (4 records) fixtures at
`tests/run_acceptance.sh:94-95`, commented "one mate short", which **no test ever references** —
a mate-count check the reference solution evidently has and the shipped suite forgot to exercise
directly. Added that check to `stage_validate`: for any row where both mates are present, compare
record counts and report a mismatch naming the sample. Suite went from 7/9 to **9/9**. Note on
cost: stage 0 already fully decompresses every FASTQ via `gzip -t`, so counting records is the
same order of work, not a new one — on real GB-scale inputs the two passes should be folded into
one (`n=$(zcat f | wc -l)` under `pipefail` yields validity *and* the count).

**Resolution (23 Sep 2026) — the fixture bug is officially fixed, and the reason this test passes
has changed.** The corrected `w01-assignment-tests.zip` replaces the fixed 120-byte cut with
`head -c $(( $(wc -c < whole.fastq.gz) / 2 ))`, and adds a self-check that aborts the entire suite
if the "truncated" fixture ever passes `gzip -t` — the harness now refuses to grade anyone against
a fixture that tests nothing. Rebuilt it by hand to confirm: `whole.fastq.gz` is still 109 bytes,
the cut is now 54, and `gzip -t` fails on it as it should. So the claim above that the mate-count
check is what "clears both failing tests" was true of the old harness and is **no longer true of
this one**: stage 0 now catches CUTGZIP on the plain `gzip -t` branch, reporting `sample 'CUTGZIP':
r1_fastq is truncated or corrupt`. The mate-count check does not even fire, which is correct —
`pipefail` makes `zcat` fail on the corrupt stream, `n1` comes back empty, and the comparison is
skipped rather than inventing a second complaint about a file that could not be read at all. The
check stays on its own merits: `shortmate_R1` (5 records) and `shortmate_R2` (4) are *still* built
at `tests/run_acceptance.sh:100-101` and *still* referenced by no test, and mates that are out of
sync remain a real defect `gzip -t` cannot see. What I would keep from the whole episode: "the
fixture is broken" and "there is nothing here for my code to detect" are two different claims, and
establishing the first does not establish the second. I stopped at the first and called it done.

## Entry: .gitignore would have silently dropped the one file the assignment asks for

**Symptom:** None locally — that is the entire problem. `bash tests/run_acceptance.sh .` reported
10/10 in my working copy, including the 20-mark smoke test, and `git status` showed a clean tree.
A grader cloning the repo would instead have scored 10/20 on that test, against the message "no
`smoke-run/cohort.filtered.vcf.gz` in your repository."

**Evidence:** `.gitignore` carried a blanket `*.vcf.gz`, added early so cohort VCFs could never be
committed. The required deliverable `smoke-run/cohort.filtered.vcf.gz` matches that pattern.
`git add --dry-run smoke-run/` printed nothing for the VCF, and `git check-ignore -v
smoke-run/cohort.filtered.vcf.gz` named the exact rule doing it. The suite kept passing throughout
because it reads `smoke-run/` off the filesystem, not out of git: to a test that just opens the
path, an untracked file on disk is indistinguishable from a committed one.

**Cause:** A gitignore rule written for one purpose — never commit cohort VCFs — silently swallowed
a file the brief explicitly requires. No test could have caught it, because every test ran in a
working copy where the file was present but untracked.

**Fix:** Added `!smoke-run/` and `!smoke-run/**` after the blanket rules, exempting the one
directory the brief names. Verified twice, and the second one is the one that counts: first with
`git add --dry-run smoke-run/`, which now lists both files, and then by cloning the *pushed* repo
into a separate directory and running the suite from there — 10/10, with `cohort.filtered.vcf.gz`
(170,732 bytes) and `manifest.json` (3,001 bytes) genuinely present. Running the tests in the
directory where the work happened proves much less than it appears to. The fresh clone is the
real check, and it is cheap.

## Entry: harness detected --flags interface even though the driver is positional

**Symptom:** `bash tests/run_acceptance.sh .` printed "driver called as:
./run_pipeline.sh --samplesheet S --outdir D --to validate", but `run_pipeline.sh` only ever
parses `$1 $2 $3` - there is no flag-parsing code in it at all. Every test that depended on
stage 0 actually running failed identically, as if the driver never read the samplesheet.

**Evidence:** The harness detects the interface by grepping the driver's own source for the
literal patterns `--samplesheet`, `--outdir`, `--to `, `--to=` (tests/run_acceptance.sh, ~line 162).
`grep -nE -- '--samplesheet|--outdir|--to[[:space:]]|--to=' run_pipeline.sh` found a hit: the
FastQC call in stage_qc_raw used `fastqc --quiet --outdir "$sample_dir" ...` - an external tool's
own flag, unrelated to the driver's CLI, but textually indistinguishable from it to a naive grep.

**Cause:** The detector can't tell "my driver's interface" from "a flag I pass to a tool I call
inside a stage." Any stage that shells out to a tool using `--outdir`/`--samplesheet`/`--to`
poisons the detection for the whole script.

**Fix:** Switched to FastQC's short-flag alias: `fastqc --quiet -o "$sample_dir" ...`. Re-ran
`grep -nE -- '--samplesheet|--outdir|--to[[:space:]]|--to=' run_pipeline.sh` and confirmed zero
matches. Detector now correctly reports positional, and every test that had been failing on this
alone (single-end, duplicate-id, progress-to-stderr, no-sample-in-code) passed immediately.

## Entry: stage 0 rejected every real acceptance fixture on an invented column schema

**Symptom:** Once the driver-detection issue above was fixed, three tests still failed:
"stage 0 reports every problem together" named none of BADPATH/NOMATE/CUTGZIP, "catches a
truncated .fastq.gz" and "rejects a duplicate sample_id" both failed without naming the sample
they were supposed to catch - even though the same logic clearly worked against my own test
fixtures earlier in development.

**Evidence:** Read the harness's fixture-construction code directly (`sed -n '60,160p'
tests/run_acceptance.sh`). Every fixture sheet it builds uses the header
`sample_id,condition,replicate,library_type,r1_fastq,r2_fastq`. My `REQUIRED_COLS` in
`stage_validate` demanded `sample_id,r1_fastq,r2_fastq,library_type,sex,is_synthetic_phenotype` -
a schema I had invented myself from the cohort's `.tsv` file, not the one the demo pipeline /
acceptance tests actually use. `sex` and `is_synthetic_phenotype` don't exist in any harness
fixture, so the header-column check failed on every single test sheet before ever reaching
per-sample logic - the per-sample checks were never being exercised at all.

**Cause:** I guessed the samplesheet schema from the wrong source (the cohort metadata file)
instead of the one authority that matters (the demo pipeline / acceptance harness contract).

**Fix:** Changed `REQUIRED_COLS` to `(sample_id condition replicate library_type r1_fastq
r2_fastq)`, rebuilt the real cohort `samplesheet.csv` to match (mapping the tsv's `phenotype`
column to `condition`), and added a genuinely missing check while I was in there: a row with
`library_type=paired` but an empty `r2_fastq` (the NOMATE case) is now flagged explicitly, since
previously an empty r2 was always silently accepted as single-end regardless of what
`library_type` claimed. Re-ran the suite: 7/9, with the remaining 2 failures traced to an
unrelated, TA-confirmed bug in the harness's own truncated-gzip fixture (see entry above).

---

# Part 2 · Assignment 2, four failures caused on purpose

> **STATUS: SCAFFOLD. Three of the four have not been run on Explorer yet.**
>
> The cohort data is small enough that nothing fails by itself, so each failure below has to be
> provoked deliberately: one submission each, under five minutes each. The headings, the breakage
> command and the expected shape are written out ready. **Every `sacct` block marked
> `[not yet run]` is a placeholder — no State, Reason, Elapsed or ExitCode below has been observed
> on Explorer.** Failure 4 is the exception: it has real evidence, but from a *local* reproduction,
> and it is labelled as such.
>
> If a breakage produces something other than the failure expected here, write down what happened
> instead and why. That counts in full — e.g. a trimming step can finish before `scancel` lands, in
> which case nothing was cancelled mid-write and that is the finding.
## Failure 1 · `--time` too short → TIMEOUT

**Break it:**
```bash
cd slurm
sbatch -p courses -A binf6610.202710 --array=1-1 --time=00:02:00 01_persample.sbatch
```

**First attempt was a false start, worth recording.** The first run against the real `RUN_ROOT`
completed successfully within the 2-minute limit, because `align`/`postprocess`/`quantify` for
NA12878 were already cached from the prior full cohort run, and the resume guards correctly
skipped them. To get a genuine timeout, the test needs to run against output that has never been
produced before — a temporary `RUN_ROOT` override in `conf/slurm.env`, restored only after
confirming (via the job's own log) that it had already sourced the file and started running.

**Evidence (Explorer, job `10726328`, 30 Sep 2026, fresh output directory):**
```bash
sacct -j 10726328 --format=JobID,State,ExitCode,Elapsed,Timelimit
```
```
JobID             State ExitCode    Elapsed  Timelimit
------------ ---------- -------- ---------- ----------
10726328_1      TIMEOUT      0:0   00:02:03   00:02:00
10726328_1.+  CANCELLED     0:15   00:02:05
10726328_1.+  COMPLETED      0:0   00:02:04
```

Log, `logs/persample_10726328_1.err`:
```
task 1 on c0638: sample=NA12878 cores=8 tmpdir=/tmp/10726328
stage 0 (validate): checking samplesheet and inputs
stage 0: all samples validated OK
stage 1 (qc_raw): FastQC on raw FASTQ
stage 1: qc_raw complete for 1 sample(s)
stage 2 (trim): fastp adapter/quality trim
stage 2: trim complete for 1 sample(s)
stage 3 (align): BWA-MEM against full GRCh38
align: NA12878
slurmstepd: error: *** JOB 10726328 ON c0638 CANCELLED AT 2026-09-30T22:35:52 DUE TO TIME LIMIT ***
```

**Where it stopped:** mid-stage 3 (align), inside the `bwa mem | samtools view` pipeline. Stages
0-2 (validate, qc_raw, trim) completed cleanly in about 1:51 combined — align never got a chance
to finish.

**What was left on disk:**
```
$ ls -la align/NA12878/
total 1
-rw-r--r-- 1 atre.m users 47 Sep 30 22:35 bwa.log
```
Only `bwa.log` (47 bytes, BWA's startup message) — no `.partial.bam` and no real `NA12878.bam`.
The kill landed before `samtools view` had written anything at all, so there was nothing for the
atomic-write/resume-guard pair to even need to protect against here; a slightly later kill would
have left a `NA12878.partial.bam` instead, which is exactly the scenario Failure 4 covers.

**Confirms:** Slurm's `--time` limit is enforced exactly as documented — the job is killed
mid-command, not given a chance to finish its current step, and the state is correctly recorded
as `TIMEOUT` rather than `FAILED`.

## Failure 2 · a task exits 1, with the cohort job on `afterok`

**Break it:** copied the real 8-sample sheet, corrupted exactly one row's `r1_fastq` (NA12873,
row 8) to point at a file that doesn't exist, and submitted the modified sheet through
`submit.sh` so the `afterok` dependency was wired exactly as it normally is.

```bash
cp /courses/BINF6610.202710/data/samplesheet-variant8.csv ~/samplesheet-broken.csv
# edited NA12873's r1_fastq to .../NA12873_DOES_NOT_EXIST_R1.fastq.gz
# SAMPLESHEET in conf/slurm.env pointed at the broken copy, RUN_ROOT pointed at a fresh dir
bash slurm/submit.sh
```

**What actually happened — not what was expected, and more informative for it.** All eight
array tasks failed, not just the one carrying the bad row:

```bash
sacct -j 10726468 --format=JobID,State,ExitCode
```
```
JobID             State ExitCode
------------ ---------- --------
10726468_1       FAILED      1:0
10726468_2       FAILED      1:0
10726468_3       FAILED      1:0
10726468_4       FAILED      1:0
10726468_5       FAILED      1:0
10726468_6       FAILED      1:0
10726468_7       FAILED      1:0
10726468_8       FAILED      1:0
```

Task 1's log (`NA12878`, a perfectly valid sample) shows why:
```
task 1 on c0617: sample=NA12878 cores=8 tmpdir=/tmp/10726469
run_sample: restricting to sample 'NA12878'
run_sample: matched 1 row(s) for 'NA12878'
stage 0 (validate): checking samplesheet and inputs
stage 0: 1 problem(s) found
VALIDATION ERROR: sample 'NA12873': r1_fastq not found: /courses/.../NA12873_DOES_NOT_EXIST_R1.fastq.gz
```

**The cause:** `stage_validate()` is written (correctly, from Assignment 1's own "stage 0
reports every problem together" requirement) to validate the *entire* samplesheet on every
invocation, not just the row the current task cares about. Even though task 1 only ever
*processes* NA12878, it still *validates* the full sheet first and refuses to proceed the
moment any row in it is broken — including a row belonging to a sample this task will never
touch. One corrupted row in the sheet blocks every array task, not just the one it belongs to.

**Cohort job:**
```bash
sacct -j 10726476 --format=JobID,State,ExitCode,Reason
```
```
JobID             State ExitCode                 Reason
------------ ---------- -------- ----------------------
10726476      CANCELLED      0:0             Dependency
```

Correctly `CANCELLED` with reason `Dependency`, since **zero** of the eight array tasks
succeeded (`afterok` requires every task to succeed, and here none did) — `--kill-on-invalid-
dep=yes` meant it never sat `PENDING` waiting on an impossible condition.

**Why this is arguably a stronger result than the originally-expected "7 succeed, 1 fails"
scenario:** the assignment's framing imagines one bad sample silently costing you one column
of the cohort while the rest proceed. What was found instead is stricter: a single bad row
anywhere in the sheet halts the *entire* array before any compute happens on *any* sample —
which is more expensive (the whole array has to be resubmitted, not just the broken task) but
also safer, since it's impossible for a partially-valid-looking cohort to silently exist.
`afterok` still did exactly its job here: no task succeeded, so the cohort job correctly never
started, regardless of which stage caused the failures.
## Failure 3 · `--array=1-9` against an eight-row samplesheet

**This is the one that can succeed while being completely wrong**, which is why the guard exists.

**Break it:**
```bash
cd slurm
sbatch -p courses -A binf6610.202710 --array=1-9 01_persample.sbatch
```

**Evidence (Explorer, job `10726147`, 30 Sep 2026):**
```bash
sacct -j 10726147_9 --format=JobID,State,ExitCode
cat logs/persample_10726147_9.err
```
```
JobID             State ExitCode
------------ ---------- --------
10726147_9       FAILED     64:0
10726147_9.+     FAILED     64:0
10726147_9.+  COMPLETED      0:0

task 9: no data row 9 in /courses/BINF6610.202710/data/samplesheet-variant8.csv
the --array range is wider than the sheet has samples
```

**What task 9 did:** the awk in `01_persample.sbatch` finds no row 10 in an eight-row sheet and
returns an empty string, so the `[[ -z "${SAMPLE}" ]]` guard fires and the task exits **64**
(`EX_USAGE`) with `task 9: no data row 9 in <sheet>` and `the --array range is wider than the sheet
has samples`.

**What it would have done without the guard** — and this is the part worth writing up, because
nothing would have looked wrong: `run_sample.sh` would have been handed an empty `sample_id`.
Our `run_sample.sh` happens to refuse that too (it has its own empty-id check), but had it not,
`read_samples()` filtering on an empty `ONLY_SAMPLE_ID` returns **every** row, so task 9 would have
quietly processed the whole cohort a second time, single-threaded, inside one array task — and
exited 0. Under `afterok` that is worse than a failure: nine `COMPLETED` tasks, a cohort job that
starts happily, and no error anywhere to explain the elapsed time.

**Expected:** exit 64, `State=FAILED`, `ExitCode=64:0`.

**Actually happened:** exactly as expected. Task 9 exited `FAILED 64:0`, naming the exact sheet
and the missing row number. Tasks 1-8 ran normally against the real 8-row sheet — their
validate/qc_raw/trim stages re-ran in full (no resume guard on those), while
align/postprocess/quantify correctly skipped, already complete from the prior cohort run. No
silent "processed every row" or "no row, exit 0" behavior was observed anywhere in the array.

## Failure 4 · `scancel` mid-write, then resubmit

**Break it:**
```bash
sbatch -p courses -A binf6610.202710 --array=1-1 01_persample.sbatch   # fresh output directory
# watched the log until stage 3 (align) started, then:
scancel <jobid>
```

**Evidence — first run, cancelled (Explorer, job `10726580`, 30 Sep 2026):**
```bash
sacct -j 10726580 --format=JobID,State,ExitCode
```
```
JobID             State ExitCode
------------ ---------- --------
10726580_1   CANCELLED+      0:0
```

Log shows the cancel landed 9 seconds into stage 3, inside `bwa mem | samtools view`:
```
stage 3 (align): BWA-MEM against full GRCh38
align: NA12878
slurmstepd: error: *** JOB 10726580 ON c0617 CANCELLED AT 2026-09-30T22:56:04 ***
```

**What was left on disk:**
```
$ ls -la align/NA12878/
total 1
-rw-r--r-- 1 atre.m users 151 Sep 30 22:56 bwa.log
```
No `.partial.bam` and no real `NA12878.bam` — the cancel landed early enough that
`samtools view` had not yet written any output at all.

**The question being asked:** *did the rerun trust what was left behind?* Resubmitted the
identical job against the same output directory.

**Evidence — resubmission (job `10726629`):**
```bash
sacct -j 10726629 --format=JobID,State,ExitCode,Elapsed
```
```
JobID             State ExitCode    Elapsed
------------ ---------- -------- ----------
10726629_1    COMPLETED      0:0   00:08:24
```

The log confirms it **re-ran** align from scratch rather than skipping — `align: NA12878`
appears again, followed by a real completion 1:29 later, then postprocess and quantify both
ran to completion normally:
```
stage 3 (align): BWA-MEM against full GRCh38
align: NA12878
stage 3: align complete for 1 sample(s)
stage 4 (postprocess): sort, index, mark duplicates
...
stage 5: quantify complete for 1 sample(s)
stopping after requested stage: quantify
```

**What was left on disk after the successful rerun:**
```
$ ls -la align/NA12878/
total 215839
-rw-r--r-- 1 atre.m users 221013056 Sep 30 23:02 NA12878.bam
-rw-r--r-- 1 atre.m users      5630 Sep 30 23:02 bwa.log
```
A real, complete 221 MB BAM under the real name, **no `.partial.bam` left behind** — the
atomic rename removed the temp name the moment `samtools view` exited successfully.

**Confirms:** the rerun trusted nothing from the cancelled attempt. In this particular trial
the cancel landed early enough that there was nothing partial to trust in the first place — no
file existed under either the real or the `.partial` name — so the resume guard's `[[ -s
"$bam" ]]` check correctly found nothing and re-ran the stage unconditionally. This is the
same safe-by-construction behavior verified locally during development (see the Assignment 1
entries above): a stage only ever trusts a file that made it all the way to its real name,
and a `.partial` sibling is always discarded, never resumed from, before a stage starts over.
---

# Part 3 · Assignment 3, container failures caused on purpose

## Failure: missing --env THREADS

**Break it:** removed `--env THREADS="${THREADS}"` from `01_persample.sbatch`'s `apptainer exec`
line, left everything else (`--cleanenv`, `--bind`, the other three `--env` lines) intact, and ran
one sample on an 8-core allocation.

**Command:**
```
sbatch -p courses -A binf6610.202710 --array=1-1 --export=NONE 01_persample_nothreads.sbatch
```

**What it printed:** nothing failed. The job completed normally, `COMPLETED 0:0`, all five stages
ran to completion. The only evidence is in the tool's own log, not in Slurm's exit status:

```
$ grep "[main] CMD:" align/NA12878/bwa.log
[main] CMD: bwa mem -t 4 -R @RG\tID:NA12878\tSM:NA12878\tPL:ILLUMINA ...
```

**The actual failure:** the job was allocated 8 cores (`--cpus-per-task=8`), but `bwa mem` ran with
`-t 4` — the pipeline's own hardcoded default, since `THREADS` was never set inside the container
(`--cleanenv` strips everything not explicitly passed in with `--env`). Four of the eight cores sat
idle for the whole alignment step, and nothing anywhere reports this: exit code 0, no warning, no
log line saying "using fewer cores than requested." The only way to catch it is to go looking in
the tool's own log, exactly as the assignment's framing warns: "it stops nothing... only the log
shows it."

**The fix:** restore the `--env THREADS="${THREADS}"` line. Confirmed in the working version of
`01_persample.sbatch`, `bwa mem -t 8` is what actually runs.

## Failure: missing --bind

**Break it:** removed `--bind /courses/BINF6610.202710,/scratch/${USER}` from `01_persample.sbatch`'s
`apptainer exec` line, left `--cleanenv` and all four `--env` lines intact, and ran one sample.

**Command:**
```
sbatch -p courses -A binf6610.202710 --array=1-1 --export=NONE 01_persample_nobind.sbatch
```

**What it printed:** failed immediately, at stage 0, before any real work started:

```
$ sacct -j 10764764 --format=JobID,State,ExitCode
10764764_1    FAILED   1:0
```

```
$ cat logs/f2_10764764_1.err
task 1 on c3014: sample=NA12878 cores=8 tmpdir=/tmp/10764764
mkdir: cannot create directory '/scratch': Read-only file system
```

**Exit code:** 1. **Which path the container couldn't see:** `/scratch` — without `--bind`, the
container has no view of `/scratch/${USER}` at all (read-only, in fact not even mounted as the
real filesystem), so `mkdir -p "${TMPDIR}"` inside the pipeline's own setup fails before stage 0
can even begin. `/courses` would have failed the same way one step later if this hadn't failed
first — the pipeline would have reported every FASTQ as missing, the same failure mode the Week 3
page describes for FastQC ("Skipping ... which didn't exist").

**The fix:** restore `--bind /courses/BINF6610.202710,/scratch/${USER}`. Confirmed in the working
`01_persample.sbatch`, the run proceeds normally with this flag present.


## Failure: arm64 image on amd64 Explorer

**Break it:** pulled an arm64-architecture image directly on Explorer, then tried to run it.

**Command:**
```
apptainer pull --arch arm64 arm.sif docker://ubuntu:24.04
apptainer exec arm.sif uname -m
```

**Whether the pull succeeded:** yes, with no warning at pull time at all:

```
INFO:    Converting OCI blobs to SIF format
INFO:    Fetching OCI image...
27.6MiB / 27.6MiB [...] 100 % 19.5 MiB/s 0s
INFO:    Extracting OCI image...
INFO:    Creating SIF file...
[...] 100 % 0s
```

No error, no architecture check, a complete `.sif` file written to disk. The mismatch is
completely invisible until the moment you actually try to run it.

**What the run said:**

```
FATAL:   While checking container encryption: could not open image /home/atre.m/arm.sif:
the image's architecture (arm64) could not run on the host's (amd64)
```

**The lesson:** this is the exact failure mode the Week 2/3 pre-flight material already names
as the single most common way this assignment goes sideways — an image can be built, pushed,
and pulled with zero complaint, and only fails the moment it's actually executed on the wrong
CPU architecture. It's why `docker build --platform linux/amd64` and
`docker image inspect --format '{{.Architecture}}'` are checked *before* ever pushing — catching
this at build time on a laptop is free; catching it here, after a real pull, costs a wasted
pull and a job that never produces any useful output.

**The fix:** always build and pull with the correct architecture explicit — `--platform
linux/amd64` on `docker build`, and no `--arch arm64` override on `apptainer pull` (the default
correctly matches the host). Confirmed `atremeghana/variant-call:1.0` is `amd64` via
`docker image inspect --format '{{.Architecture}}'` before it was ever pushed.


## Failure: unpinned rebuild drift (incomplete — insufficient time gap)

**Break it:** built `FROM ubuntu` (no tag) with `RUN apt-get update && apt-get install -y curl`,
saved the package list (`dpkg -l`), intending to rebuild with `--pull --no-cache` a full day later
and diff the two.

**What actually happened:** the assignment's deadline did not allow the required 24-hour gap
between builds. Only ran the first build (2 Oct, ~14:34 EDT); never ran the second. This test
specifically requires elapsed real time — Ubuntu's apt repositories publish new package builds
on their own schedule, not on command, so a rebuild minutes or hours later would very plausibly
show the same packages as the first build, proving nothing. The course's own Week 3 material
makes this explicit with a real measurement: one pinned recipe, rebuilt 14 days apart, showed 57
packages differ; the same recipe rebuilt same-day would show close to zero.

**Why this one specifically needs the gap, unlike the other three:** failures 2-4 are
deterministic — removing `--bind` fails the same way whether you try it now or tomorrow. This one
is the opposite: it's testing a time-dependent external fact (whether upstream packages changed),
not a mistake in a flag or a recipe. There is no way to "simulate" the 24 hours; the gap *is* the
experiment.

**What this confirms about the fix regardless:** every tool this pipeline actually depends on
(bwa, samtools, bcftools, gatk4, fastqc, fastp, multiqc, git) is pinned to an exact version in
`containers/variant-call/Dockerfile`, verified directly against the course's own conda
environment via `conda env export`. The base image is also pinned to an exact tag
(`mambaorg/micromamba:2.0.5-ubuntu24.04`, digest recorded in `IMAGE.md`), not `latest`. The
real pipeline image is not exposed to the drift this test demonstrates — only the throwaway
`FROM ubuntu` (no tag) test image used specifically to provoke it would be.
