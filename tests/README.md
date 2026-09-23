# Assignment 2 — Your variant-calling pipeline, as a job array

**Due:** Friday 25 September, 23:59 · **Worth:** 6 % of the course grade

Take the pipeline you built in week 1 and run it on Explorer as a Slurm job array. Eight samples at
once instead of one at a time, with the cohort stages held back until every sample has finished.

**You do not rewrite the analysis.** The ten stages do exactly what they did on your laptop. The
pipeline grows one thing — a per-sample entry point — and everything else you add is *outside* it.

That claim is the assignment, and the acceptance tests check it the only way that is fair: they look
inside `slurm/` for bioinformatics tool names. If `bwa` or `gatk` appears there, the boundary has
moved and the orchestration has started doing the analysis. **Improving your week-1 code is fine and
expected** — nothing is compared against last week's submission.

> ### If your week-1 pipeline does not run
>
> You still do this week's work, on the **demo** pipeline instead of your own.
>
> `w01-demo-pipeline-bash.zip` on Canvas is the complete `rnaseq-de` implementation shown in class —
> ten stages, same architecture, already on your machine. Job-array that.
>
> Nothing about this week changes. Every one of the five things below is about **submission**, not
> about biology: the array index, the barrier, the resource contract, the threads you were given and
> where the temp files go are identical whether the stages call `bwa` or `hisat2`. You lose no marks
> for taking this route.
>
> **Say so in one line at the top of `RESOURCES.md`** — *"job-arrayed the demo pipeline; my week-1
> pipeline did not complete"* — so the grader reads your `slurm/` against the right stages. Then come
> to office hours about week 1, because week 3 builds on it again.

---

## What you are adding

Four files, and none of them contains a bioinformatics tool:

```
slurm/
├── conf/slurm.env       partition, resources, paths — everything cluster-specific
├── 01_persample.sbatch  stages 0–5 for ONE sample, as one task of an array
├── 02_cohort.sbatch     stages 6–9, once, after every task has succeeded
└── submit.sh            two sbatch calls and one dependency
```

Plus **one file inside the pipeline**: a per-sample entry point. An array task runs *one* sample;
`run_pipeline.sh` runs all of them. Both call the same stages — which is the reason the stages moved
into their own files in assignment 1.

That is the whole week. The analysis from assignment 1 sits underneath, unchanged.

## The five things this is testing

### 1 · The array index is your samplesheet row

`$SLURM_ARRAY_TASK_ID` runs from 1 to 8. Row *N* of the samplesheet is sample *N*.

```bash
SAMPLE=$(awk -F',' -v n="${SLURM_ARRAY_TASK_ID}" 'NR == n + 1 { print $1 }' "${SAMPLESHEET}")
```

The `n + 1` skips the header. Get it wrong and every sample is processed under its neighbour's name —
a total corruption that produces a complete, plausible, entirely wrong cohort VCF.

Note what did *not* happen here: you did not write a new manifest of samples for Slurm to iterate.
The samplesheet from week 1 is the index, unchanged, because a good contract does not need to know
who will read it.

### 2 · The barrier is now a declaration, not a line position

In week 1 stage 6 ran after the loop because it came after the loop in the file. Your eight samples
are now on eight different machines and nothing orders them.

```bash
sbatch --dependency=afterok:${ARRAY_ID} 02_cohort.sbatch
```

**`afterok`, not `afterany`.** `afterany` starts the cohort job when the array *finishes*, whatever
happened. `afterok` starts it only if every task *succeeded*. Joint-genotype seven of eight samples
and you get a cohort VCF that is the right shape and the wrong experiment, with nothing anywhere
saying so.

When a task fails, **Explorer cancels the cohort job for you**, within seconds:

```
10382770   CANCELLED   Reason=Dependency
```

That is not the scheduler stuck — it is the scheduler refusing to build a wrong answer. It happens
automatically because this cluster sets `DependencyParameters = kill_invalid_depend`. **On a cluster
that does not, the same job sits `PENDING` with `DependencyNeverSatisfied` until a human notices**,
so write `--kill-on-invalid-dep=yes` anyway. One flag, and your script is right on a machine whose
defaults you did not check.

### 3 · A resource request is a contract

`--mem`, `--cpus-per-task`, `--time`.

**`--time` is enforced: at the limit your job is killed.** `--mem` on Explorer is **not** — a job
that asks for 1 GB and uses 6 GB completes, because the memory limit is simply not set on this
cluster. So under-asking will not bite you; it makes you a bad neighbour, because the scheduler
packs other people onto that node believing there is room. Most clusters do enforce it, and most
tutorials assume yours does.

You are required to **measure, then justify.** Run two or three samples with generous resources,
read what they actually used, then set your numbers:

```bash
seff <jobid>
sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS,AllocCPUS
```

Two things to know before you read those numbers, because both will mislead you otherwise.

**`CPU Efficiency` is not the number you want. `CPU time ÷ wall time` is** — that is how many cores
were actually busy. "I used 4.2 of my 16 cores" is a sentence you can act on.

**`MaxRSS` here is sampled every 30 seconds and read from the cgroup**, which means it can miss a
short peak *and* it counts file cache as memory your program needed. Do not size a request from one
reading. Either take the largest of several runs, or ask the kernel for the exact high-water mark:

```bash
CG=/sys/fs/cgroup$(awk -F: '/^0::/{print $3}' /proc/self/cgroup)
cat "$CG/memory.peak"
```

**And the measurement that decides `--cpus-per-task` is not `seff` at all.** Run the same sample at
two or three different core counts and compare wall clock. Sometimes more cores is *slower*.

### 4 · The threads you use are the threads you were given

```bash
export THREADS="${SLURM_CPUS_PER_TASK}"      # not a number you typed
```

Two ways to get this wrong, and they are not the same size.

**Not passing the count at all** is the expensive one. Almost every command-line tool defaults to
one thread, so `--cpus-per-task=8` with no `-t` means seven cores sit idle for the whole job.
Measured on this cluster, on the same input: **3.8× slower**, with no error anywhere.

**Passing more threads than you asked for** is the one everyone warns about and it is minor:
measured, 16 threads on 4 cores was **7.6 %** slower than 4 threads on 4 cores.

The fix for both is one line, and it is why you write the variable rather than a number — change
the `#SBATCH` line and the tool follows.

### 5 · Temp space belongs on the node, and a `trap` has to remove it

```bash
export TMPDIR="/tmp/${SLURM_JOB_ID}"
mkdir -p "${TMPDIR}"
trap 'rm -rf "${TMPDIR}"' EXIT
```

`samtools sort` keeps records in memory up to `-m` per thread and spills the rest to temporary
files, which by default land beside the output — on shared storage. Measured on one of the demo's
own BAMs (411 MiB, 6.1 M records, `-m 768M -@ 2`) that is **one** spill file of a few hundred
megabytes, written and deleted for nothing; the count grows with the input. Eight tasks do it at
once, and none of that traffic needs to leave the node.

`/tmp` on a compute node is local, fast, and **shared with every other job on that node**. Its
size depends on the node — measured, 298 GB on `d0135` and 821 GB on `c3014` — so run
`df -h /tmp` rather than assuming. There is no per-job private `/tmp` here (`$SLURM_TMPDIR` is unset on Explorer), so name
yours after the job id.

**And it has to be a `trap`, not a `rm` at the bottom.** A `rm` at the bottom does not run when the
job is cancelled or hits its time limit. Verified: after a `TIMEOUT`, `/tmp/<jobid>` was gone.

---

## Getting on the cluster

Complete the **Week 2 pre-flight** page before you start. It ends with `hpc_check.sh`, which tells
you whether you can log in, submit, load modules, and reach the shared reference.

> **Never run the pipeline on the login node.** It is shared by everyone logged in, and a
> whole-genome alignment there will be killed — after it has made the machine unusable for other
> people. `srun --pty /bin/bash` gets you an interactive shell on a compute node if you want to poke
> at something by hand.

The shared reference genome and the eight FASTQ files are already on the cluster; the pre-flight page
gives the path. Do not copy them into your home directory — they are large, your quota is not, and
everyone using the same read-only copy is the point.

### Get your code there by cloning, not by copying

**`git clone` your own repository onto Explorer. Do not `scp` or `rsync` your working directory.**

```bash
ssh <yourusername>@login.explorer.northeastern.edu
cd /scratch/$USER
git clone git@github.com:<you>/<your-repo>.git
```

Two reasons, and the second is the one that will save you an afternoon.

**It keeps the provenance real.** A clone has the repository's history, so `git rev-parse` works and
your manifest records the commit you are actually running. Copy the files instead and the `.git`
directory does not come with them, `git rev-parse` fails, and every cluster run writes
`git_sha: "unknown"` — the same field week 1 asked you to make real. Your laptop runs would be
attributable and your cluster runs would not, which is exactly backwards.

**It gives you one source of truth.** `scp` leaves you with two copies that drift, and the failure
mode is the worst kind: you fix a bug on your laptop, re-run on the cluster, and debug the old code
for an hour. `git push` from the laptop and `git pull` on Explorer keeps that impossible.

**One-time setup: a key for GitHub.** Cloning over SSH needs a key on Explorer that GitHub knows —
your Explorer login key is a different key and GitHub has never seen it. Verified on Explorer: the
network path is open (`github.com` answers on both 22 and 443), so the only missing piece is the
credential.

```bash
ls ~/.ssh/id_*.pub                     # you may already have one
ssh-keygen -t ed25519 -C "explorer"    # if not
cat ~/.ssh/id_ed25519.pub              # paste this into GitHub -> Settings -> SSH keys
ssh -T git@github.com                  # should greet you by username
```

If `git clone` asks for a **username and password**, that is this step missing — GitHub stopped
accepting passwords for git in 2021, so there is nothing you can type there that will work.

> If your repository is **private**, all of the above is required. If it is public, `git clone` over
> HTTPS works with no key at all — but you still want the key for `git push`.

---

## What to submit

Your week-1 repository, with `slurm/` added, a per-sample entry point, and **two files at the top
level**:

### `RESOURCES.md` — what you measured and what you changed

One table and a few sentences. What you asked for first, what the measurements said, what you set
it to, and why. The measurement is half the mark; **the decision it led to is the other half.**

Paste the real `seff` or `sacct` output. Include the core-count comparison — that is the one that
cannot be guessed.

### `TROUBLESHOOTING.md` — four failures you caused on purpose

**The data is small enough that nothing goes wrong by itself.** So you break it, four times, and
hand in what each one looked like. A `sacct` line and two or three sentences each.

| | Break it | Write down |
|---|---|---|
| 1 | `--time=00:02:00` | the `State`, where in the log it stopped, and what was left on disk |
| 2 | make one task `exit 1`, with the cohort job on `afterok` | what happened to the cohort job, and its `Reason` |
| 3 | `--array=1-9` against your eight-row samplesheet | what task 9 did — and what it would have done without a guard |
| 4 | `scancel` mid-write, then resubmit | whether the rerun trusted what was left behind |

These are cheap: each is one submission and under five minutes.

**Number 3 is the one that matters most**, because it is the only one of the four that can succeed
while being wrong. The other three announce themselves.

**If a breakage does not produce the failure you expected, write that down instead.** One of mine
did not — `fastp` finishes in 15 seconds, so a `scancel` never landed inside the write — and "I
aimed at X, got Y, here is why" is a full-marks answer. Retrying until the cluster agrees with the
brief is not.

Do not commit `results/`, `logs/`, or anything under the run directory.

## How it is graded

**100 points, nine acceptance tests.** They are in `tests/`, they run on your laptop, and you run
them before you submit.

```bash
bash tests/run_acceptance.sh .
```

| Pts | Test | Full marks | Partial |
|---:|---|---|---|
| 10 | `slurm/` contains no bioinformatics | the batch scripts orchestrate; the tools stay in `stages/` | — |
| 10 | a per-sample entry point | an array task can run one sample | **5** — it exists but does not decline stages 6–9 |
| 15 | the array index selects the right row | header skipped, **and** an out-of-range task refused | **10** — correct row, nothing checks it exists |
| 15 | `afterok`, not `afterany` | the cohort job depends on array success | **10** — no `--kill-on-invalid-dep`; **5** — `afterany` |
| 10 | threads come from `SLURM_CPUS_PER_TASK` | the variable, not a number you typed | **5** — used, but not reaching the tools |
| 10 | temp space on the node, removed by a `trap` | `/tmp/$SLURM_JOB_ID` and `trap ... EXIT` | **5** — node-local but no trap |
| 10 | the job does not depend on your shell or your directory | `--export=NONE`, `$SLURM_SUBMIT_DIR`, `mkdir -p logs` | **5–7** — one or two of the three |
| 10 | `RESOURCES.md` | measurements **and** what you changed | **5** — measurements only |
| 10 | `TROUBLESHOOTING.md` | all four failures, with evidence | **5** — two or three of them |

Nothing here is graded on the biology, and nothing is graded against last week's submission.

**What the tests cannot check:** that you ever submitted a job. They read your scripts. Passing all
nine without running anything on Explorer would be nine passes and no pipeline — and your two
write-ups are where that shows.

## Expect to wait

Your jobs queue. That is not a bug and it is the first thing about a cluster that laptops do not
prepare you for: submitting is instant, starting is not, and you have no control over the second
part.

Two consequences. **Start early** — a queue on Sunday night is not the queue on Wednesday afternoon.
And **submit rather than watch**: `sbatch`, then close your laptop. Everything about this design
exists so you do not have to be present while it runs.
