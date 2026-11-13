#!/usr/bin/env python3
"""load.py — loads one or more pipeline run folders into the Assignment 9 database.

    python3 db/load.py <database> <metadata.tsv> <run-folder> [<run-folder> ...]

The database must already have its tables (run db/schema.sql first). Each run
folder must hold manifest.json, samples.tsv and variants.tsv.

A run already present (by its manifest's run_id) is skipped. A run whose
manifest lists the same sample twice is refused, whole, by run_samples'
primary key - nothing of that run is left in the database.
"""
import csv
import json
import os
import sqlite3
import sys


def read_metadata(path):
    """Rows of the cohort metadata file, skipping its leading '#' notes."""
    with open(path, newline="") as f:
        lines = [line for line in f if not line.startswith("#")]
    return list(csv.DictReader(lines, delimiter="\t"))


def read_tsv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def load_metadata(con, metadata_path):
    """samples, from the cohort metadata file. Re-running this changes nothing:
    a sample_id already present is left as it is."""
    for row in read_metadata(metadata_path):
        father = row["father"] if row["father"] not in ("", "0") else None
        mother = row["mother"] if row["mother"] not in ("", "0") else None
        is_synth = 1 if row["is_synthetic_phenotype"].strip().lower() in ("true", "1") else 0
        con.execute(
            """INSERT OR IGNORE INTO samples
               (sample_id, sex, population, family, father, mother,
                phenotype, is_synthetic_phenotype)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (row["sample_id"], row["sex"], row["population"], row["family"],
             father, mother, row["phenotype"], is_synth),
        )


def get_or_create_pipeline(con, name, version, implementation):
    row = con.execute(
        "SELECT pipeline_id FROM pipelines WHERE name = ? AND version = ? AND implementation = ?",
        (name, version, implementation),
    ).fetchone()
    if row:
        return row[0]
    cur = con.execute(
        "INSERT INTO pipelines (name, version, implementation) VALUES (?, ?, ?)",
        (name, version, implementation),
    )
    return cur.lastrowid


def load_run(con, folder):
    """One run folder, as a single transaction: it goes in whole, or not at all."""
    folder = os.path.abspath(folder)
    with open(os.path.join(folder, "manifest.json")) as f:
        manifest = json.load(f)

    p = manifest["pipeline"]
    run_id = p["run_id"]

    already = con.execute("SELECT 1 FROM runs WHERE run_id = ?", (run_id,)).fetchone()
    if already:
        print(f"{os.path.basename(folder)}/: run_id {run_id} already loaded, skipping")
        return

    pipeline_id = get_or_create_pipeline(con, p["name"], p["version"], p["implementation"])

    params = manifest.get("params", {})
    platform = manifest.get("platform", {})

    samples_in_manifest = manifest.get("samples", [])
    variants = read_tsv(os.path.join(folder, "variants.tsv"))
    outputs = manifest.get("outputs", [])

    with con:
        # Any sample this run names that the metadata file does not describe
        # (the smoke samples) needs a row of its own before run_samples can
        # point at it.
        for s in samples_in_manifest:
            con.execute("INSERT OR IGNORE INTO samples (sample_id) VALUES (?)",
                        (s["sample_id"],))

        con.execute(
            """INSERT INTO runs
               (run_id, pipeline_id, started_at, finished_at, exit_status,
                platform, executor, samplesheet, reference, region, folder)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (run_id, pipeline_id, p["started_at"], p["finished_at"],
             p.get("exit_status"), platform.get("kind"), platform.get("executor"),
             params.get("samplesheet"), params.get("ref"), params.get("region"), folder),
        )

        for s in samples_in_manifest:
            con.execute(
                """INSERT INTO run_samples (run_id, sample_id, condition, library_type)
                   VALUES (?, ?, ?, ?)""",
                (run_id, s["sample_id"], s["condition"], s.get("library_type")),
            )

        for v in variants:
            con.execute(
                """INSERT INTO variants (run_id, chrom, pos, ref, alt, qual, filter)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (run_id, v["chrom"], int(v["pos"]), v["ref"], v["alt"],
                 float(v["qual"]), v["filter"]),
            )

        for o in outputs:
            sha256 = o["checksum"].lower().replace("sha256:", "")
            con.execute(
                "INSERT INTO outputs (run_id, path, sha256) VALUES (?, ?, ?)",
                (run_id, o["path"], sha256),
            )

    print(f"{os.path.basename(folder)}/: loaded run_id {run_id}")


def main():
    if len(sys.argv) < 4:
        sys.exit(f"usage: {sys.argv[0]} <database> <metadata.tsv> <run-folder> [<run-folder> ...]")
    db_path, metadata_path, *folders = sys.argv[1:]

    con = sqlite3.connect(db_path)
    con.execute("PRAGMA foreign_keys = ON")

    with con:
        load_metadata(con, metadata_path)

    for folder in folders:
        try:
            load_run(con, folder)
        except sqlite3.Error as e:
            print(f"{os.path.basename(folder)}/: not loaded ({e})", file=sys.stderr)

    con.close()


if __name__ == "__main__":
    main()
