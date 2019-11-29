import pandas as pd

configfile: "configs/config_rn.yaml"

rule series_matrices_seq_download:
    '''
    Takes search output .txt, parses out all links and downloads them. 
    (wget -nc) Existing up to date files out dir doesn't reload. To update  database just remove complete flag file. 
    '''
    input:
        config["geo_search_result_chip"]
    resources:
        download_res=1,
        writing_res=1,
        mem_ram=2
    output:
        sm_dir=directory("out/series_matrices/seq/"),
        complete_flag="out/flags/series_matrices_seq_download"
    shell:
        "scripts/bash/download_sm.sh {input} {output.sm_dir} && "
        "touch {output.complete_flag}"

rule sm_seq_metadata:
    input:
        rules.series_matrices_seq_download.output.sm_dir
    output:
        gsm_df="out/data/metadata/seq/gsm.tsv",
        gse_df="out/data/metadata/seq/gse.tsv"
    shell:
        "python scripts/python/parse_sm_metadata.py {input} {output.gse_df} {output.gsm_df}"

rule sra_accession_df_download:
    resources:
        download_res=1,
        writing_res=1,
        mem_ram=2
    output:
        temp("out/data/sra_accession_raw.tab")
    shell:
        "wget -O {output} {config[sra_accession_df]}"

rule get_srr_df:
    resources:
        writing_res=1
    input:
        rules.sra_accession_df_download.output
    output:
        srr_df="out/data/srr_gsm_spots.tsv"
    conda: "envs/r_scripts.yaml"
    shell:
        "scripts/bash/clean_sra_accession_df.sh {input} {output.srr_df} &&"
        " Rscript scripts/R/clean_sra_accession_df.R {output.srr_df}"

checkpoint prequant_filter:
    '''
    '''
    message: "Pre-quantification filtering... "
    input:
        srr_df=rules.get_srr_df.output.srr_df,
        gse_df=rules.sm_seq_metadata.output.gse_df,
        gsm_df=rules.sm_seq_metadata.output.gsm_df,
        gpl_df=config["gpl_df"]
    output:
        gsm_gse_df="out/data/filtering/prequant/gsm_gse.tsv",
        gsm_filtering_df="out/data/filtering/prequant/gsm_filtering.tsv",
        passing_gsm_list="out/data/filtering/prequant/passing_gsm.list",
        srr_gsm_df="out/data/filtering/prequant/srr_gsm.tsv"
    shell:
        "Rscript scripts/R/prequant_filter.R {input.gse_df} {input.gsm_df} {input.gpl_df} {input.srr_df}"
        " {config[organism]} {config[min_spots_gsm]} {config[max_spots_gsm]} {config[quant_min_gsm]} "
        " {config[quant_max_gsm]} {output.gsm_filtering_df} {output.passing_gsm_list} {output.srr_gsm_df}"
        " {output.gsm_gse_df}"



rule sra_download:
    resources:
        download_res=1,
        writing_res=1,
        mem_ram=2
    output: temp("out/sra/{srr}.sra")
    log:    "out/sra/{srr}.log"
    message: "Downloading {wildcards.srr}"
    shadow: "shallow"
    conda: "envs/quantify.yaml"
    shell:
        "scripts/bash/download_sra.sh {wildcards.srr} {output} > {log} 2>&1"

rule sra_fastqdump:
    resources:
        writing_res=1
    input:
        "out/sra/{srr}.sra"
    output:
        fastq_dir=temp(directory("out/fastq/{srr}")),
        complete_flag=temp("out/fastq/{srr}_complete")
    log:    "out/fastq/{srr}.log"
    message: "fastq-dump {wildcards.srr}"
    conda: "envs/quantify.yaml"
    shell:
        "fastq-dump --outdir {output.fastq_dir} --split-3 {input} >{log} 2>&1 &&"
        "touch {output.complete_flag}"

rule fastq_kallisto:
    resources:
        mem_ram=4
    input:
        rules.sra_fastqdump.output.complete_flag,
        fastq_dir="out/fastq/{srr}"
    output:
        h5=protected("out/kallisto/{srr}/abundance.h5"),
        tsv=protected("out/kallisto/{srr}/abundance.tsv"),
        json=protected("out/kallisto/{srr}/run_info.json")
    log: "out/kallisto/{srr}/{srr}.log"
    message: "Kallisto: {wildcards.srr}"
    conda: "envs/quantify.yaml"
    shadow: "shallow"
    shell:
        "scripts/bash/quantify.sh {wildcards.srr} {input.fastq_dir} "
        " {config[refseq]} out/kallisto/{wildcards.srr} >{log} 2>&1"

def get_srr_files(wildcards):
    srr_df_file = checkpoints.prequant_filter.get(**wildcards).output.srr_gsm_df
    srr_df = pd.read_csv(srr_df_file, sep="\t")
    srr_list = srr_df[srr_df['GSM']==wildcards.gsm]["SRR"].tolist()
    srr_files = expand("out/kallisto/{srr}/abundance.tsv", srr=srr_list)
    print(srr_files)
    return srr_files

rule srr_to_gsm:
    resources:
        mem_ram=1
    input:
        get_srr_files
    output: "out/gsms/{gsm}.tsv"
    log: "out/gsms/{gsm}.log"
    message: "Aggregating GSM {wildcards.gsm}"
    shadow: "shallow"
    conda: "envs/r_scripts.yaml"
    shell:
        "Rscript scripts/R/srr_to_gsm.R {wildcards.gsm}"
        " {config[probes_to_genes]} {input}"


def get_prequant_filtered_gsm(wildcards):
    filtered_gsm_list = checkpoints.prequant_filter.get(**wildcards).output.passing_gsm_list
    gsms = [line.rstrip('\n') for line in open(filtered_gsm_list)]
    gsm_files = expand("out/gsms/{gsm}.tsv", gsm=gsms)
    return gsm_files

def get_gsm_gse_df(wildcards):
    return checkpoints.prequant_filter.get(**wildcards).output.gsm_gse_df

checkpoint postquant_filter:
    resources:
        mem_ram=2
    input:
        gsm_files=get_prequant_filtered_gsm,
        gsm_gse_df=get_gsm_gse_df
    output:
        gsm_stats_df="out/data/filtering/postquant/gsm_stats.tsv",
        gsm_gse_df="out/data/filtering/postquant/gse_gsm.tsv",
        passing_gse_list="out/data/filtering/postquant/passing_gse.list"
    shell:
        "Rscript scripts/R/postquant_filter.R {config[quant_min_gsm]} {config[min_exp_genes]} {input.gsm_gse_df}"
        "{output.gsm_stats_df} {output.gsm_gse_df} {output.passing_gse_list}"
        "{input.gsm_files}"


def get_postquant_gsms_for_gse(wildcards):
    gsm_gse_df_file = checkpoints.postquant_filter.get(**wildcards).output.gse_gsm_df
    gsm_gse_df = pd.read_csv(gsm_gse_df_file, sep="\t")
    gsms = gsm_gse_df[gsm_gse_df['GSE']==wildcards.gse]["GSM"].tolist()
    gsm_files = expand("out/gsms/{gsm}.tsv", gsm=gsms)
    return gsm_files


rule gsm_to_gse:
    input:
        get_postquant_gsms_for_gse
    output:
        gse="out/gses/{gse}.tsv"
    log: "out/gses/{gse}.log"
    message: "Aggregating GSE"
    shadow: "shallow"
    conda: "envs/r_scripts.yaml"
    shell:
        "Rscript scripts/gsm_to_gse.R {output} out/gsms"
        " {config[ensamble_genesymbol_entrez]} "
        " {input.gse_filtered_df}"


def get_postquant_filter_gses(wildcards):
    filtered_gse_list = checkpoints.postquant_filter.get(**wildcards).output.gse_filtered_list
    gses = [line.rstrip('\n') for line in open(filtered_gse_list)]
    gse_files = expand("out/gses/{gsm}.tsv", gsm=gses)
    return gse_files


rule push_filtered_gses:
    input:
        get_postquant_filter_gses
    output:
        flag="out/flag"
    shell:
        "touch {output.flag}"


# def get_filtered_gses(wildcards):
#     gse_filtered_path = checkpoints.get_gsm_stats.get(**wildcards).output.gse_filtered_df
#     gse_gsm_df = pd.read_csv(gse_filtered_path, sep="\t")
#     gses = list(set(gse_gsm_df["gse"].tolist()))
#     gse_files = ["out/gses/" + gse + ".tsv" for gse in gses]
#     return gse_files

# rule push_filtered_gses:
#     input:
#         get_filtered_gses
#     output:
#         flag="out/flag"
#     shell:
#         "touch {output.flag}"


