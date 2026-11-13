-- Assignment 9: a database of the pipeline's runs.
PRAGMA foreign_keys = ON;

-- One row per (name, version, implementation): the distinct pipeline builds
-- that produced a run. Several runs can share one pipeline row.
CREATE TABLE pipelines (
    pipeline_id     INTEGER PRIMARY KEY,
    name            TEXT NOT NULL,
    version         TEXT NOT NULL,
    implementation  TEXT NOT NULL,
    UNIQUE (name, version, implementation)
) STRICT;

-- One row per run, from manifest.json's "pipeline", "params" and "platform" blocks.
CREATE TABLE runs (
    run_id          TEXT PRIMARY KEY,
    pipeline_id     INTEGER NOT NULL REFERENCES pipelines(pipeline_id),
    started_at      TEXT NOT NULL,
    finished_at     TEXT NOT NULL,
    exit_status     TEXT,
    platform        TEXT NOT NULL,
    executor        TEXT,
    samplesheet     TEXT,
    reference       TEXT,
    region          TEXT,
    folder          TEXT NOT NULL
) STRICT;

-- One row per sample named anywhere: either in the cohort metadata file, or
-- in a run's manifest that the metadata does not describe (the smoke samples).
-- A sample the metadata does not list gets every column but sample_id as NULL.
CREATE TABLE samples (
    sample_id               TEXT PRIMARY KEY,
    sex                     TEXT,
    population              TEXT,
    family                  TEXT,
    father                  TEXT,
    mother                  TEXT,
    phenotype               TEXT,
    is_synthetic_phenotype  INTEGER
) STRICT;

-- Which samples a run used, and what that run called them: manifest.json's
-- "samples" array, one row per entry. The same sample cannot appear twice in
-- one run - that is exactly what the key below refuses.
CREATE TABLE run_samples (
    run_id          TEXT NOT NULL REFERENCES runs(run_id),
    sample_id       TEXT NOT NULL REFERENCES samples(sample_id),
    condition       TEXT NOT NULL,
    library_type    TEXT,
    PRIMARY KEY (run_id, sample_id)
) STRICT;

-- One row per line of a run's variants.tsv. No single-column INTEGER PRIMARY
-- KEY here on purpose: SQLite still gives every row a rowid, but a declared
-- one would make the row itself look like a plain integer id to anything
-- that inspects the table, which nothing here needs.
CREATE TABLE variants (
    run_id          TEXT NOT NULL REFERENCES runs(run_id),
    chrom           TEXT NOT NULL,
    pos             INTEGER NOT NULL,
    ref             TEXT NOT NULL,
    alt             TEXT NOT NULL,
    qual            REAL NOT NULL,
    filter          TEXT NOT NULL
) STRICT;

-- One row per file in a run's manifest.json "outputs" list. sha256 holds the
-- 64 hex characters only - the manifest's own "sha256:" prefix is stripped
-- before the value reaches this table.
CREATE TABLE outputs (
    run_id          TEXT NOT NULL REFERENCES runs(run_id),
    path            TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    PRIMARY KEY (run_id, path)
) STRICT;
