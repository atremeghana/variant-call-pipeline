# Resources — what we asked for, what we measured, what we changed

> **STATUS: SCAFFOLD. The measurement columns are empty on purpose.**
>
> Nothing in this file has been measured on Explorer yet. Every "asked for" value below is real —
> it is what `slurm/conf/slurm.env` and the `#SBATCH` defaults currently request — but every
> "measured" and "set to" cell is a placeholder marked `—`, and the reasoning column says
> `[unmeasured]`. **Do not quote any number here as a measurement until the cell holding it has
> been filled in from a real job.** Half the mark for this file is the measurement; the other half
> is the decision it led to, and neither exists yet.

## 1 · What we ask for now, and why those numbers

These are guesses carried over from Assignment 1's placeholder `slurm.env`. They are recorded here
so that the measured values have something to be compared against.

| Job | Knob | Asked for | Measured | Set to | Why |
|---|---|---|---|---|---|
| per-sample array task | `--cpus-per-task` | 8 | — | — | `[unmeasured]` |
| per-sample array task | `--mem` | 32G | — | — | `[unmeasured]` |
| per-sample array task | `--time` | 04:00:00 | — | — | `[unmeasured]` |
| cohort job | `--cpus-per-task` | 4 | — | — | `[unmeasured]` |
| cohort job | `--mem` | 24G | — | — | `[unmeasured]` |
| cohort job | `--time` | 02:00:00 | — | — | `[unmeasured]` |

Both sets live in `slurm/conf/slurm.env`, which `slurm/submit.sh` passes to `sbatch` on the command
line. The `#SBATCH` directives inside the two `.sbatch` files carry the same values as defaults, so
a job submitted by hand still gets something sane, but `slurm.env` is the one place to edit.

## 2 · How to fill this in

Run the array, let the cohort job follow it, then read what they actually used. `submit.sh` prints
both job ids and the exact commands on the way out.

```bash
bash slurm/submit.sh 1-2          # two samples first, to prove the wiring
bash slurm/submit.sh              # then all eight

seff <array_jobid>_1
seff <cohort_jobid>
sacct -j <jobid> --format=JobID,JobName,State,Elapsed,MaxRSS,AllocCPUS,ReqMem
```

Three things to be careful about when reading the output:

- **Cores actually kept busy = `CPU Utilized` ÷ `Job Wall-clock time`.** `4.2` means about four of
  the cores we asked for did any work. Asking for 8 and measuring 4.2 is the signal to drop the
  request, not to leave it.
- **`MaxRSS` can be wrong in both directions.** Slurm samples memory every 30 s, so it can miss a
  short peak, and the figure includes file cache the program never needed. Take the largest `MaxRSS`
  across several runs, or read the exact peak from the cgroup at the end of the job script:
  ```bash
  CG=/sys/fs/cgroup$(awk -F: '/^0::/{print $3}' /proc/self/cgroup)
  cat "$CG/memory.peak"
  ```
- **Explorer does not kill a job for exceeding `--mem`** (a job that asked for 1 GB and used 6 GB
  finished normally), but it does kill one that exceeds `--time`. Over-asking for memory is still
  antisocial — Slurm packs other jobs onto the node believing our number — and most other clusters
  do enforce it.

### Paste the real output here

```
[seff <array_jobid>_1 output goes here — not yet run]
```

```
[seff <cohort_jobid> output goes here — not yet run]
```

## 3 · Core-count comparison

Required by the brief: run the *same sample* at two or three core counts and compare elapsed time.
More cores does not always mean faster, and the knee is the number worth asking for.

```bash
# same sample, same input, three allocations
sbatch -p courses -A binf6610.202710 --array=1-1 --cpus-per-task=4  slurm/01_persample.sbatch
sbatch -p courses -A binf6610.202710 --array=1-1 --cpus-per-task=8  slurm/01_persample.sbatch
sbatch -p courses -A binf6610.202710 --array=1-1 --cpus-per-task=16 slurm/01_persample.sbatch
```

Run these from inside `slurm/` (or via `submit.sh`), so `$SLURM_SUBMIT_DIR` holds `conf/slurm.env`.
Each needs its own output directory, or the resume guards from section 4 will make runs 2 and 3
skip all the work and report a few seconds.

| Cores | Elapsed | CPU Utilized | Cores busy | Core-minutes | Verdict |
|---:|---|---|---:|---:|---|
| 4 | — | — | — | — | `[unmeasured]` |
| 8 | — | — | — | — | `[unmeasured]` |
| 16 | — | — | — | — | `[unmeasured]` |

**Conclusion:** `[to be written once the three runs above have finished]`

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
  against 8 minutes with it in `${TMPDIR}`, for the same 36,853 records.
- **Threads come from the scheduler.** Both `.sbatch` scripts `export THREADS="$SLURM_CPUS_PER_TASK"`
  and the library lets an environment `THREADS` beat `conf/pipeline.env`, so `--cpus-per-task` is the
  only number to change. *Course page measurement, not ours:* not passing a thread count at all is
  3.8 times slower on the same input, with no error — seven of eight cores simply sit idle.
  Over-subscribing is cheap by comparison: 16 threads on 4 cores measured 7.6 % slower than 4 on 4.
- **Every stage that writes a file now skips work whose output is already complete**, and writes
  under a `.partial` name it renames only on success. That is a correctness change first (see
  `TROUBLESHOOTING.md`, failure 4) but it has a resource consequence worth stating: a resubmitted
  cohort job costs roughly the unguarded stages only, instead of the whole pipeline again.

**Still unmeasured, and worth measuring:** stages 0, 1, 2, 8 and 9 have no resume guard. Stage 0 in
particular decompresses every R1 and R2 in full to compare mate record counts, so it is the most
expensive thing a rerun repeats. If the cohort job's elapsed time is dominated by stage 0 rather
than by stages 6-9, that is the next thing to fix.
