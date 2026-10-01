# Resources — what we asked for, what we measured, what we changed

Measured on Explorer (`courses` partition), 30 Sep 2026: the full 8-sample cohort run
(array job `10698335`, cohort job `10698343`), plus a 3-point core-count comparison on sample
NA12878 (jobs `10717008` at 4 cores, `10698335_1` at 8 cores, `10717242` at 16 cores, each in
its own output directory to avoid our resume guards skipping real work).

## 1 · What we asked for, and what we changed to

| Job | Knob | Asked for | Measured | Set to | Why |
|---|---|---|---|---|---|
| per-sample array task | `--cpus-per-task` | 8 | see §3 | 8 | 4→8 cores cut wall-clock ~34%; 8→16 bought ~6% more while nearly doubling memory. 8 is the knee. |
| per-sample array task | `--mem` | 32G | peak 14.21 GB (NA12873) across all 8 real samples | 20G | Comfortably above the highest observed peak, without reserving memory nobody used. |
| per-sample array task | `--time` | 04:00:00 | slowest real task 13:19 (NA12813) | 00:30:00 | Over 2x the slowest observed task — enough margin for a slower node, without masking a genuinely hung job for hours. |
| cohort job | `--cpus-per-task` | 4 | 4 (unchanged — see note below) | 4 | Not re-swept: merge/analyze/qc_report are mostly single-threaded tools, so a core sweep wasn't expected to move the needle. |
| cohort job | `--mem` | 24G | peak 4.73 GB | 8G | Used a fifth of what was requested; 8G gives real headroom without reserving 5x the need. |
| cohort job | `--time` | 02:00:00 | 9:33 | 00:20:00 | Over 2x observed, same reasoning as the array job. |

Both sets live in `slurm/conf/slurm.env`, which `slurm/submit.sh` passes to `sbatch` on the command
line.

## 2 · The full cohort run

```bash
bash slurm/submit.sh              # all eight samples
seff 10698335_1
seff 10698343
sacct -j 10698335 --format=JobID,JobName,State,Elapsed,MaxRSS,AllocCPUS,ReqMem
sacct -j 10698343 --format=JobID,JobName,State,Elapsed,MaxRSS,AllocCPUS,ReqMem
```

**Per-sample array task, all 8 real samples, `--cpus-per-task=8`:**

| Sample | Elapsed | MaxRSS |
|---|---|---|
| NA12878 | 8:45 | 6.65 GB |
| NA12891 | 9:53 | 6.63 GB |
| NA12892 | 6:18 | 6.37 GB |
| NA07357 | 8:18 | 12.88 GB |
| NA12003 | 7:04 | 6.46 GB |
| NA10851 | 8:18 | 12.76 GB |
| NA12813 | 13:19 | 13.13 GB |
| NA12873 | 10:00 | 14.21 GB |

Slowest task 13:19, highest MaxRSS 14.21 GB. The spread (6:18–13:19, nearly 2x) tracks each
sample's actual read depth — all eight ran under identical `--cpus-per-task=8`, so the
variation isn't a resource-allocation artifact.

**Cohort job (merge, analyze, qc_report, publish), `--cpus-per-task=4`:**

| | |
|---|---|
| Elapsed | 9:33 |
| MaxRSS | 4.73 GB |
| AllocCPUS | 4 |

**On `CPU Utilized ÷ Job Wall-clock time` and the memory-sampling caveats this scaffold warns
about:** the cohort job's observed MaxRSS (4.73 GB) sat well under its 24G request — a fifth
of what was asked — which is the over-request pattern the section above specifically calls
out as costing other jobs on the node their fair share, not something to leave as-is just
because Explorer doesn't enforce `--mem`.

## 3 · Core-count comparison

Same sample (NA12878), same input, three allocations, each run against its own isolated
output directory so the resume guards couldn't skip real work and silently invalidate the
comparison:

```bash
sacct -j 10717008 --format=JobID,State,Elapsed,MaxRSS   # 4 cores
sacct -j 10698335 --format=JobID,State,Elapsed,MaxRSS   # 8 cores (from the full array run)
sacct -j 10717242 --format=JobID,State,Elapsed,MaxRSS   # 16 cores
```

| Cores | Elapsed | MaxRSS | Verdict |
|---:|---|---|---|
| 4 | 13:11 | 9.76 GB | Slowest — the baseline this comparison is measured against |
| 8 | 8:45 | 6.65 GB | ~34% faster than 4 cores — the clear win |
| 16 | 8:14 | 12.88 GB | Only ~6% faster than 8 cores, while nearly doubling memory use |

**Conclusion:** 8 cores is the knee in this curve. The jump from 4→8 is worth taking; the jump
from 8→16 is not — it costs real memory for marginal speed, exactly the pattern the course
material warns "more cores does not always mean faster." `--cpus-per-task=8` is kept as
originally configured, now with a real measurement behind it instead of a guess.

One thing worth flagging rather than smoothing over: MaxRSS at 8 cores (6.65 GB) came out
*lower* than at both 4 cores (9.76 GB) and 16 cores (12.88 GB) on the identical sample. Given
this scaffold's own warning that MaxRSS is sampled every 30s and can miss short peaks, this
is read as a sampling artifact, not evidence that 8 cores genuinely uses less memory than 4 —
the `--mem=20G` setting above is sized off the full 8-sample array's observed peak (14.21 GB),
not off this single-sample number.

## 4 · Changes already made for resource reasons

Unlike the table above, these are changes to the code that are already in place. Two of them are
justified by measurements published on the course's week-2 page rather than by our own runs, and are
attributed as such.

- **Temporary files moved to the node's own disk.** `samtools sort -T`, GATK's `--tmp-dir` and
  Picard's `--TMP_DIR` all now point at `$TMPDIR`, which both `.sbatch` scripts set to
  `/tmp/$SLURM_JOB_ID` and remove with a `trap ... EXIT`. Before this, every one of them spilled to
  its default: `samtools sort` writes its overflow *beside the output*, which on Explorer is
  `/scratch` over NFS, and eight array tasks doing that at once buys nothing.
- **The GenomicsDB workspace moved to `$TMPDIR` as well.** This is the largest single change in the
  cohort job. *Course page measurement, not ours:* the GenomicsDBImport + GenotypeGVCFs pair over
  these eight GVCFs took 36, 58 and 96 minutes in three runs with the workspace on `/scratch`,
  against 8 minutes with it in `${TMPDIR}`, for the same 36,853 records. Our own cohort job's
  9:33 total elapsed time is consistent with this workspace fix already being in place rather
  than the slower, /scratch-based figures the course page measured before it.
- **Threads come from the scheduler.** Both `.sbatch` scripts `export THREADS="$SLURM_CPUS_PER_TASK"`
  and the library lets an environment `THREADS` beat `conf/pipeline.env`, so `--cpus-per-task` is the
  only number to change. *Course page measurement, not ours:* not passing a thread count at all is
  3.8 times slower on the same input, with no error — seven of eight cores simply sit idle.
  Over-subscribing is cheap by comparison: 16 threads on 4 cores measured 7.6 % slower than 4 on 4.
- **Every stage that writes a file now skips work whose output is already complete**, and writes
  under a `.partial` name it renames only on success. That is a correctness change first (see
  `TROUBLESHOOTING.md`, failure 4) but it has a resource consequence worth stating: a resubmitted
  cohort job costs roughly the unguarded stages only, instead of the whole pipeline again. This is
  also why the core-count comparison in §3 had to use a fresh output directory per run — without
  that, the guards would have reported a few seconds for every core count and the comparison would
  have measured nothing.

**Still unmeasured, and worth measuring:** stages 0, 1, 2, 8 and 9 have no resume guard. Stage 0 in
particular decompresses every R1 and R2 in full to compare mate record counts, so it is the most
expensive thing a rerun repeats. The real cohort job's 9:33 elapsed time (§2) is dominated by stages
6-9, not stage 0, so this hasn't yet been the bottleneck in practice — but it remains the next thing
to fix if a resubmitted cohort job's time ever starts being dominated by stage 0 instead.
