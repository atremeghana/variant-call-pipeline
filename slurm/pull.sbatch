#!/bin/bash
#SBATCH -A binf6610.202710 -p courses
#SBATCH -c 4 --mem=16G -t 00:30:00
#SBATCH -o pull-%j.out
set -euo pipefail
export APPTAINER_CACHEDIR=/scratch/${USER}/apptainer-cache
mkdir -p /scratch/${USER}/containers
apptainer pull --force /scratch/${USER}/containers/variant-call.sif \
    docker://atremeghana/variant-call@sha256:9fecb0cbe58d43fe4040d29188ebdefb0cc66a64fd5d560d49855d333395dc6c
