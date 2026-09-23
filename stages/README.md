# stages/

**Intentionally empty in week 1.** The stage code is in
[`../lib/pipeline_lib.sh`](../lib/pipeline_lib.sh).

The brief lists `stages/  # one script per stage` in the submission layout, and then says
splitting the pipeline up is week 2's work: *"Week 1's demo is a single file and so is the first
thing you should write — one script, one function per stage, run in order. Splitting it into
`lib/` and `stages/` is week 2's work, and week 2 gives you the reason... Split it before you have
that reason and you get a broken script and no lesson."*

So there is one function per stage — `stage_validate`, `stage_qc_raw`, ... `stage_publish`, in
pipeline order — and `../run_pipeline.sh` is a thin driver that runs them in sequence and stops
after the stage you name.

They live in `lib/` rather than in a single top-level script because week 2's reason has already
arrived: a Slurm array runs stages 0–5 for *one* sample, so `../run_sample.sh` (one array task)
and `../run_cohort.sh` (stages 6–9) have to call the identical functions, and eight tasks logging
at once need the sheet reading and logging to live in one place.

This directory is kept so the layout matches the brief, and so per-stage scripts have an obvious
home if that split ever earns its keep.
