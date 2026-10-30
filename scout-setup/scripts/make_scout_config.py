#!/usr/bin/env python3
"""Build a Scout load config (case YAML) from an archived nf-core/raredisease 3.1.2 run.

    make_scout_config.py RUN_DIR [-o case.yaml] [--institute nefu_mmhg_arcgen] [--panel OMIM-AUTO] [--threshold 5]

RUN_DIR is the archive folder D:\\data_annotated\\<date>_<code>_<sex> (Windows form or /mnt/d/...).
Only paths are written; nothing is copied. Sample and case IDs come from the pipeline's
pedigree file, so they are lab codes, never patient names.
"""
import argparse
import datetime as dt
import glob
import os
import re
import sys

import yaml


def linux_path(p):
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", p)
    if m:
        return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2).replace("\\", "/"))
    return p


def first(pattern, exclude=None):
    hits = sorted(h for h in glob.glob(pattern, recursive=True) if not (exclude and re.search(exclude, h)))
    return hits[0] if hits else None


def read_ped(path):
    samples, family = [], None
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            fam, sid, father, mother, sex, pheno = line.split("\t")[:6]
            family = fam
            samples.append(dict(
                sample_id=sid,
                sample_name=sid,
                father=father if father not in ("", "0") else "0",
                mother=mother if mother not in ("", "0") else "0",
                sex={"1": "male", "2": "female"}.get(sex.strip(), "unknown"),
                phenotype={"2": "affected", "1": "unaffected"}.get(pheno.strip(), "unknown"),
                analysis_type="wgs",
            ))
    return family, samples


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("-o", "--out")
    ap.add_argument("--institute", default="nefu_mmhg_arcgen")
    ap.add_argument("--panel", default="OMIM-AUTO", help="default gene panel shown when the case opens")
    ap.add_argument("--threshold", type=float, default=5,
                    help="load clinical SNVs with RankScore above this (ClinVar pathogenic and MT are always loaded)")
    a = ap.parse_args()

    run = linux_path(a.run_dir.rstrip("/\\"))
    proc = os.path.join(run, "processed")
    raw = os.path.join(run, "raw")
    # `ngs archive` puts pipeline outputs one level deeper: processed/results/
    if os.path.isdir(os.path.join(proc, "results", "pedigree")):
        proc = os.path.join(proc, "results")
    if not os.path.isdir(proc):
        sys.exit("нет папки processed в %s" % run)

    ped = first(proc + "/pedigree/*.ped")
    if not ped:
        sys.exit("нет pedigree/*.ped в %s" % proc)
    family, samples = read_ped(ped)

    rf = proc + "/rank_and_filter"
    snv_res = first(rf + "/*_snv_ranked_research.vcf.gz")
    snv_cli = first(rf + "/*_snv_ranked_clinical.vcf.gz") or first(proc + "/clinical*/*_snv_ranked_clinical*.vcf.gz")
    sv_res = first(rf + "/*_sv_ranked_research.vcf.gz")
    sv_cli = first(rf + "/*_sv_ranked_clinical.vcf.gz")
    mt_res = first(rf + "/*_mt_ranked_research.vcf.gz")
    mt_cli = first(rf + "/*_mt_ranked_clinical.vcf.gz")

    cfg = dict(
        owner=a.institute,
        family=family,
        family_name=family.replace("case_", "", 1),
        human_genome_build="38",
        rank_score_threshold=a.threshold,
        rank_model_version="raredisease-3.1.2-stock",
        sv_rank_model_version="raredisease-3.1.2-stock",
        gene_panels=[a.panel],
        default_gene_panels=[a.panel],
        samples=samples,
    )
    # A clinical set (OMIM genes) is what the case opens with; the full research set is loaded
    # on request from the case page. Without a clinical set the research file is used as clinical.
    cfg["vcf_snv"] = snv_cli or snv_res
    if snv_cli and snv_res:
        cfg["vcf_snv_research"] = snv_res
    cfg["vcf_sv"] = sv_cli or sv_res
    if sv_cli and sv_res:
        cfg["vcf_sv_research"] = sv_res
    cfg["vcf_snv_mt"] = mt_cli or mt_res
    cfg["vcf_str"] = first(proc + "/repeat_expansions/*stranger.vcf.gz")
    cfg["peddy_ped"] = first(proc + "/peddy/*.peddy.ped")
    cfg["peddy_check"] = first(proc + "/peddy/*.ped_check.csv")
    cfg["peddy_sex"] = first(proc + "/peddy/*.sex_check.csv")
    cfg["smn_tsv"] = first(  # Scout reads SMN1/SMN2 copy numbers from it itself
        proc + "/smncopynumbercaller/**/*_smncopynumbercaller.tsv")
    cfg["multiqc"] = first(proc + "/multiqc/multiqc_report.html")

    info = first(proc + "/pipeline_info/execution_report_*.html")
    m = info and re.search(r"(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})", info)
    cfg["analysis_date"] = (dt.datetime.strptime("".join(m.groups()), "%Y-%m-%d%H%M%S") if m
                            else dt.datetime.now().replace(microsecond=0))

    for s in samples:
        sid = s["sample_id"]
        bam = (first(proc + "/alignment/%s*.bam" % sid, exclude=r"mt_subsample")
               or first(raw + "/**/%s*.bam" % sid, exclude=r"mt_subsample"))
        cram = first(proc + "/alignment/%s*.cram" % sid) or first(raw + "/**/%s*.cram" % sid)
        s["alignment_path"] = bam or cram
        s["mt_bam"] = first(proc + "/alignment/%s_mt_subsample.bam" % sid)
        s["rhocall_bed"] = first(proc + "/annotate_snv/genome/%s_rhocallviz/*.bed" % sid)
        s["rhocall_wig"] = first(proc + "/annotate_snv/genome/%s_rhocallviz/*.wig" % sid)
        s["tiddit_coverage_wig"] = first(proc + "/qc_bam/%s_tidditcov.wig" % sid)
        chrom = {}
        if first(proc + "/annotate_snv/genome/%s_rhocallviz_chr1.png" % sid):
            chrom["autozygous"] = proc + "/annotate_snv/genome/%s_rhocallviz_chr" % sid
        if first(proc + "/qc_bam/%s_tidditcov_chr1.png" % sid):
            chrom["coverage"] = proc + "/qc_bam/%s_tidditcov_chr" % sid
        if chrom:
            s["chromograph_images"] = chrom
        for k in [k for k, v in s.items() if v is None]:
            del s[k]
        if "alignment_path" not in s:
            print("!! %s: BAM/CRAM не найден, IGV в Scout будет без чтений" % sid, file=sys.stderr)

    for k in [k for k, v in cfg.items() if v is None]:
        del cfg[k]
    # Scout silently loads 0 variants from a VCF without an index
    for k, v in cfg.items():
        if k.startswith("vcf_") and not (os.path.exists(v + ".tbi") or os.path.exists(v + ".csi")):
            sys.exit("нет индекса %s.tbi: сделайте tabix -p vcf %s" % (v, v))
    if not snv_cli:
        print("!! клинического набора SNV нет: в Scout пойдёт research-файл с порогом RankScore > %g"
              % a.threshold, file=sys.stderr)

    out = a.out or os.path.join(run, "scout_case.yaml")
    with open(out, "w") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True)
    print(out)


if __name__ == "__main__":
    main()
