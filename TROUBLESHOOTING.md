# Troubleshooting Log

Written as I went — symptom, the evidence that located the cause, the cause, the fix.
This cannot be reconstructed afterward, so entries went in the moment something broke.

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
