# PES Scripts

The `scripts/` directory contains the reproducible data-preparation pipeline
for `data/<STATE>/` and the post-simulation analysis workflow.

R scripts are easiest to run from RStudio by opening `scripts.Rproj`. This sets
the working directory to `scripts/`, which is assumed by the relative paths in
scripts `0` through `6`. Python dependencies are managed through Poetry.

## State Data Preparation

`0_generate_US-State_inputs.R` orchestrates steps `1` through `6`. A complete
run can take more than an hour because it processes large survey and mobility
datasets. Individual scripts can be run separately when only one source needs
to be refreshed.

| Step | Script | Inputs and outputs |
| --- | --- | --- |
| 1 | `1_county_age_pop_totals.R` | Uses 2019-2023 ACS county population data to create state directories, county population-by-age files, and initial-infection candidates. |
| 2 | `2_epydemix_contact_matrix_generation.py` | Uses Epydemix/Mistry contact data to create one age-by-age contact matrix per state. |
| 3a | `3a_ct_ak_crosswalks.R` | Builds crosswalks for Connecticut and Alaska county-boundary changes. |
| 3b | `3b_county_mobility_timeseries_post2020census.R` | Uses COVID19USFlows county flows, applies modern geography, and writes quarterly state mobility matrices and connectivity rankings. |
| 4a | `4a_flu_state_high_risk_by_age.R` | Estimates state-and-age influenza high-risk proportions using BRFSS and NSCH survey data. |
| 4b | `4b_flu_county_high_risk_by_age.R` | Distributes state high-risk estimates to counties using CDC PLACES comorbidity burden, with SVI used for comparison. |
| 5 | `5_vaccine_coverage_by_state.R` | Converts influenza coverage and effectiveness assumptions into weekly state vaccine-stockpile schedules. |
| 6 | `6_create_input_files_and_parallel_commands.R` | Replaces `STATE` tokens in templates, inserts initial exposures and vaccination schedules, writes `data/<STATE>/INPUT_*.json`, and creates parallel simulator commands. |
| 6b | `6b_derive_initial_exposures.R` | Delaware manuscript example deriving county-age low-risk exposures from age-stratified incident hospitalization data and writing `data/Delaware_TEST/INPUT_*.json`. |

The orchestrator expects some private or external inputs:

- a Census API key loaded from `data/private_input_data/api_keys.R`;
- BRFSS and NSCH source files under `data/BRFSS/` and `data/NSCH/`;
- CDC PLACES and SVI files under their corresponding data directories;
- a local checkout of the COVID19USFlows daily county-flow data.

Each script header records its source datasets, release assumptions, parent
directories, and any geography corrections. Update those headers and this
README when regenerating data from newer releases.

## Files In Each State Directory

The pipeline prepares:

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

The age-group order must match across population, contact, risk, model,
vaccine, and antiviral inputs. Mobility-matrix county order must match the
population file.

“High risk” means increased risk of hospitalization or death from influenza.
The risk files are most directly expressed by SEIHRD-family models, but risk
groups are required by all models and may also control vaccine or antiviral
eligibility.

## Generated Simulation Identity

Input templates normally use:

```json
"output_dir_path": "GENERATE",
"batch_num": "GENERATE"
```

The simulator writes equivalent scenarios to
`<STATE>_<SCENARIO_HASH>/`. Each execution receives a separate UUIDv7
`batch_num`, used in its metadata and CSV filenames. The pair
`(scenario_hash, batch_num)` is the stable key used by scripts `7a` and `7b`.

## Process Completed Outputs

`7a_process_output_to_db.R` searches beneath its configured `SEARCH_ROOT` for
`metadata_batch-*.json`. It builds:

```text
<SEARCH_ROOT>/
├── metadata_master.csv
└── sim_data/
    └── <scenario_hash>/
        └── <batch_num>/
            ├── network.parquet
            ├── nodes.parquet
            └── simulation_times.parquet
```

Set `SEARCH_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` at the top of the script
before running it. Re-running is safe because already ingested
`(scenario_hash, batch_num)` pairs are skipped. Optional MongoDB ingestion is
disabled by default.

Before deleting large simulation CSVs, verify that each expected pair appears
in `metadata_master.csv` and that its Parquet files exist.

## Explore Outputs

`7b_sim_dashboard_app.R` is a Shiny dashboard for filtering metadata, checking
batch completion, comparing scenarios, plotting trajectories, and exporting
Parquet data to CSV.

Set `REPO_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` at the top of the file. Then
open it in RStudio and select **Run App**.

The repository does not currently include a separate Read the Docs source tree;
keep this file and `../data/README.md` in sync when script behavior, generated
input fields, or model-family template rules change.
