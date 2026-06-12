# Data Preparation And Analysis Scripts

The `scripts/` directory contains two related workflows:

1. scripts `0` through `6` prepare the files stored in `data/<STATE>/`;
2. scripts `7a` and `7b` ingest and explore completed simulation outputs.

The repository-level `scripts/README.md` is the working provenance record.
Update it when a source dataset, release year, assumption, or generated
filename changes.

## State Input Pipeline

Open `scripts/scripts.Rproj` in RStudio and run
`0_generate_US-State_inputs.R` to orchestrate the input pipeline. Some source
datasets are large, require credentials, or live outside this repository, so
the scripts can also be run individually.

| Step | Script | Primary result |
| --- | --- | --- |
| 1 | `1_county_age_pop_totals.R` | State directories, county population-by-age files, and initial-infection candidates. |
| 2 | `2_epydemix_contact_matrix_generation.py` | State age-contact matrices from Epydemix/Mistry data. |
| 3a | `3a_ct_ak_crosswalks.R` | Geography crosswalks for Connecticut and Alaska boundary changes. |
| 3b | `3b_county_mobility_timeseries_post2020census.R` | County mobility time series, quarterly matrices, and connectivity rankings. |
| 4a | `4a_flu_state_high_risk_by_age.R` | State-and-age influenza high-risk proportions from BRFSS and NSCH. |
| 4b | `4b_flu_county_high_risk_by_age.R` | County high-risk ratios using state estimates and CDC PLACES burden. |
| 5 | `5_vaccine_coverage_by_state.R` | State weekly vaccination stockpile schedules. |
| 6 | `6_create_input_files_and_parallel_commands.R` | State-specific JSON inputs and parallel simulator commands. |

The resulting state directory normally contains:

```text
data/<STATE>/
├── INPUT_*.json
├── contact_matrix_<STATE>_Mistry2021_all.csv
├── county_pop_by_age_<STATE>_2019-2023ACS.csv
├── state_<STATE>_high-risk-ratios-flu-only.csv
├── county_<STATE>_high-risk-ratios-flu-only.csv
├── <STATE>_Q1-2019_mobility-matrix.csv
├── <STATE>_Q2-2019_mobility-matrix.csv
├── <STATE>_Q3-2019_mobility-matrix.csv
├── <STATE>_Q4-2019_mobility-matrix.csv
├── <STATE>_quarterly-2019_mobility.csv
└── <STATE>_quarterly-2019_county-connection-ranking.csv
```

Age-group order must agree across population, contact, risk-ratio, disease,
vaccine, and antiviral inputs. County order in each mobility matrix must agree
with the population file.

## Data Sources And Assumptions

| Dataset | Use | Important assumptions |
| --- | --- | --- |
| [2019-2023 American Community Survey](https://www.census.gov/programs-surveys/acs) | County population by the five simulator age groups | Uses 2023 five-year ACS estimates and modern county FIPS. |
| [Epydemix data](https://github.com/epistorm/epydemix-data) using Mistry 2021 contacts | State-specific age contact matrices | Uses the `all` layer: home, work, school, and community combined. The same matrix is used every simulation day. |
| [COVID19USFlows](https://github.com/GeoDS/COVID19USFlows) | 2019 county-to-county mobility | Keeps within-state flows, translates Alaska and Connecticut geography, normalizes outflow using population-based processing, and writes quarterly matrices. Missing county pairs are treated as zero flow. |
| [Behavioral Risk Factor Surveillance System](https://www.cdc.gov/brfss/annual_data/annual_data.htm) | Adult state/age influenza high-risk estimates and vaccination survey fields | Primarily 2024 data, with 2023 Tennessee data where 2024 submission was unavailable. |
| [National Survey of Children's Health](https://www.census.gov/programs-surveys/nsch/data/datasets.html) | Pediatric state/age influenza high-risk estimates | Uses survey weights and pediatric conditions associated with severe influenza risk. |
| [CDC influenza high-risk guidance](https://www.cdc.gov/flu/highrisk/index.htm) | Defines adult and pediatric conditions included in high-risk estimates | In this simulator, “risk” means risk of hospitalization or death, not risk of becoming infected. |
| [CDC PLACES](https://data.cdc.gov/500-Cities-Places/PLACES-Local-Data-for-Better-Health-County-Data-20/swc5-untb/about_data) | Adjusts state/age high-risk estimates to county comorbidity burden | Uses the latest available nonmissing county measures from the 2024 and 2025 releases. |
| [CDC/ATSDR Social Vulnerability Index](https://www.atsdr.cdc.gov/place-health/php/svi/svi-data-documentation-download.html) | Comparison for county risk adjustment | Retained as a comparison; current county risk construction is based primarily on PLACES comorbidities. |
| [CDC weekly influenza vaccination coverage](https://data.cdc.gov/Vaccinations/Weekly-Cumulative-Influenza-Vaccination-Coverage-C/eudc-n39h/about_data) | Pediatric seasonal vaccine schedule | Coverage is combined with pediatric effectiveness and state population. |
| [CDC adult influenza vaccination coverage](https://data.cdc.gov/Flu-Vaccinations/Weekly-Influenza-Vaccination-Coverage-and-Intent-f/sw5n-wg2p/about_data) | Adult seasonal vaccine schedule | Adult and pediatric schedules are combined into weekly stockpile releases relative to October 1, 2024. |
| [CDC vaccine-effectiveness studies](https://www.cdc.gov/flu-vaccines-work/php/effectiveness-studies/2023-2024.html) | Effectiveness assumptions used by the vaccine-preparation script | The current script uses separate pediatric and adult inpatient-effectiveness assumptions. |

These source files are preparation inputs, not all committed repository data.
Survey microdata, API keys, and the full daily mobility archive remain outside
version control.

## Output ETL

After simulations finish, configure `SEARCH_ROOT` near the top of
`scripts/7a_process_output_to_db.R` and run the script from the repository
working directory. It discovers `metadata_batch-*.json`, then:

- Creates or updates `metadata_master.csv`
- Converts network, node, and timing CSVs to compressed Parquet
- Partitions Parquet as `sim_data/<scenario_hash>/<batch_num>/`
- Optionally upserts metadata into MongoDB
- Skips an already ingested `(scenario_hash, batch_num)` pair

The source simulation directories remain the reproducibility record. Confirm
that the expected scenario/batch pairs are present in `metadata_master.csv`
before cleaning their larger CSV outputs.

## Dashboard

Configure `REPO_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` near the top of
`scripts/7b_sim_dashboard_app.R`, then open the file in RStudio and select
**Run App**. The dashboard reads the metadata index and Parquet partitions to:

- Filter scenarios by geography, model, and intervention
- Inspect completion and run-time information by batch
- Compare all batches sharing a scenario hash
- Plot compartment trajectories
- Export selected Parquet data back to CSV

The scenario hash represents the modeled configuration. The batch UUID
represents one execution of that configuration. Keeping both identifiers is
what makes repeated runs, partial batches, cleanup, and visualization
compatible.
