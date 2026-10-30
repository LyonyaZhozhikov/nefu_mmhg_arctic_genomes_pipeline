# nf-core/raredisease on a local machine: WGS, GRCh38, Yakut cohort

Starter kit for running **nf-core/raredisease 3.1.2** (latest release, 2026-07-06) on whole genomes from one
workstation with Docker. Everything was checked against the 3.1.2 source code (`docs/usage.md`,
`nextflow_schema.json`, `conf/modules/*.config`). Nothing has been run yet on real data.

## What is in this folder

| File | What it is |
| --- | --- |
| `params_grch38_wgs.yaml` | All pipeline parameters for a GRCh38 WGS run. Edit paths, then pass with `-params-file`. |
| `conf/local.config` | Machine settings: CPU/RAM limits, Docker, temp dir, keeps DeepVariant gVCFs. Pass with `-c`. |
| `conf/vep_extended.config` | Optional: adds ClinVar, REVEL and conservation scores to VEP so the rank model can use them. |
| `samplesheets/trio.csv`, `singleton.csv`, `bam_input.csv` | Example samplesheets (FASTQ trio, FASTQ singleton, BAM input). |
| `scripts/download_references.sh` | Downloads and prepares all GRCh38 references (re-runnable). |
| `scripts/make_interval_lists.sh` | Builds Picard interval lists that match your reference (called by the download script). |
| `scripts/make_gnomad_af.sh` | Shrinks gnomAD v4.1 genomes to an AF-only VCF and the `gnomad_af` tab file. |
| `scripts/build_yakut_af.sh` | Builds the in-house **Yakut allele-frequency VCF** from DeepVariant gVCFs. |
| `scripts/build_yakut_svdb.sh` | Builds the in-house **Yakut SV frequency database** with SVDB. |
| `references/` | Ready-made files: Yakut-adapted rank models, vcfanno TOML, SVDB/VEP/ME sheets, ExpansionHunter catalog, PAR bed, Manta regions, ME region beds. |

## 1. Machine

Numbers below are estimates from the pipeline's resource labels, not measured runs.

| | Recommended | Minimum |
| --- | --- | --- |
| CPU | 32 cores | 16 cores |
| RAM | 128 GB | 64 GB (then set `aligner: "bwa"`: building the bwa-mem2 GRCh38 index needs ~90 GB) |
| Disk | 2 TB+ fast local disk | references ~350 GB, plus ~0.5 TB working space per 30x genome while it runs |
| OS | Linux (Ubuntu 22.04/24.04 etc.) with Docker | |

The heaviest standard steps ask for 12 CPUs / 72 GB (`process_high`). `conf/local.config` caps every task at
your machine's limits via `resourceLimits`, so set the three numbers there to match `nproc` and `free -g`.

## 2. Software

```bash
# Java 17+ and Nextflow >= 25.10.4 (required by 3.1.2)
curl -s https://get.nextflow.io | bash && sudo mv nextflow /usr/local/bin/
# Docker: install Docker Engine, then let your user run it
sudo usermod -aG docker $USER    # log out and back in
# Pull the pipeline and run the built-in test (small, a few minutes to an hour)
nextflow pull nf-core/raredisease -r 3.1.2
nextflow run nf-core/raredisease -r 3.1.2 -profile test,docker --outdir test_results
```

If the test run passes, Docker, Nextflow and network access to the container registries all work.

## 3. Reference files (GRCh38)

```bash
bash scripts/download_references.sh /data/raredisease/references/grch38
```

The script uses `/data/raredisease/...` everywhere. If you choose another location, change the paths in
`params_grch38_wgs.yaml`, `references/vcfanno_resources.txt`, `svdb_query_dbs*.csv`, `vep_files*.csv` and
`mobile_element_references.tsv`.

What it sets up, and the choices made:

- **Genome**: NCBI `GCA_000001405.15_GRCh38_no_alt_analysis_set` (no ALT contigs, chrM as 25th contig, as the
  pipeline requires). The interval lists that ship with the pipeline have a header for the 3366-contig
  GRCh38+ALT+decoy+HLA reference, which Picard rejects for this genome, so the script builds matching ones.
- **VEP 110 merged cache**. The pipeline's VEP is 110.1 and runs with `--merged`, so `vep_cache_version: 110`
  (the pipeline default of 112 would not match the container).
- **gnomAD v4.1 genomes** reduced to `AF, AF_grpmax, AC, nhomalt, AF_eas`. `AF_grpmax` is renamed
  `GNOMADAF_popmax` because the pipeline's hard filter (drop variants with gnomAD AF > 0.70) reads that exact key.
- **gnomAD mito v3.1, gnomAD SV v4.1, CADD v1.7** (chr-prefixed so contigs match), **ClinVar** (chr-prefixed).
- **ExpansionHunter catalog** with pathogenicity data from Clinical Genomics Stockholm (51 loci, includes
  ATXN1, DMPK, PABPN1, ATXN2/3, HTT, FMR1, C9ORF72, RFC1).
- **Rank models**: Clinical Genomics' production GRCh38 SNV v0.4 and SV v0.2 models, adapted (see section 6).

Two downloads need your login or licence choice and are not scripted: SpliceAI precomputed scores (Illumina
BaseSpace) and dbNSFP 4.9a (academic licence, only needed for `conf/vep_extended.config`).

## 4. Samplesheet

One row per FASTQ pair. Same `sample` on several rows = several lanes/runs of one person (merged after alignment).

- `sex`: 1 male, 2 female, 0 unknown. `phenotype`: 1 unaffected, 2 affected.
- `paternal_id` / `maternal_id`: sample IDs of parents in the same sheet, `0` otherwise.
- `case_id`: family ID; all members of a family share it and are jointly genotyped together.
- Paths must be absolute and end in `.fastq.gz` / `.fq.gz`.
- Sex matters beyond QC: DeepVariant calls chrX/chrY as haploid in males, and `grch38_par.bed` keeps the
  pseudo-autosomal regions diploid.

Trios and singletons both work with the same params file; inheritance models (de novo, compound het, AR hom)
are only scored when parents are in the case.

## 5. Running

```bash
nextflow run nf-core/raredisease -r 3.1.2 -profile docker \
    -c conf/local.config \
    -params-file params_grch38_wgs.yaml \
    -resume
# with richer VEP annotation (after getting dbNSFP + setting vep_plugin_files to vep_files_extended.csv):
#   -c conf/local.config -c conf/vep_extended.config
```

- Run inside `screen`/`tmux`, or add `-bg`.
- First run has `save_reference: true`, so the bwa-mem2 index and other generated indices are written to
  `results/references/`. Move them next to your references, set `bwamem2:` (and friends) in the params file, and set
  `save_reference: false` so later runs skip index building.
- One family per run is simplest: one samplesheet + one `outdir` per family. Keep the `work/` dir until the run
  is finished and checked, then delete it (it is large).

### What is switched off at first and why

| Off | Why | To turn on |
| --- | --- | --- |
| `germlinecnvcaller` | GATK gCNV needs a cohort model trained on your own samples (same library prep). | After ~30-50 genomes, build models with nf-core/createpanelrefs, set `ploidy_model`, `gcnvcaller_model`, `readcount_intervals`. CNVnator and Tiddit still call CNVs/SVs meanwhile. |
| `gens` | Needs a panel of normals from your samples. | Same as above. |
| `vcf2cytosure` | Only for the CytoSure array viewer. | Leave off unless you use it. |
| `generate_clinical_set` | Needs a gene list (HGNC IDs) to split clinical vs research variants. | Make `panel_hgnc_ids.txt` (one HGNC ID per line), set `vep_filters`. |
| `me_annotation` | Mobile-element frequency annotation needs a population ME database. Mobile element *calling* stays on. | Build one from your cohort with SVDB like the SV database, set `mobile_element_svdb_annotations`. |

## 6. Yakut-specific points

**Why gnomAD alone is not enough.** gnomAD has no Siberian or Yakut group. Yakut genomes are mostly
East-Eurasian/Siberian with some West-Eurasian admixture, so `GNOMADAF_eas` is the nearest proxy and is kept for
review, but it misses variants that drifted to high frequency in the Yakut founder population. Those variants look
"absent from gnomAD" and get the top rare-variant score, which floods candidate lists. A local allele-frequency
database is the fix, and raredisease already supports it through vcfanno (SNVs/indels) and SVDB (SVs).

**How the Yakut database plugs in (already wired in these files):**

1. Each run keeps per-sample DeepVariant gVCFs in `results/deepvariant_gvcf/` (`conf/local.config`).
2. `scripts/build_yakut_af.sh` joint-genotypes the gVCFs of **unrelated** individuals (unaffected trio parents,
   unrelated singletons) with GLnexus and writes a sites-only `yakut_cohort_af.vcf.gz` with `AF, AC, AN, AC_Hom`.
3. vcfanno adds these as `YAKUT_AF`, `YAKUT_AC`, `YAKUT_AN`, `YAKUT_AC_Hom` (`references/vcfanno_config_grch38_yakut.toml`).
4. The rank model's `[yakut]` section scores `YAKUT_AF` in the `allele_frequency` category, which is aggregated by
   **minimum**: a variant common in Yakuts (AF ≥ 2%) gets −12 even if gnomAD has never seen it.
5. For SVs, `scripts/build_yakut_svdb.sh` builds an SVDB database from founders' SV VCFs; switch the params file to
   `svdb_query_dbs_with_yakut.csv` and the SV rank model's `[yakut_sv]` section scores `yakut_svAF`.

Until the cohort file exists, an empty placeholder is used and `run_vcfanno_db_sanity_check: true` drops it, so
runs work from day one. Rebuild the file every time a batch of new founders is added and record the sample
count (the script writes `yakut_cohort_af.README`).

**Cohort size and thresholds.** With N founders the smallest non-zero AF is 1/(2N). The inherited rank thresholds
(very rare < 0.0005, rare < 0.005, common ≥ 0.02) were set for large reference sets. With 100 founders a single
observation is already AF 0.005 ("intermediate"). Until the cohort has several hundred unrelated people, read
`YAKUT_AC` / `YAKUT_AC_Hom` next to the score rather than relying on the AF bins, and consider widening the
`[yakut]` bins in `rank_model_snv_grch38_yakut.ini`.

**Founder pathogenic variants: don't let the local database hide them.** Some disease alleles are frequent in
Yakuts precisely because of founder effects. Literature on the Sakha Republic reports, for example, GJB2
c.-23+1G>A (recessive hearing loss), a CUL7 frameshift (3-M syndrome / "Yakut short stature"), NBAS p.R1914H
(SOPH syndrome), CYB5R3 variants (recessive congenital methaemoglobinaemia), and high SCA1 (ATXN1) and DM1 (DMPK)
prevalence. A common-in-Yakut pathogenic SNV would receive −12 from the frequency category. Two safeguards:

- Keep a curated `yakut_known_pathogenic.vcf.gz` of lab-confirmed founder variants and enable the commented
  vcfanno block in the TOML (adds a `YAKUT_KNOWN_PATHOGENIC` flag), then check flagged variants in every case
  regardless of rank score. Verify each variant's GRCh38 coordinates against ClinVar/your Sanger data before
  adding it; the list above is from memory of the literature and is not a curated set.
- Repeat expansions (ATXN1, DMPK, PABPN1 etc.) are not affected by frequency ranking: ExpansionHunter + Stranger
  report them separately in `repeat_expansions/`.

**Runs of homozygosity / UPD.** `bcftools roh` and UPD detection read population AFs from `gnomad_af`. Once the
Yakut cohort is a few hundred people, you can build a Yakut tab file (one-liner at the end of
`build_yakut_af.sh`) and point `gnomad_af` at it for ROH estimates better matched to the population. ROH regions
are especially useful for finding homozygous founder variants in affected children of unrelated-looking parents.

**Bootstrapping the reference with public Yakut genomes.** The HGDP high-coverage WGS set (GRCh38, public)
includes a small number of Yakut individuals (about 25; check the sample list). Running them through the same
DeepVariant settings and adding their gVCFs to `build_yakut_af.sh` gives the database a starting point before your
own cohort grows. RUSeq (Russian exome frequencies, ruseq.ru) is browsable but the VCF is only available on
request, and it has no explicitly Yakut samples.

**Privacy.** `yakut_cohort_af.vcf.gz` contains only site-level counts and is the file to share or publish; keep
the multi-sample `yakut_cohort.bcf` with genotypes inside the lab.

## 7. Not verified yet

These were checked by reading the code or syntax only (no bcftools or Docker in the environment where this was
written). Watch for them on the first real run:

- `conf/local.config` re-enables `publishDir` for DeepVariant gVCFs on top of the pipeline's "publish nothing by
  default" rule. If `results/deepvariant_gvcf/` does not appear, the gVCFs are still in `work/`.
- `pLI_values.txt` and `LoFtool_scores.txt` are expected in the VEP_plugins repo; the script warns if not.
- dbNSFP column names (`GERP++_RS` etc.) differ between dbNSFP versions; check them before using `vep_extended.config`.
- The CADD annotation tarball layout must match what the pipeline's CADD module expects (`cadd_resources`).

## Sources

- nf-core/raredisease 3.1.2 source and docs: https://github.com/nf-core/raredisease (tag 3.1.2)
- Clinical Genomics Stockholm reference files (rank models, catalogs, regions): https://github.com/Clinical-Genomics/reference-files
- RUSeq, Russian allele frequency reference: https://pmc.ncbi.nlm.nih.gov/articles/PMC11533896
- Yakut WGS for personalized medicine (CHW 2021): https://atlantis-press.com/proceedings/chw-21/125968743
- GJB2 variants in the Sakha Republic: https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0156300
- Population structure of Sakha (Yakutia): https://link.springer.com/article/10.1186/1471-2148-13-127
