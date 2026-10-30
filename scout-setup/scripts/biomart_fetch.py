#!/usr/bin/env python3
"""Download Ensembl genes and transcripts for Scout straight from Ensembl BioMart.

    biomart_fetch.py OUT_DIR [--build 38 37]

Writes ensembl_genes_<build>.txt and ensembl_transcripts_<build>.txt in the format of
`scout download ensembl`. That command streams everything through schug.scilifelab.se in
one long request, which keeps breaking on the lab connection; here each chromosome is a
separate small request with retries, and finished chromosomes are kept in OUT_DIR/.biomart
so a rerun continues where it stopped.
"""
import argparse
import os
import sys
import time
import urllib.parse
import urllib.request

CHROMS = [str(c) for c in range(1, 23)] + ["X", "Y", "MT"]
# Mirrors are tried in turn; www.ensembl.org may redirect to a regional mirror that is down.
MART = {"38": ["https://useast.ensembl.org/biomart/martservice",
               "https://www.ensembl.org/biomart/martservice",
               "https://asia.ensembl.org/biomart/martservice"],
        "37": ["https://grch37.ensembl.org/biomart/martservice"]}

# (biomart attribute, header Scout's parser recognises)
GENES = [("chromosome_name", "Chromosome/scaffold name"),
         ("start_position", "Gene start (bp)"),
         ("end_position", "Gene end (bp)"),
         ("ensembl_gene_id", "Gene stable ID"),
         ("hgnc_symbol", "HGNC symbol"),
         ("hgnc_id", "HGNC ID")]
TRANSCRIPTS = [("chromosome_name", "Chromosome/scaffold name"),
               ("ensembl_gene_id", "Gene stable ID"),
               ("ensembl_transcript_id", "Transcript stable ID"),
               ("transcript_start", "Transcript start (bp)"),
               ("transcript_end", "Transcript end (bp)"),
               ("refseq_mrna", "RefSeq mRNA ID"),
               ("refseq_mrna_predicted", "RefSeq mRNA predicted ID"),
               ("refseq_ncrna", "RefSeq ncRNA ID")]
MANE = [("transcript_mane_select", "RefSeq match transcript (MANE Select)"),
        ("transcript_mane_plus_clinical", "RefSeq match transcript (MANE Plus Clinical)")]


def query(attrs, chrom, unique):
    a = "".join('<Attribute name="%s"/>' % n for n, _ in attrs)
    return ('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE Query>'
            '<Query virtualSchemaName="default" formatter="TSV" header="0" uniqueRows="%d" '
            'datasetConfigVersion="0.6" completionStamp="1">'
            '<Dataset name="hsapiens_gene_ensembl" interface="default">'
            '<Filter name="chromosome_name" value="%s"/>%s</Dataset></Query>' % (unique, chrom, a))


def fetch_chrom(urls, attrs, chrom, unique, part, tries=9):
    if os.path.exists(part):
        return
    # GET, not POST: www.ensembl.org redirects to a regional mirror, and a redirected POST
    # arrives as a bare GET (HTTP 405)
    q = urllib.parse.urlencode({"query": query(attrs, chrom, unique)})
    for t in range(1, tries + 1):
        url = urls[(t - 1) % len(urls)]
        full = url + "?" + q
        try:
            with urllib.request.urlopen(full, timeout=600) as r:
                text = r.read().decode("utf-8")
            if text.startswith("Query ERROR"):
                sys.exit("BioMart отклонил запрос: %s" % text[:300])
            lines = text.rstrip("\n").split("\n")
            if lines and lines[-1] == "[success]":
                with open(part + ".tmp", "w") as fh:
                    fh.write("\n".join(lines[:-1]) + ("\n" if len(lines) > 1 else ""))
                os.replace(part + ".tmp", part)
                print("   chr%s: %d строк" % (chrom, len(lines) - 1), flush=True)
                return
            print("   chr%s: %s не отвечает (%s), повтор %d/%d" % (chrom, url.split("/")[2], " ".join(text[:200].split())[:60], t, tries), flush=True)
        except Exception as e:  # network drops, timeouts, 5xx
            print("   chr%s: %s: %s, повтор %d/%d" % (chrom, url.split("/")[2], e, t, tries), flush=True)
        time.sleep(min(10 * t, 90))
    sys.exit("chr%s не скачалась за %d попыток (%s)" % (chrom, tries, ", ".join(urls)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--build", nargs="+", default=["38", "37"])
    a = ap.parse_args()
    cache = os.path.join(a.out_dir, ".biomart")
    os.makedirs(cache, exist_ok=True)
    for build in a.build:
        for kind, attrs, unique in (("genes", GENES, 1),
                                    ("transcripts", TRANSCRIPTS + (MANE if build == "38" else []), 0)):
            out = os.path.join(a.out_dir, "ensembl_%s_%s.txt" % (kind, build))
            if os.path.exists(out) and os.path.getsize(out) > 0:
                print(">> %s: уже есть" % os.path.basename(out))
                continue
            print(">> Ensembl GRCh%s %s (по хромосомам)" % (build, kind), flush=True)
            parts = []
            for c in CHROMS:
                part = os.path.join(cache, "%s_%s_%s.tsv" % (kind, build, c))
                fetch_chrom(MART[build], attrs, c, unique, part)
                parts.append(part)
            with open(out + ".tmp", "w") as fh:
                fh.write("\t".join(h for _, h in attrs) + "\n")
                for p in parts:
                    with open(p) as ph:
                        fh.write(ph.read())
            os.replace(out + ".tmp", out)
            print(">> готово: %s" % out, flush=True)


if __name__ == "__main__":
    main()
