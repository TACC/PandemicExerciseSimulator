# PES Scripts

The `scripts/` directory contains the reproducible data-preparation pipeline
for `data/<STATE>/` and the post-simulation analysis workflow.

R scripts are easiest to run from RStudio by opening `scripts.Rproj`. This sets
the working directory to `scripts/`, which is assumed by the relative paths in
scripts `0` through `6`. Python dependencies are managed through Poetry.

## State Data Preparation

Start here: `0_run_full_pipeline_US.R` shows the numbered `0`–`9` pipeline.
Experiment settings and their explanations live in
`data/INPUT_FILE_TEMPLATES/RUN_FULL_PIPELINE_INPUTS.R`; copy that input-only file
for each experiment. Parsing, validation and launch helpers live in
`0_pipeline_helpers.R`, so the main script stays focused on the workflow.
A complete run can take more than an hour because it processes large
survey and mobility datasets. Individual scripts can be run separately when only
one source needs to be refreshed.

From the repository root:

```bash
Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/RUN_FULL_PIPELINE_INPUTS.R
```

Command-line values override the input file. Add `--check-config` to validate and
print the settings without installing packages, downloading data or running fits.
In RStudio, set `PIPELINE_CONFIG_FILE` to your input file and source `0`.

### LS6 phases

`RUN_FULL_PIPELINE_INPUTS.R` is the local full-pipeline example. For LS6, edit
`LS6_PIPELINE_INPUTS.R`, `1_RUN_FIT.R`, `2_RUN_SCENARIOS.R`, and `3_RUN_FIGURES.R`
in `data/INPUT_FILE_TEMPLATES/` directly, or copy all four files together into
an experiment directory. Edit scientific settings once in
`LS6_PIPELINE_INPUTS.R`; all three phase files inherit them from the shared file
in the same directory. The commands below use the templates in their original
location. If you copy them, replace each `--config=data/INPUT_FILE_TEMPLATES/...`
path with the corresponding copied phase file's path, relative to the repository
root or absolute.
The LS6 example uses all states, 100 realizations, 32 workers per fitting
candidate, all four search criteria, peak-height selection, and reuse of the
winning All Interventions batch. Publication is disabled.

Run all three phase commands from the repository root through the LS6 container
wrapper:

The wrapper loads `tacc-apptainer` when needed and defaults
`APPTAINERENV_PES_R_LIBRARY` to `$WORK/pes-r-library` for all three phases.
An explicitly set library path is preserved. Use these wrapper commands after
each login; no repeated manual setup is needed. When invoking Apptainer directly,
run the following again after each login (or add them to your shell startup):

```bash
module load tacc-apptainer
export APPTAINERENV_PES_R_LIBRARY="$WORK/pes-r-library"
```

```bash
bash 'scripts/ls6_container_exec.sh' Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/1_RUN_FIT.R
```

This prepares data and writes the fitting launcher under
`<output_dir>/Rm_search/<date>/`. Set the allocation in that directory's
`fit_state_pylauncher.sh`, then submit it with `sbatch fit_state_pylauncher.sh`.
The fitting files are `fit_state_commands.txt`, `fit_state_pylauncher.py`, and
`fit_state_pylauncher.sh`. The Python launcher retains the template's `cores=4`
and the shell job name is `fit_state_Rm`. Scenario launchers keep their original
`state_*` names.
Per-state fitting logs are written under `<date>/logs/`.
Fitting commands are ordered by county count, fewest first, with state name
breaking ties. Script 0 prints the ordered states and counts when writing them.
LS6 launchers include all states being fitted (51 commands for all states/DC),
even when calibrated JSONs already exist. Each fitting job checks for reusable
state checkpoints and completed simulation batches on the execution machine;
a calibrated JSON alone does not remove a state from the command file.
Parallel execution means jobs can finish in a different order.
Selecting `execution_target = "ls6"` automatically generates container
commands for fitting and scenarios, using `$WORK/pes_pipeline_r442_py312.sif`
on the job's compute node. Shell launchers load Apptainer and the shared wrapper
restores the image's R/Python environment. `ls6_container_image` is an optional
path override; local execution stays native. See the
[container build instructions](../containers/README.md).
All fitting states share the original `<date>/candidate_inputs/`, `sim_outputs/`,
and `plots/` directories. Fitting tasks write private state-specific RDS files
under `<date>/checkpoints/`; they never write combined sweep CSVs. Once all
fits finish, `2_RUN_SCENARIOS.R` publishes `Rm_search_*.csv` files directly under
`<date>/`. This removes shared summary-table writes from parallel fitting.
After fitting finishes:

```bash
bash 'scripts/ls6_container_exec.sh' Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/2_RUN_SCENARIOS.R
```

This requires matching fits for all states and dates, prepares the downstream
inputs and launcher under `<output_dir>/TACC_FILES/`, then stops. Submit that
directory's `state_pylauncher.sh`. The retained fitting scenario has no rerun
commands. Every generated scenario command uses the same container wrapper as
fitting, for example `bash '../../scripts/ls6_container_exec.sh' poetry run
python3 ../../src/simulator.py ...`. This applies to NONE, VACCINE, ANTIVIRAL,
NPI, and ALL_INTERVENTIONS when selected; reused winning-fit batches are omitted.
The generator prints the execution target and command prefix for inspection.
After the scenario jobs finish:

```bash
bash 'scripts/ls6_container_exec.sh' Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/3_RUN_FIGURES.R
```

This requires completed selected scenarios, then builds Parquet data, the
deployment bundle, and figures. It never generates inputs or simulation
commands. Keep `deploy_shinyapps = FALSE` to publish separately after review.
Use `--check-config` with any phase file to check merged settings without work.

The explicit `pipeline_phase` values are `fit`, `scenarios`, `results`, and `deploy`.
With `execution_target = "local"`, the fit and scenarios phases execute locally
instead of preparing LS6 jobs. The default local `pipeline_phase = "all"`
preserves the complete 0–9 workflow. Results processing never starts simulations.

To rebuild only the deployment from existing Parquet outputs, use
`4_PREPARE_DEPLOYMENT.R` (see [Rebuild a deployment](#rebuild-a-deployment)).
This phase skips fitting, simulation input generation, simulations, ingestion,
and figures, even if their switches are enabled in the shared experiment file.

`r0_fit_scenario` chooses the scenario fitted to observed hospitalizations
(for example, `"ALL_INTERVENTIONS"` or `"VACCINE"`). `r0_selection_metric`
chooses the winning R_m, which all downstream scenario inputs inherit.
Set `reuse_best_fit_simulations = TRUE` to use that winning candidate's saved
simulations for downstream analyses and omit its TACC and local rerun commands.
Keep the fitting scenario in `selected_scenarios` to include those results.
Reuse requires matching fitting/downstream realization ranges and full-simulator
fitting for all states (`r0_county_threshold = 255L`). Other scenarios still run
normally. The selected batches are recorded in `reused_fit_outputs.csv`; ingestion
and bundling read those batches without copying the whole sweep.
The example preserves the previous defaults: 10 fitting realizations, auto
workers and direct fitting. For LS6 preparation, set `r0_realization_range` to
`c(0L, 99L)`, `workers` to `32L` and `r0_fit_launch` to `"pylauncher"` in your copy.

Existing command-line-only runs continue to work, for example:

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
  --r0-fit-method=epydemix_all \
  --deploy-shinyapps=false
```

The orchestrator prints numbered stage banners such as
`5b/5c. R_m fitting` so long console output is easy
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
| 5b | `5b_epydemix_fit_seihrd_hospitalizations.py` | Uses Epydemix ABC to fit the five-age-group SEIHRD hospitalization curve to Flu Hub age-stratified incident hospitalization time series, either one state or all `5a` no-intervention JSONs. The default target is weekly incident hospital admissions; pass `--epydemix-fit-target=hosp_increase` to the orchestrator, or `--fit-target hosp_increase` to the Python script, to compare against the older positive H-compartment-increase target. The orchestrator writes/checks calibrated JSONs under `<PIPELINE_OUTPUT_DIR>/epydemix_fit/<sim_day_0>/` and skips this step when all 51 files there record the same fit start date as `--sim-day-0`. |
| 5c | `5c_Rm_search.R` | Full-simulator R0 search, defaulting to absolute total incident-hospitalization error. Outputs use `Rm_search/<sim_day_0>/`. `--r0-fit-method=simulator_county_threshold` uses it for counties `<= --r0-county-threshold` (default 255), with Epydemix for larger states. `--r0-realization-range=0,9` is independent of the final simulator range; legacy `--r0-wis-*` flags and fit-method names remain aliases. The existing weekly hospitalization series is scored over complete MMWR weeks within the simulation window. Individual criteria are `total`, `peak_height`, `peak_timing`, and optional `wis`; `--r0-search-metrics=all` explores the three features, and `all,wis` adds WIS. `--r0-selection-metric` chooses the downstream calibrated JSON (default `total`). There is no combined penalty loss. Candidate realizations default to `--execution-mode=parallel --workers=auto`. |
| 6a | `6a_vaccine_coverage_by_state.R` | Converts influenza coverage and effectiveness assumptions into weekly state vaccine-stockpile schedules. |
| 6b | `6b_outpatient_antiviral_coverage_by_state.R` | Estimates state-specific insured high-risk counts for outpatient antiviral stockpile scenarios. Skips when both final antiviral CSVs exist and caches downloaded ACS PUMS extracts under `data/RISK_RATIOS/PUMS_CACHE/`. |
| 6c | `6c_weekend_npi_schedule.R` | Expands a prototype Weekend Mobility Decrease NPI across the configured simulation window. |
| 6d | `6d_create_intervention_inputs.R` | Layers intervention templates onto calibrated seed inputs and writes scenario JSONs per state/DC to dated folders under `<PIPELINE_OUTPUT_DIR>/TACC_FILES`. |
| 6e | `6e_create_parallel_commands.R` | Creates `<PIPELINE_OUTPUT_DIR>/TACC_FILES/state_commands.txt` for all generated state/DC TACC JSONs and copies `data/INPUT_FILE_TEMPLATES/state_launcher.sh` to `<PIPELINE_OUTPUT_DIR>/TACC_FILES/state_launcher.sh` if missing. |
| 6f | `6f_run_selected_scenarios.R` | Runs a user-selected subset of states and scenarios locally, writing selected JSON copies and `web_state_commands.sh` to `<PIPELINE_OUTPUT_DIR>/WEB_INPUTS`, with generated outputs under `<PIPELINE_OUTPUT_DIR>/WEB_OUTPUTS`. |
| 7a | `7a_process_output_to_db.R` | Processes generated simulator outputs under `<PIPELINE_OUTPUT_DIR>`, updates `metadata_master.csv`, writes Parquet files under `sim_data/`, and skips already complete `(scenario_hash, batch_num)` pairs. |
| 8 | `8_prepare_shinyapps_bundle.R` | Refreshes the Shiny deployment bundle by copying the current `7b` dashboard as `app.R` and packaging the selected preview states and scenarios. |
| 9a | `9a_pre_sim_input_plots.R` | Draws pre-simulation input figures, including mobility matrix flow maps, under `<PIPELINE_OUTPUT_DIR>/validation_scores/plots/`. |
| 9b | `9b_score_validation_hubverse_style.R` | Scores validation outputs, writes WIS summaries, and writes validation figures under `<PIPELINE_OUTPUT_DIR>/validation_scores/plots/`. |
| 9c | `9c_score_validation_run_diagnostics.R` | Calculates additional simulations needed for a 95% CI and runtime diagnostics by state/scenario, then writes a combined runtime plot and a compartment-level heatmap. |

If a full-simulator R0 run finishes its simulations but stops before writing its summary or
calibrated JSONs, replay the search from saved outputs with the original settings:

```bash
Rscript scripts/5c_Rm_search.R \
  --output-dir=MANUSCRIPT_EXAMPLE_TEST --sim-day-0=2025-10-04 \
  --selected-states=District-of-Columbia,Delaware,Rhode-Island \
  --simulation-days=200 --realization-range=0,9 \
  --r0-selection-metric=total --recover-existing=true \
  --write-calibrated-jsons=true
```

Set `--selected-states` to the states from the interrupted run. Recovery never
launches the simulator: it stops if a required candidate is missing. Preserve
any nondefault search settings from the original invocation. Each finished
state now saves its trace, weekly scores, predictions, best R0, and requested
calibrated JSON before plotting or proceeding to another state. After recovery,
the orchestrator can reuse the calibrated JSONs and continue generating TACC inputs.

The simulation end date is `sim_day_0 + simulation_days` (day 0 is initialization).
Both validation points and the existing simulated series are restricted to complete
Sun–Sat MMWR weeks inside days 1 through that end date; a final partial week is
excluded on both sides. Extinct realizations are zero-padded through the same
window. Total error compares the sum of weekly simulated medians with the sum of
observations on those weeks. The existing calculation of simulated hospitalizations is unchanged; this version
updates the search criteria and common scoring window. Old folders are preserved.

To rerun the full pipeline using total hospitalizations only:

```bash
Rscript scripts/0_run_full_pipeline_US.R \
  --output-dir=MANUSCRIPT_EXAMPLE_TEST --sim-day-0=2025-10-04 \
  --simulation-days=200 --r0-fit-method=simulator_county_threshold \
  --r0-selection-metric=total --r0-search-metrics=total \
  --r0-realization-range=0,9 --execution-mode=parallel --workers=auto
```

As before, calibration covers the generated seed states; `--selected-states`
controls the local preview subset. Use `--r0-search-metrics=all` to explore
three feature paths, `--r0-search-metrics=all,wis` for all four, or select just
`wis`, `peak_height`, or `peak_timing`. The selected criterion must be included
in the paths and is added automatically. Search plots use only requested paths.

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

## Validation Figures

When `0_run_full_pipeline_US.R` runs with `--run-web-preview=true` and
`--make-validation-figs=true`, step `9b` writes Hubverse-style quantile score
outputs to `<PIPELINE_OUTPUT_DIR>/validation_scores/`, pooling all available
Parquet batches for each scenario hash. With `--make-diagnostic-figs=true`, step `9c` writes
`simulation_completion_runtime_summary.csv` with attempted simulations,
completed simulations, scheduled simulations still missing, completion fraction,
mean runtime per simulation across available batches in each state/scenario/hash,
and data-driven estimates of additional simulations needed for a 95% confidence
interval by state/scenario. By default, the CI
estimate targets a half-width of 5% of each compartment mean, with a minimum
half-width of 1 person. Compartments `S`, `R`, and `D` use final-day totals;
transient compartments use summed totals across the simulation trajectory. Both
the runtime and CI estimates pool all available batches for each scenario hash,
so rerunning a state/scenario with a new realization range contributes additional
realizations to the validation figures instead of replacing the prior batch. It
also writes
`simulation_compartment_ci_sims_needed.csv` with one row per
state/scenario/compartment and a `compartment_summary_type` column.

The validation plot directory includes a single combined runtime plot and a
compartment-level CI-needed heatmap, both ordered by county count with the
largest states at the top:

```text
<PIPELINE_OUTPUT_DIR>/validation_scores/plots/run_time_by_state_scenario.png
<PIPELINE_OUTPUT_DIR>/validation_scores/plots/sims_needed_for_95ci_by_state_scenario_compartment_heatmap.png
```

Step `9b` also reads `data/VACCINATION/all_US_weekly_vax_adult-ped.csv`, when
available, and writes one vaccine coverage figure per validation state under:

```text
<PIPELINE_OUTPUT_DIR>/validation_scores/plots/vaccine_coverage_by_state/
```

Pre-simulation input plots now live in the 9-series plotting workflow as step
`9a`. The orchestrator calls them with the validation figures by default:

```bash
Rscript 0_run_full_pipeline_US.R \
  --output-dir=Example_TEST \
  --run-web-preview=true \
  --make-pre-sim-figs=true \
  --make-validation-figs=true \
  --make-diagnostic-figs=true
```

Because generating every selected state-quarter pre-simulation plot can be
slow, pass `--make-pre-sim-figs=false` to skip only step `9a`. Use
`--make-validation-figs=false` to skip only step `9b`, and
`--make-diagnostic-figs=false` to skip only step `9c`.
By default, steps `7a`, `9b`, and `9c` use only simulator metadata whose paths
match `WEB_OUTPUTS`, which prevents R0 WIS search candidates from being scored
as intervention scenarios. Pass `--validation-output-source-regex=<regex>` to
`0_run_full_pipeline_US.R`, or `--output-source-regex=<regex>` directly to
`9b`/`9c`, to score a different output source.

To run only the pre-simulation input plots:

```bash
Rscript scripts/9a_pre_sim_input_plots.R \
  --output-dir=Example_TEST \
  --year=2025 \
  --acs-year-range=2020-2024
```

## Explore Outputs

`7b_sim_dashboard_app.R` is a Shiny dashboard for filtering metadata, checking
batch completion, comparing scenarios, plotting trajectories, and exporting
Parquet data to CSV.

The **County map** tab has state, age, scenario, compartment, and simulation
selectors, a Count/Percentage toggle, and an animated day slider below the map.
**Network preview** uses the same State → Age group → Scenario selection order.
Both tabs share scenario labels with intervention names, R0, model, and the short
hash, and list only scenarios for the selected state. Selecting a metadata table
row also switches Network preview to that row's state and scenario.
While the map is being computed, a loading indicator explains that boundaries
and simulation data may take time to load. The deployment includes the entire
generated `data/` folder, including boundaries and county population inputs.
Each frame shows one realization. Percentages divide the selected compartment
count by that county's population in the selected age group (all five groups
for All ages), using the scenario's existing `data_population` CSV. Counties
without records are gray. The yellow-to-red logarithmic color scale stays fixed
across days, matching the Python frontend; hovers show the untransformed count
and percentage. Boundary files are served once as static assets and can be
prefetched during browser idle time. The figure sends boundary URLs rather
than embedding the same geometry in both map layers. Daily updates send compact
numeric values; hover labels are formatted in the browser.

Map data queries run through Shiny `ExtendedTask` on one separate R worker,
so another tab in the same session can still update while a map loads. The
worker uses one DuckDB thread and a 128 MB query memory limit. Each session
caches recent results within 32 MB. Rapid selection changes keep only the latest
pending request, and obsolete completed results can still be reused from cache.
Playback pauses when leaving the map tab. The app prepares the worker at startup;
the first map query may still need to read its Parquet columns from disk.

Phase 4 downloads only selected states' county boundaries and the license directly
from `TACC/PandemicExerciseTool`, pinned to commit
`12242450febc494f30616a191f743ca6f1638cd6`. Downloads are staged in a temporary
directory, validated, counted against the bundle budget, and copied into the
bundle's `data/dashboard_map_assets/`. Internet access is required when preparing
a deployment; the published app serves its bundled files without GitHub requests.
The simulator's own `data/` directory needs no map assets. Source dashboard
previews reuse the most recently prepared deployment's boundary files.
No additional R packages, external map tiles, or API keys are required.

Set `REPO_ROOT`, `MASTER_CSV`, and `PARQUET_ROOT` at the top of the file. Then
open it in RStudio and select **Run App**.

`8_prepare_shinyapps_bundle.R` copies the current
`scripts/7b_sim_dashboard_app.R` to `deploy/shinyapps/PandemicSimExplorer/app.R`
each time it runs, rewrites the deployed app to read from the bundle's local
`data/` directory, then writes a filtered `metadata_master.csv`, copies
`scenario_features.parquet`, and copies the matching `sim_data/` subset. For
each selected state and scenario label, it keeps all matching scenario hashes and
uses the newest complete local preview batch for each hash. This lets parameter
comparison runs publish together without adding parameter-specific deploy code. It
also recreates the small deployment-project scaffold files (`deploy.R`,
`DESCRIPTION`, `README.md`, `renv.lock`) and creates or updates the Posit
Publisher configuration under
`deploy/shinyapps/PandemicSimExplorer/.posit/publish/`. It reuses the configuration
named by the saved `deployments/*.toml` record, preserving the existing hosted
app's deployment ID. If several deployments are present, preparation stops
instead of guessing a target. A new project without deployment records reuses
its sole config, or creates a starter config when none exists.
After the deploy app and `DESCRIPTION` exist, script `8` runs `renv::snapshot()`
against the deploy bundle itself so `renv.lock` reflects the Shiny app's current
R package dependencies.

Posit Publisher/Positron can also generate `.posit/publish/*.toml` files when
you start a new deployment from the Publisher pane, such as **Deploy Project** or
**New Deployment**. The files written by script `8` are included so the
deployment bundle is reproducible on a new computer without depending on local
Positron state. If a Publisher configuration already exists, script `8`
preserves it and only makes the required maintenance edits, such as ensuring the
literal `"$schema"` key is quoted and `/data/scenario_features.parquet` appears
in the `files` list.

When called from `0_run_full_pipeline_US.R`, script `8` uses
`WEB_PREVIEW_STATES` from `SELECTED_RUN_STATES` and `SELECTED_RUN_SCENARIOS`;
standalone runs can override those with `DASHBOARD_PREVIEW_STATES` and
`DASHBOARD_PREVIEW_SCENARIOS`. It stops if any expected preview scenario label
has no matching rows or if any selected Parquet directories are missing. This
avoids publishing a stale dashboard while keeping the deploy bundle scoped to the
selected preview states and scenarios.

Script `8` also copies the selected states' county boundaries and their existing
county-by-age population CSVs, rewriting `data_population` to a portable bundled
path. It estimates the selected payload before copying, then checks the **entire
finished deployment directory**, including hidden files, against a decimal
**5 GB** budget (`dashboard_max_bundle_bytes` in pipeline inputs, default `5e9`).
An oversized selection fails before previous deployment data is replaced. Each
rebuild overwrites this same folder's generated `data/` tree, so deselected states
cannot linger in the payload. The original pipeline outputs and the existing
`.posit` publishing settings are preserved. The complete `/data` folder is
included in Publisher's file list, covering county boundaries and populations
as well as the simulation Parquet files.

## Rebuild a deployment

Edit `data/INPUT_FILE_TEMPLATES/4_PREPARE_DEPLOYMENT.R`, which inherits the
experiment's `output_dir` and scientific settings from `LS6_PIPELINE_INPUTS.R`.
Its `selected_states` vector defaults to Texas, Oklahoma, New Mexico, Louisiana,
Arkansas, and California. Set `selected_states = NULL` or `character()` for all
available states. These are the existing pipeline state-selection conventions;
in the `deploy` phase they affect only packaging. `selected_scenarios` controls
which intervention scenarios are included. All county/age detail, simulation
replicates, validation inputs, map controls, and CSV exports are retained.

From the repository root on your local computer:

```bash
Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/4_PREPARE_DEPLOYMENT.R
```

On LS6, prefix that command with `bash scripts/ls6_container_exec.sh`.
You can override the input file's subset without editing it:

```bash
Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/4_PREPARE_DEPLOYMENT.R --selected-states=Texas,Oklahoma,Louisiana
```

Use `--selected-states=` for all available states; the size budget still applies.
Add `--check-config` to inspect settings without rebuilding anything. Successful
preparation prints the folder's exact size in decimal GB. With
`deploy_shinyapps = FALSE`, no upload occurs: publish the prepared
`deploy/shinyapps/PandemicSimExplorer` folder using Posit Publisher / Connect
Cloud. The separate `deploy_shinyapps` switch is specifically for shinyapps.io.
Choose the existing saved deployment in Publisher to update the hosted app;
creating a New Deployment creates a separate hosted app. A localhost preview
opened for testing is a separate browser view and does not publish anything.

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

To deploy the same bundle with Positron instead, open
`deploy/shinyapps/PandemicSimExplorer` as the project folder, refresh the
Publisher pane if needed, and deploy using the generated configuration
`PandemicSimExplorer-3R9A`. The configuration file's `files` list controls the
Publisher **Project Files** checklist and includes the dashboard app, dependency
files, metadata CSV, `scenario_features.parquet`, selected Parquet outputs, and
validation fit data.

## Fit SEIHRD Hospitalizations With Epydemix

`5b_epydemix_fit_seihrd_hospitalizations.py` reads an existing SEIHRD input JSON,
the Flu Hub file at `data/FLU_HUB/time-series_2026-07-13.csv`, and fits the
single projection-season weekly age-stratified incident hospitalization series
with `epydemix.calibration.ABCSampler`. By default, the fit starts at
`metadata_tags.sim_day_0`, constrains `R0 > 1`, preserves the input JSON
`initial_exposed` values from `5a_derive_initial_exposures.R`, and estimates only
`R0`. Pass `--fit-initial-exposed-scale` only for an explicit sensitivity run.
The default fit target is `hosp_incident`, which sums daily new `IS -> H`
admissions over complete Sun-Sat MMWR weeks to match Flu Hub weekly incident
hospitalizations. For comparison with the older target, pass
`--fit-target hosp_increase`; this sums positive daily increases in the H
compartment over each observed week. If `sim_day_0` falls inside a reporting
week, the partial first week is skipped and fitting starts at the first full
MMWR week end. The default penalty emphasizes aggregate all-age shape and
peak-week timing. The calibrated JSON uses the best-distance particle by default; pass
`--calibrated-json-estimator median` if you prefer the posterior median. For one
Delaware init-test file:

```bash
python3 scripts/5b_epydemix_fit_seihrd_hospitalizations.py \
  --input-json Example_TEST/SEED_INPUT_JSONS/2025-10-01/INPUT_SEIHRD-STOCH_Delaware_SEED_NONE.json \
  --output-dir Example_TEST/epydemix_fit/2025-10-01 \
  --hosp-file data/FLU_HUB/time-series_2026-07-13.csv \
  --fit-target hosp_incident \
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
  --fit-target hosp_incident \
  --nsim 1000 \
  --top-fraction 0.05 \
  --write-calibrated-json
```

The script writes `posterior_samples.csv`, `best_parameters.json`,
`best_fit_timeseries.csv`, and, when requested, a calibrated simulator JSON copy
under `<PIPELINE_OUTPUT_DIR>/epydemix_fit/`. In `--all-states` mode, each input JSON
gets its own subdirectory under the date-specific output directory, and a
`batch_manifest.json` summarizes successes and failures.

To compare the two hospitalization targets without losing current results, keep
the current `hosp_incident` run in its existing output directory and run the
older target into a sibling directory:

```bash
Rscript scripts/0_run_full_pipeline_US.R \
  --sim-day-0=2025-10-04 \
  --output-dir=STATE_WKLYFIT_H_INCREASE_COMPARE \
  --epydemix-fit-target=hosp_increase
```

Each calibrated JSON records `metadata_tags.epydemix_fit.fit_target` and
`generated_metric`, so downstream summaries can distinguish the calibration
target used for a result set.

The repository does not currently include a separate Read the Docs source tree;
keep this file and `../data/README.md` in sync when script behavior, generated
input fields, or model-family template rules change.
