#!/usr/bin/env python3
"""
Validate a stage-9 manifest against the manifest schema — shipped beside this
script in the week-8 archive, or `pipelines/contracts/` in the course repo.

This is the contract check that SPEC section 6 promises: Module 8's CI runs it on
every commit, week 1's acceptance tests run it against student output, and the
demo pipeline runs it on itself at the end of a run.

Stdlib only — no `jsonschema` dependency, because this machine has a bare
Python 3.9 and students should not need a venv to check their own output.
It implements the subset of JSON Schema the contract actually uses, and it
reports EVERY problem rather than stopping at the first, so one run tells a
student everything they need to fix.

Usage:
    check_manifest.py results/manifest.json
    check_manifest.py results/manifest.json --schema path/to/manifest.schema.json
    check_manifest.py results/manifest.json --results-dir results   # also verify checksums

Exit codes:  0 = valid    65 = contract violation    70 = internal/usage error
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Two places, tried in order, because this script runs in two different trees.
#
# In the course repository it sits at tools/validators/ and the schema is at
# pipelines/contracts/. In a STUDENT's repository it arrives as a single file in
# the week-8 archive, with the schema shipped beside it and no `pipelines/` tree
# anywhere -- and the first version resolved only the repository layout, so the
# command week 8's brief tells students to run failed with a file-not-found
# naming a directory they had never heard of. Found by unzipping the archive
# into an empty directory and working the brief from inside it
# (WORKING-AGREEMENTS §9 step 12), which is the only check that would have.
_SCHEMA_CANDIDATES = (
    REPO_ROOT / "pipelines" / "contracts" / "manifest.schema.json",
    Path(__file__).resolve().parent / "manifest.schema.json",
)
DEFAULT_SCHEMA = next((c for c in _SCHEMA_CANDIDATES if c.is_file()),
                      _SCHEMA_CANDIDATES[0])

# `fullmatch`, not `match`, at every use below. Python's `$` also matches just
# BEFORE a trailing newline, so `pat.match("variant-call\n")` succeeds on an
# anchored pattern. Measured 2026-08-30: the validator accepted a pipeline name
# with a trailing newline, and that value then reaches week 9's `runs.pipeline`,
# where it renders identically to the clean name and compares unequal -- a
# `GROUP BY pipeline` that silently splits into two rows. ERRATA
# TOOL-anchored-regex-with-match-accepts-a-trailing-newline.
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
ISO8601 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, where, msg):
        self.errors.append(f"{where}: {msg}")

    def warn(self, where, msg):
        self.warnings.append(f"{where}: {msg}")


def enum_of(schema, *path):
    """Pull an enum out of the schema so the checker can't drift from it."""
    node = schema
    for key in path:
        node = node.get("properties", node).get(key, {}) if key != "items" else node.get("items", {})
    return node.get("enum")


def check(manifest, schema, rep, results_dir=None):
    for key in schema.get("required", []):
        if key not in manifest:
            rep.error("$", f"missing required key '{key}'")

    # ---- pipeline ---------------------------------------------------------
    pipe = manifest.get("pipeline")
    if not isinstance(pipe, dict):
        rep.error("$.pipeline", "must be an object")
    else:
        pschema = schema["properties"]["pipeline"]
        for key in pschema.get("required", []):
            if key not in pipe:
                rep.error("$.pipeline", f"missing required key '{key}'")
        for key, pat, label in (("version", SEMVER, "SemVer (e.g. 1.0.0)"),
                                ("started_at", ISO8601, "ISO-8601 timestamp"),
                                ("finished_at", ISO8601, "ISO-8601 timestamp")):
            val = pipe.get(key)
            if val is not None and not pat.fullmatch(str(val)):
                rep.error(f"$.pipeline.{key}", f"{val!r} is not {label}")
        for key in ("name", "implementation", "exit_status"):
            spec = pschema["properties"].get(key, {})
            allowed = spec.get("enum")
            if allowed and pipe.get(key) not in allowed:
                rep.error(f"$.pipeline.{key}", f"{pipe.get(key)!r} not in {allowed}")
            # A constraint the schema states but this checker does not implement is
            # worse than no constraint, because the schema reads as if it were
            # enforced. `pipeline.name` stopped being an enum on 2026-08-30 -- the
            # closed list of two made the final project's second pipeline
            # unrepresentable -- and became a pattern; until this branch existed,
            # '', 'My Pipeline' and '-leading-dash' all validated clean.
            elif not allowed and spec.get("pattern"):
                val = pipe.get(key)
                if val is None or not re.fullmatch(spec["pattern"], str(val)):
                    rep.error(f"$.pipeline.{key}",
                              f"{val!r} does not match {spec['pattern']}")
        sha = str(pipe.get("git_sha", ""))
        if sha and sha != "unknown" and len(sha) < 7:
            rep.error("$.pipeline.git_sha", f"{sha!r} is shorter than 7 characters")

    # ---- platform --------------------------------------------------------
    plat = manifest.get("platform")
    if not isinstance(plat, dict):
        rep.error("$.platform", "must be an object")
    else:
        allowed = schema["properties"]["platform"]["properties"]["kind"].get("enum")
        if allowed and plat.get("kind") not in allowed:
            rep.error("$.platform.kind", f"{plat.get('kind')!r} not in {allowed}")
        digests = plat.get("container_digests") or {}
        for tool, dig in digests.items():
            if not SHA256.fullmatch(str(dig)):
                rep.error(f"$.platform.container_digests.{tool}",
                          f"{dig!r} is not a sha256 digest")
        if plat.get("kind") not in ("laptop", "slurm") and not digests:
            rep.warn("$.platform.container_digests",
                     "empty on a containerized platform — SPEC section 6 expects digests from "
                     "week 3 onward")

    # ---- reference -------------------------------------------------------
    ref = manifest.get("reference")
    if not isinstance(ref, dict):
        rep.error("$.reference", "must be an object")
    elif not ref.get("genome"):
        rep.error("$.reference.genome", "missing or empty")

    # ---- samples ---------------------------------------------------------
    samples = manifest.get("samples")
    sample_ids = set()
    if not isinstance(samples, list) or not samples:
        rep.error("$.samples", "must be a non-empty array")
    else:
        lib_enum = schema["properties"]["samples"]["items"]["properties"]["library_type"].get("enum")
        for i, s in enumerate(samples):
            at = f"$.samples[{i}]"
            if not isinstance(s, dict):
                rep.error(at, "must be an object")
                continue
            for key in ("sample_id", "library_type", "condition"):
                if key not in s:
                    rep.error(at, f"missing required key '{key}'")
            if lib_enum and s.get("library_type") not in lib_enum:
                rep.error(f"{at}.library_type", f"{s.get('library_type')!r} not in {lib_enum}")
            sid = s.get("sample_id")
            if sid in sample_ids:
                rep.error(f"{at}.sample_id", f"duplicate sample_id {sid!r}")
            sample_ids.add(sid)

    # ---- outputs ---------------------------------------------------------
    outputs = manifest.get("outputs")
    if not isinstance(outputs, list):
        rep.error("$.outputs", "must be an array")
    else:
        stage_enum = schema["properties"]["outputs"]["items"]["properties"]["stage"].get("enum")
        seen_paths = set()
        for i, o in enumerate(outputs):
            at = f"$.outputs[{i}]"
            if not isinstance(o, dict):
                rep.error(at, "must be an object")
                continue
            for key in ("stage", "type", "path", "checksum"):
                if key not in o:
                    rep.error(at, f"missing required key '{key}'")
            if stage_enum and o.get("stage") not in stage_enum:
                rep.error(f"{at}.stage", f"{o.get('stage')!r} is not one of the ten pipeline stages")
            if not SHA256.fullmatch(str(o.get("checksum", ""))):
                rep.error(f"{at}.checksum",
                          f"{str(o.get('checksum'))[:24]!r} does not match sha256:<64 hex>")
            path = o.get("path")
            if path in seen_paths:
                rep.error(f"{at}.path", f"duplicate path {path!r}")
            seen_paths.add(path)
            if path and str(path).startswith("/"):
                rep.error(f"{at}.path", f"{path!r} is absolute; paths must be relative to results/")
            if results_dir and path:
                f = Path(results_dir) / path
                if not f.is_file():
                    rep.error(f"{at}.path", f"file does not exist: {f}")
                else:
                    actual = "sha256:" + hashlib.sha256(f.read_bytes()).hexdigest()
                    if actual != o.get("checksum"):
                        rep.error(f"{at}.checksum",
                                  f"does not match file contents\n      recorded: {o.get('checksum')}"
                                  f"\n      actual:   {actual}")

    # ---- metrics ---------------------------------------------------------
    metrics = manifest.get("metrics")
    if not isinstance(metrics, list):
        rep.error("$.metrics", "must be an array")
    else:
        for i, m in enumerate(metrics):
            at = f"$.metrics[{i}]"
            if not isinstance(m, dict):
                rep.error(at, "must be an object")
                continue
            for key in ("metric", "value", "stage"):
                if key not in m:
                    rep.error(at, f"missing required key '{key}'")
            if not isinstance(m.get("value"), (int, float)) or isinstance(m.get("value"), bool):
                rep.error(f"{at}.value", f"{m.get('value')!r} is not a number")
            sid = m.get("sample_id")
            if sid is not None and sample_ids and sid not in sample_ids:
                rep.error(f"{at}.sample_id", f"{sid!r} is not in $.samples")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--schema", default=str(DEFAULT_SCHEMA))
    ap.add_argument("--results-dir",
                    help="also verify that every recorded checksum matches the file on disk")
    a = ap.parse_args()

    try:
        schema = json.loads(Path(a.schema).read_text())
    except Exception as e:
        sys.exit(f"error: cannot read schema {a.schema}: {e}")
    try:
        manifest = json.loads(Path(a.manifest).read_text())
    except FileNotFoundError:
        sys.exit(f"error: no such file: {a.manifest}")
    except json.JSONDecodeError as e:
        print(f"FAIL  {a.manifest}\n  not valid JSON: {e}", file=sys.stderr)
        sys.exit(65)

    rep = Report()
    check(manifest, schema, rep, a.results_dir)

    for w in rep.warnings:
        print(f"  WARN  {w}")
    if rep.errors:
        print(f"FAIL  {a.manifest} — {len(rep.errors)} contract violation(s):", file=sys.stderr)
        for e in rep.errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(65)

    n_out = len(manifest.get("outputs", []))
    n_met = len(manifest.get("metrics", []))
    n_smp = len(manifest.get("samples", []))
    extra = " (checksums verified)" if a.results_dir else ""
    print(f"OK    {a.manifest} — {n_smp} samples, {n_out} outputs, {n_met} metrics{extra}")


if __name__ == "__main__":
    main()
