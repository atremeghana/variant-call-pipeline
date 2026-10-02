#!/bin/bash
echo "bwa       $(bwa 2>&1 | grep -oP 'Version: \K[^\s]+')"
echo "samtools  $(samtools --version | head -1 | awk '{print $2}')"
echo "bcftools  $(bcftools --version | head -1 | awk '{print $2}')"
echo "gatk4     $(gatk --version 2>&1 | grep -oP 'v\K[0-9.]+')"
echo "fastqc    $(fastqc --version | awk '{print $2}')"
echo "fastp     $(fastp --version 2>&1 | awk '{print $2}')"
echo "multiqc   $(multiqc --version | awk '{print $3}')"
