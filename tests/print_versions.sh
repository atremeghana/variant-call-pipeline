#!/usr/bin/env bash
# print_versions.sh — the version of each pipeline tool, as the tool itself reports it.
#
# Run it twice and compare:
#   in the course conda env:   bash tests/print_versions.sh > cluster-run-container/versions-conda.txt
#   inside your image:         apptainer exec --cleanenv "$SIF" bash tests/print_versions.sh \
#                                  > cluster-run-container/versions-image.txt
#   diff cluster-run-container/versions-conda.txt cluster-run-container/versions-image.txt
#
# It asks each program, rather than reading a package list, because the program
# that runs is the one that matters -- and a package list can name a version the
# program does not have.
v() { printf '%-9s %s\n' "$1" "${2:-NOT FOUND}"; }
v bwa      "$(bwa 2>&1 | awk '/^Version/ { print $2 }')"
v samtools "$(samtools --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
v bcftools "$(bcftools --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
v gatk     "$(gatk --version 2>&1 | awk '/Toolkit/ { sub(/^v/, "", $NF); print $NF }')"
v fastqc   "$(fastqc --version 2>/dev/null | awk '{ sub(/^v/, "", $2); print $2 }')"
v fastp    "$(fastp --version 2>&1 | awk '{ print $2 }')"
v multiqc  "$(multiqc --version 2>/dev/null | awk '{ print $NF }')"
