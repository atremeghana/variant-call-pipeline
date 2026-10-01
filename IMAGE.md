# Container image

**Image:** `atremeghana/variant-call:1.0.0`
**Digest:** `sha256:8f91395ea44b4a8d29be94cd0fcf76dfefb92317854925775c235ac963930751`

Pull by digest (tags can move, digests cannot):

    docker pull atremeghana/variant-call@sha256:8f91395ea44b4a8d29be94cd0fcf76dfefb92317854925775c235ac963930751

## Pinned tool versions

| Tool | Version |
|---|---|
| bwa | 0.7.19-r1273 |
| samtools | 1.24 |
| bcftools | 1.24 |
| gatk4 | 4.6.2.0 |
| fastqc | 0.12.1 |
| fastp | 1.3.7 |
| multiqc | 1.35 |
| git | 2.56.0 |

Built from `containers/variant-call/Dockerfile`, base image `mambaorg/micromamba:2.0.5-ubuntu24.04`,
`--platform linux/amd64`. Verified via `docker image inspect --format '{{.Architecture}}'` = `amd64`.
