## Base image

mambaorg/micromamba:2.0.5-ubuntu24.04
mambaorg/micromamba@sha256:1c62a28916ad7a4533555a542a5410e55ea2ed2c1e29f00c8fc3f1c8add111d5

## Versions pinned

bwa=0.7.19 samtools=1.24 bcftools=1.24 gatk4=4.6.2.0 fastqc=0.12.1 fastp=1.3.7 multiqc=1.35 git=2.47.1

## The pushed image

docker.io/atremeghana/variant-call@sha256:9fecb0cbe58d43fe4040d29188ebdefb0cc66a64fd5d560d49855d333395dc6c

To rerun this in a year: pull the image by the digest above (tags can move, digests cannot) with
docker pull docker.io/atremeghana/variant-call@sha256:9fecb0cbe58d43fe4040d29188ebdefb0cc66a64fd5d560d49855d333395dc6c,
or rebuild from containers/variant-call/Dockerfile, which pins every tool to an exact version and
the base image to an exact tag.
