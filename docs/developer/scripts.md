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

## Output ETL

After simulations finish, configure `SEARCH_ROOT` near the top of
`scripts/7a_process_output_to_db.R` and run the script from the repository
working directory. It discovers `metadata_batch-*.json`, then:

- creates or updates `metadata_master.csv`;
- converts network, node, and timing CSVs to compressed Parquet;
- partitions Parquet as `sim_data/<scenario_hash>/<batch_num>/`;
- optionally upserts metadata into MongoDB;
- skips an already ingested `(scenario_hash, batch_num)` pair.

The source simulation directories remain the reproducibility record. Confirm
that the expected scenario/batch pairs are present in `metadata_master.csv`
before cleaning their larger CSV outputs.

## Dashboard

Configure `REPO_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` near the top of
`scripts/7b_sim_dashboard_app.R`, then open the file in RStudio and select
**Run App**. The dashboard reads the metadata index and Parquet partitions to:

- filter scenarios by geography, model, and intervention;
- inspect completion and run-time information by batch;
- compare all batches sharing a scenario hash;
- plot compartment trajectories;
- export selected Parquet data back to CSV.

The scenario hash represents the modeled configuration. The batch UUID
represents one execution of that configuration. Keeping both identifiers is
what makes repeated runs, partial batches, cleanup, and visualization
compatible.
