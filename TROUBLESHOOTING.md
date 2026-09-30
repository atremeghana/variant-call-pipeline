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

**Evidence:**
```
[not yet run]
sacct -j <jobid> --format=JobID,State,Elapsed,Timelimit,ExitCode,MaxRSS
```

**Write down:** the `State` (expected `TIMEOUT`, not `FAILED`), the last line reached in
`slurm/logs/persample_<jobid>_1.out` — which identifies the stage it died inside — and what was
left on disk under `$RUN_ROOT/run`.

**What to check specifically, because this is where our resume design gets tested:** the killed
stage should have left a `*.partial.bam` / `*.partial.g.vcf.gz` and **no** file under the real name.
`trap 'rm -rf "${TMPDIR}"' EXIT` should also have removed `/tmp/<jobid>` — confirm with
`ls /tmp/<jobid>` on the node, or by its absence in the next job's log.

**Expected:** `[to fill in]`  ·  **Actually happened:** `[to fill in]`

## Failure 2 · a task exits 1, with the cohort job on `afterok`

**Break it:** make exactly one array task fail, leaving the other seven to succeed — e.g. point one
row's `r1_fastq` at a path that does not exist, so stage 0 refuses that sample and only that sample.
Submit through `submit.sh` so the dependency is wired as it normally is:
```bash
bash slurm/submit.sh
```

**Evidence:**
```
[not yet run]
sacct -j <array_jobid> --format=JobID,State,ExitCode
sacct -j <cohort_jobid> --format=JobID,State,Reason,ExitCode
squeue -j <cohort_jobid> -o '%i %T %r'
```

**Write down:** what happened to the cohort job and its `Reason`. Expected: the array shows seven
`COMPLETED` and one `FAILED`; the cohort job never starts, and because `submit.sh` passes
`--kill-on-invalid-dep=yes` it is `CANCELLED` with a `DependencyNeverSatisfied` reason rather than
sitting in the queue forever.

**Why `afterok` and not `afterany`:** under `afterany` the cohort job would have run on seven
GVCFs and produced a joint-called VCF quietly missing a column, which is worse than no VCF.

**Expected:** `[to fill in]`  ·  **Actually happened:** `[to fill in]`

## Failure 3 · `--array=1-9` against an eight-row samplesheet

**This is the one that can succeed while being completely wrong**, which is why the guard exists.

**Break it:**
```bash
cd slurm
sbatch -p courses -A binf6610.202710 --array=1-9 01_persample.sbatch
```

**Evidence:**
```
[not yet run]
sacct -j <jobid> --format=JobID,State,ExitCode        # task _9 specifically
cat logs/persample_<jobid>_9.err
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

**Expected:** exit 64, `State=FAILED`, `ExitCode=64:0`.  ·  **Actually happened:** `[to fill in]`

## Failure 4 · `scancel` mid-write, then resubmit

**Break it:**
```bash
bash slurm/submit.sh 1-1
sleep 90                                  # long enough to be inside stage 3 or 4
scancel <array_jobid>
bash slurm/submit.sh 1-1                  # resubmit, same output directory
```

**The question being asked:** *did the rerun trust what was left behind?* It must not. A cancelled
job leaves a half-written file, and the whole point of the guard-plus-atomic-rename pair added for
this assignment is that such a file can never be mistaken for a finished one.

**Evidence — Explorer:**
```
[not yet run]
sacct -j <first_jobid>  --format=JobID,State,ExitCode    # expect CANCELLED
sacct -j <second_jobid> --format=JobID,State,Elapsed
ls -la $RUN_ROOT/run/align/<sample>/                     # before the resubmit
```

**Evidence — local reproduction (real, run on the smoke dataset):** the failure mode was
reproduced on a laptop rather than waiting for the cluster, by leaving behind exactly what a
`scancel` during stage 3 leaves: a truncated `smoke_01.partial.bam` (the first 4096 bytes of a good
BAM) and no `smoke_01.bam`. Re-running all ten stages then showed:

- the rerun logged `align: smoke_01` — it re-ran the stage rather than skipping it, so it did
  **not** trust the partial file;
- the leftover `.partial.bam` was gone afterwards (`discard_partial` removes a stale one before
  reusing the name, so it is deleted rather than resumed from);
- the rebuilt BAM was **byte-identical** to the one from the clean run, and passed
  `samtools quickcheck`;
- the other two samples logged `already done, skipping` and were not recomputed.

A second check in the same reproduction: deleting only `smoke_01.dedup.bam.bai` and leaving the BAM
caused `postprocess` to re-run for that sample rather than skip on the BAM alone — the guard tests
the data file *and* its index, because stage 5 needs both. The expensive sort was reused
(`sort already done`) while MarkDuplicates and the indexing were redone.

**Why a truncated file can never appear under the real name:** each stage writes to a `.partial`
sibling in the same directory and renames it only after the tool exits 0. A rename within one
filesystem is atomic, and the sidecar index is renamed *before* the data file, so the name the
guard tests for is always the last one to appear. Being killed between the two renames leaves an
index with no data file, the guard sees nothing, and the work is redone — the safe direction.

**Note on provoking this on Explorer:** with a 10 Mb call region the per-sample stages are quick,
so `scancel` may well land after the write it was aiming at. If that happens, say so and report
which stage had already completed — a `scancel` that arrives too late is a legitimate finding, not
a failed attempt.

**Expected:** `[to fill in from Explorer]`  ·  **Actually happened:** `[to fill in from Explorer]`
