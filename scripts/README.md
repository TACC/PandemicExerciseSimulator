# PES Scripts

The `scripts/` directory contains the reproducible data-preparation pipeline
for `data/<STATE>/` and the post-simulation analysis workflow.

R scripts are easiest to run from RStudio by opening `scripts.Rproj`. This sets
the working directory to `scripts/`, which is assumed by the relative paths in
scripts `0` through `6`. Python dependencies are managed through Poetry.

## State Data Preparation

Start here: `0_run_full_pipeline_US.R` is the entry point for the full state/DC
pipeline. It orchestrates steps `1` through `6`, including seed no-intervention
generation, Epydemix fitting, intervention scenario generation, and command
creation. A complete run can take more than an hour because it processes large
survey and mobility datasets. Individual scripts can be run separately when only
one source needs to be refreshed.

```bash
cd scripts
Rscript 0_run_full_pipeline_US.R \
  --acs-year-range=2020-2024 \
  --sim-day-0=2025-10-01 \
  --simulation-days=300 \
  --output-dir=Example_TEST \
  --epydemix-nsim=1000 \
  --run-web-preview=true \
  --selected-states=District-of-Columbia,Connecticut,Massachusetts \
  --selected-scenarios=NONE,VACCINE,ANTIVIRAL,NPI,ALL_INTERVENTIONS \
  --deploy-shinyapps=false
```

The orchestrator prints large section banners such as
`###### Section 5b Running Epydemix Fits ######` so long console output is easy
to scan. It also writes a timestamped run log under the selected
`--output-dir`, for example:

```text
Example_TEST/pipeline_0_run_full_pipeline_US_YYYYMMDD_HHMMSS.log
```

The log captures R output/messages and appends stdout/stderr from long shell
commands such as `poetry install`, Epydemix fitting, and the selected local
simulation commands from `6f`.

`--output-dir` is the parent directory for generated pipeline artifacts. The
examples use `Example_TEST`, so paths such as `Example_TEST/WEB_INPUTS` mean
“the `WEB_INPUTS` folder inside the selected output directory.” Any directory
ending in `_TEST/` is intentionally ignored by git via `.gitignore`, which
keeps bulky local inputs, simulator outputs, metadata, and dashboard-preview
files out of commits.

| Step | Script | Inputs and outputs |
| --- | --- | --- |
| 1 | `1_county_age_pop_totals.R` | Uses the configured 5-year ACS county population data, `2020-2024` by default, to create state directories, county population-by-age files, and initial-infection candidates. |
| 2 | `2_epydemix_contact_matrix_generation.py` | Uses Epydemix/Mistry contact data to create one age-by-age contact matrix per state. |
| 3a | `3a_ct_ak_crosswalks.R` | Builds crosswalks for Connecticut and Alaska county-boundary changes. |
| 3b | `3b_county_mobility_timeseries_post2020census.R` | Uses COVID19USFlows county flows, applies modern geography, and writes quarterly state mobility matrices and connectivity rankings. |
| 3c | `3c_advan_county_mobility.R` | Converts Advan Research Foot Traffic / Neighborhood Patterns Plus files into state county-to-county OD CSVs and simulator-ready square matrices. |
| 4a | `4a_flu_state_high_risk_by_age.R` | Estimates state-and-age influenza high-risk proportions using BRFSS and NSCH survey data. |
| 4b | `4b_flu_county_high_risk_by_age.R` | Distributes state high-risk estimates to counties using CDC PLACES comorbidity burden, with SVI used for comparison. |
| 5a | `5a_derive_initial_exposures.R` | Derives state/DC county-age low-risk exposures from Flu Hub age-stratified incident hospitalization data using `prop_IS_to_H_lowrisk` from the SEIHRD template by default, or an explicit `--lowrisk-hosp-rate-file`, then writes dated seed JSONs under `<PIPELINE_OUTPUT_DIR>/SEED_INPUT_JSONS/<sim_day_0>/`. The orchestrator skips this step when the dated summaries, 51 dated seed JSONs, and 51 dated validation files already exist for `--sim-day-0`. |
| 5b | `5b_epydemix_fit_seihrd_hospitalizations.py` | Uses Epydemix ABC to fit the five-age-group SEIHRD hospitalization curve to Flu Hub age-stratified incident hospitalization time series, either one state or all `5a` no-intervention JSONs. The orchestrator writes/checks calibrated JSONs under `<PIPELINE_OUTPUT_DIR>/epydemix_fit/<sim_day_0>/` and skips this step when all 51 files there record the same fit start date as `--sim-day-0`. |
| 6a | `6a_vaccine_coverage_by_state.R` | Converts influenza coverage and effectiveness assumptions into weekly state vaccine-stockpile schedules. |
| 6b | `6b_outpatient_antiviral_coverage_by_state.R` | Estimates state-specific insured high-risk counts for outpatient antiviral stockpile scenarios. Skips when both final antiviral CSVs exist and caches downloaded ACS PUMS extracts under `data/RISK_RATIOS/PUMS_CACHE/`. |
| 6c | `6c_weekend_npi_schedule.R` | Expands a prototype Weekend Mobility Decrease NPI across the configured simulation window. |
| 6d | `6d_create_intervention_inputs.R` | Layers intervention templates onto calibrated seed inputs and writes scenario JSONs per state/DC to dated folders under `<PIPELINE_OUTPUT_DIR>/TACC_FILES`. |
| 6e | `6e_create_parallel_commands.R` | Creates `<PIPELINE_OUTPUT_DIR>/TACC_FILES/state_commands.txt` beside the dated TACC JSON folders and copies `data/INPUT_FILE_TEMPLATES/state_launcher.sh` to `<PIPELINE_OUTPUT_DIR>/TACC_FILES/state_launcher.sh` if missing. |
| 6f | `6f_run_selected_scenarios.R` | Runs a user-selected subset of states and scenarios locally, writing selected JSON copies and `web_state_commands.sh` to `<PIPELINE_OUTPUT_DIR>/WEB_INPUTS`, with generated outputs under `<PIPELINE_OUTPUT_DIR>/WEB_OUTPUTS`. |
| 7a | `7a_process_output_to_db.R` | Processes generated simulator outputs under `<PIPELINE_OUTPUT_DIR>`, updates `metadata_master.csv`, writes Parquet files under `sim_data/`, and skips already complete `(scenario_hash, batch_num)` pairs. |
| 8 | `8_prepare_shinyapps_bundle.R` | Refreshes the Shiny deployment bundle by copying the current `7b` dashboard as `app.R` and packaging the selected preview states and scenarios. |

The orchestrator expects some private or external inputs:

- a Census API key loaded from `data/private_input_data/api_keys.R`;
- BRFSS and NSCH source files under `data/BRFSS/` and `data/NSCH/`;
- CDC PLACES and SVI files under their corresponding data directories;
- a local checkout of the COVID19USFlows daily county-flow data.

For Advan Research Foot Traffic / Neighborhood Patterns Plus CSV exports
downloaded from Dewey Data, run:

```bash
cd scripts
Rscript 3c_advan_county_mobility.R --year=2025
```

By default, `3c` expects the mobility CSV shards in
`../../2025-us-dc-mobility-data-csv/` and the home-panel summary CSVs in
`../../neighborhood-patterns-us-home-panel-summary/` when called from inside
`scripts/`. Set the year with `--year=YYYY`, or edit `analysis_year` near the
top of the script when running interactively from RStudio. The script currently
uses those conventional sibling directories rather than an `--input-dir`
argument.

`3c` first writes cleaned direct CSV caches under:

```text
data/MOBILITY/Advan/cleaned-direct-data/home-panel/
data/MOBILITY/Advan/cleaned-direct-data/device-home-areas/
data/MOBILITY/Advan/intermediate/county-home-panel/
data/MOBILITY/Advan/intermediate/county-device-counts/
```

The cleaned device-home-area files expand `DEVICE_HOME_AREAS` into origin CBG,
destination CBG, and device-count rows. Monthly intermediates aggregate those
rows to within-state county-to-county device counts, apply the AK/CT county
crosswalk, join the latest available monthly home-panel counts, and expand
device counts by origin adult-population coverage.

The labeled monthly OD tables are written to
`data/MOBILITY/Advan/within-state_county-mobility/` as
`<STATE>_YYYY-MM_within-state_county-mobility.csv`. Quarterly no-header square
matrices are written to `data/<STATE>/<STATE>_Q<N>-YYYY_mobility-matrix.csv`,
and quarterly connectivity rankings are written to
`data/<STATE>/<STATE>_quarterly-YYYY_county-connection-ranking.csv`. Matrix
values are normalized destination shares within each origin county, based on
adult device counts expanded by the configured `ACS_YEAR_RANGE` population
files, which default to `2020-2024`.

Dataset citation: Advan Research. (2025). Foot Traffic / Neighborhood Patterns
Plus [Dataset]. Dewey Data. https://doi.org/10.82551/HYH5-PC45

Each script header records its source datasets, release assumptions, parent
directories, and any geography corrections. Update those headers and this
README when regenerating data from newer releases.

## Files In Each State Directory

The pipeline prepares:

```text
data/<STATE>/
├── INPUT_*.json
├── contact_matrix_<STATE>_Mistry2021_all.csv
├── county_pop_by_age_<STATE>_2020-2024ACS.csv
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

When sourced by `0_run_full_pipeline_US.R`, `7a` uses the configured
`--output-dir` as its search root. When run standalone, set
`PIPELINE_OUTPUT_DIR` before sourcing it, or use the default
`STATE_WKLYFIT_TEST`. Re-running is safe because already ingested
`(scenario_hash, batch_num)` pairs are skipped. Optional MongoDB ingestion is
disabled by default.

When `0_run_full_pipeline_US.R` is run with `--run-web-preview=true`, it sources
`6f_run_selected_scenarios.R`. By default, `6f` creates
`<PIPELINE_OUTPUT_DIR>/WEB_INPUTS/web_state_commands.sh` inside the configured
`--output-dir` and runs the selected scenarios for
`District-of-Columbia`, `Connecticut`, and `Massachusetts`. Override this local
subset with:

```bash
--selected-states=District-of-Columbia,Connecticut,Massachusetts
--selected-scenarios=NONE,VACCINE,ANTIVIRAL,NPI,ALL_INTERVENTIONS
```

Allowed scenario labels are `NONE`, `VACCINE`, `ANTIVIRAL`, `NPI`, and
`ALL_INTERVENTIONS`. The selected JSON copies are written under
`<PIPELINE_OUTPUT_DIR>/WEB_INPUTS`, and the selected outputs are written
under `<PIPELINE_OUTPUT_DIR>/WEB_OUTPUTS` so `7a` can ingest them with its
normal behavior. With `--output-dir=Example_TEST`, those folders are
`Example_TEST/WEB_INPUTS` and `Example_TEST/WEB_OUTPUTS`. Because `6f` is
called through the orchestrator's
`run_logged_command()` helper, simulator output is visible in the console as it
runs and is also appended to the timestamped pipeline log.

Before deleting large simulation CSVs, verify that each expected pair appears
in `metadata_master.csv` and that its Parquet files exist.

## Explore Outputs

`7b_sim_dashboard_app.R` is a Shiny dashboard for filtering metadata, checking
batch completion, comparing scenarios, plotting trajectories, and exporting
Parquet data to CSV.

Set `REPO_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` at the top of the file. Then
open it in RStudio and select **Run App**.

`8_prepare_shinyapps_bundle.R` copies the current
`scripts/7b_sim_dashboard_app.R` to `deploy/shinyapps/PandemicSimExplorer/app.R`
each time it runs, then writes a filtered `metadata_master.csv` and matching
`sim_data/` subset for the latest complete local preview batch for each selected
state and scenario. When called from `0_run_full_pipeline_US.R`, it uses
`WEB_PREVIEW_STATES` from `SELECTED_RUN_STATES` and
`SELECTED_RUN_SCENARIOS`; standalone runs can override those with
`DASHBOARD_PREVIEW_STATES` and `DASHBOARD_PREVIEW_SCENARIOS`. It stops if any
expected preview rows or Parquet directories are missing. This avoids publishing
a stale dashboard while keeping the deploy bundle below the free upload limit.

## Deploy Preview To shinyapps.io

The pipeline prepares the deployment bundle by default, but deployment is
opt-in. It assumes:

- you have a shinyapps.io account;
- the R package `rsconnect` is installed;
- your local machine has already been authorized with your shinyapps.io token
  and secret;
- the prepared bundle is within your plan limit. As of August 10, 2026, Posit
  documents a 1 GB bundle limit for Free and Starter plans, and the Free plan
  allows 5 apps and 25 active hours per month.

Authorize this machine once from R or RStudio using the token and secret from
your shinyapps.io dashboard:

```r
install.packages("rsconnect")
rsconnect::setAccountInfo(
  name = "<your-shinyapps-account>",
  token = "<token>",
  secret = "<secret>"
)
```

After that, either let `0_run_full_pipeline_US.R` deploy after it refreshes the
bundle:

```bash
cd scripts
Rscript 0_run_full_pipeline_US.R \
  --output-dir=Example_TEST \
  --run-web-preview=true \
  --deploy-shinyapps=true \
  --shinyapps-account=<your-shinyapps-account> \
  --shinyapps-app-name=PandemicSimExplorer
```

Or deploy the already-prepared bundle manually from the repository root:

```r
rsconnect::deployApp(
  appDir = "deploy/shinyapps/PandemicSimExplorer",
  appName = "PandemicSimExplorer",
  account = "<your-shinyapps-account>"
)
```

## Fit SEIHRD Hospitalizations With Epydemix

`5b_epydemix_fit_seihrd_hospitalizations.py` reads an existing SEIHRD input JSON,
the Flu Hub file at `data/FLU_HUB/time-series_2026-07-13.csv`, and fits the
single projection-season weekly age-stratified incident hospitalization series
with `epydemix.calibration.ABCSampler`. By default, the fit starts at
`metadata_tags.sim_day_0`, constrains `R0 > 1`, preserves the input JSON
`initial_exposed` values from `5a_derive_initial_exposures.R`, and estimates only
`R0`. Pass `--fit-initial-exposed-scale` only for an explicit sensitivity run.
The default generated metric is `admissions`, which sums daily new `IS -> H`
flows over complete Sun-Sat MMWR weeks to match Flu Hub weekly incident
hospitalizations. If `sim_day_0` falls inside a reporting week, the partial
first week is skipped and fitting starts at the first full MMWR week end. The
default penalty emphasizes aggregate all-age shape and peak-week timing. The
calibrated JSON uses the best-distance particle by default; pass
`--calibrated-json-estimator median` if you prefer the posterior median. For one
Delaware init-test file:

```bash
python3 scripts/5b_epydemix_fit_seihrd_hospitalizations.py \
  --input-json Example_TEST/SEED_INPUT_JSONS/2025-10-01/INPUT_SEIHRD-STOCH_Delaware_SEED_NONE.json \
  --output-dir Example_TEST/epydemix_fit/2025-10-01 \
  --hosp-file data/FLU_HUB/time-series_2026-07-13.csv \
  --nsim 1000 \
  --top-fraction 0.05 \
  --write-calibrated-json
```

To fit every no-intervention JSON produced by `5a`, use:

```bash
python3 scripts/5b_epydemix_fit_seihrd_hospitalizations.py \
  --all-states \
  --input-json-dir Example_TEST/SEED_INPUT_JSONS/2025-10-01 \
  --output-dir Example_TEST/epydemix_fit/2025-10-01 \
  --hosp-file data/FLU_HUB/time-series_2026-07-13.csv \
  --nsim 1000 \
  --top-fraction 0.05 \
  --write-calibrated-json
```

The script writes `posterior_samples.csv`, `best_parameters.json`,
`best_fit_timeseries.csv`, and, when requested, a calibrated simulator JSON copy
under `<PIPELINE_OUTPUT_DIR>/epydemix_fit/`. In `--all-states` mode, each input JSON
gets its own subdirectory under the date-specific output directory, and a
`batch_manifest.json` summarizes successes and failures.

The repository does not currently include a separate Read the Docs source tree;
keep this file and `../data/README.md` in sync when script behavior, generated
input fields, or model-family template rules change.
