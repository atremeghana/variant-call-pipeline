# Stage 9 · publish — say what produced these results.
#
# Course-provided, and the same file for every pipeline: nothing here names a rule
# or a parameter of yours. Your Snakefile sets three things, then includes it:
#
#   PIPELINE        = {"name": "variant-call", "version": "1.0.0"}
#   PUBLISH_SHEET   = rules.validate.output          # stage 0's copy of the samplesheet
#   PUBLISH_RESULTS = [...]                          # the files the manifest describes
#   include: "rules/publish.smk"
#
# and config.yaml has outdir, platform, executor and containers. It writes
# <outdir>/samples.tsv and <outdir>/manifest.json; ask for both in rule all.

import datetime
import os
import shlex

import snakemake
from snakemake.settings.types import DeploymentMethod

# The facts about the run, worked out once, in the process that was launched.
# publish is a local rule, so under Slurm it runs in that same process; every
# other rule runs in a Slurm job that reads the Snakefile again for itself.
_STARTED = datetime.datetime.now().astimezone()
RUN = {
    "NAME": PIPELINE["name"],
    "VERSION": PIPELINE["version"],
    "REVISION": "none",
    "COMMIT": "none",
    "RUN_NAME": "snakemake-" + _STARTED.strftime("%Y%m%dT%H%M%S"),
    "STARTED_AT": _STARTED.isoformat(),
    "LAUNCH_DIR": os.getcwd(),
    "ENGINE": f"snakemake {snakemake.__version__}",
    "PLATFORM": config["platform"],
    "EXECUTOR": config["executor"],
    "PARAMS": " ".join(f"{k}={v}" for k, v in config.items() if not isinstance(v, dict)),
    # The images are recorded only when the rules ran in them.
    "CONTAINERS": " ".join(f"{k}={v}" for k, v in config["containers"].items())
    if DeploymentMethod.APPTAINER in workflow.deployment_settings.deployment_method
    else "",
}

localrules: publish

# Its params hold when the run started, so they differ every run, and Snakemake
# reruns a rule whose params have changed: every run writes a fresh manifest,
# while the rules before it are reused.
rule publish:
    input:
        sheet=PUBLISH_SHEET,
        results=PUBLISH_RESULTS,
    output:
        manifest=os.path.join(config["outdir"], "manifest.json"),
        samples=os.path.join(config["outdir"], "samples.tsv"),
    params:
        env=" ".join(f"{k}={shlex.quote(v)}" for k, v in RUN.items()),
        script=os.path.join(workflow.basedir, "bin", "run_manifest.sh"),
    log:
        "logs/publish.log",
    container: "docker://" + config["containers"]["tools"]
    shell:
        r"""
        printf 'sample_id\tcondition\n' > {output.samples}
        awk -F, 'NR == 1 {{ for (i = 1; i <= NF; i++) col[$i] = i; next }}
                 {{ print $col["sample_id"] "\t" $col["condition"] }}' {input.sheet} >> {output.samples}

        # The manifest checksums copies of exactly what this run published.
        rm -rf work/publish && mkdir -p work/publish/published
        cp {input.results} {output.samples} work/publish/published/

        {params.env} {params.script} work/publish/published {input.sheet} > {output.manifest} 2> {log}
        """
