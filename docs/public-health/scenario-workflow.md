# Scenario Workflow

A practical scenario workflow is shown below using District of Columbia as an
example.

## 0. Create A Test Workspace

Create a top-level directory whose name ends in `_TEST`:

```bash
mkdir District-of-Columbia_TEST
```

The repository's `.gitignore` excludes `*_TEST/`, so input experiments,
generated scenario directories, `metadata_master.csv`, and Parquet files stay
out of Git and do not clutter the repository root.

Copy a starting input into the workspace:

```bash
cp data/District-of-Columbia/INPUT_SEIHRD-STOCH_District-of-Columbia_R0-2.2_BASELINE.json \
  District-of-Columbia_TEST/
cd District-of-Columbia_TEST
```

Because the simulator will run from this directory, data paths in the copied
input should use:

```json
"population": "../data/District-of-Columbia/county_pop_by_age_District-of-Columbia_2019-2023ACS.csv"
```

Use `"GENERATE"` for both `output_dir_path` and `batch_num` so each scenario is
organized by scenario hash and execution UUID.

## 1. Choose A Geography

Verify that all required files exist. For District of Columbia, they are under:

```text
data/District-of-Columbia/
```

The example uses its population, contact, Q4 mobility, and high-risk-ratio
files. District of Columbia has one county-equivalent, which makes it useful
for fast model checks. Delaware is another small option when testing
multi-county travel.

## 2. Choose A Disease Model

Select a model identity and its exact compartment list. For example, a
baseline SEIHRD scenario uses:

```json
"identity": "seihrd-stochastic",
"compartments": ["S", "E", "IA", "IP", "IS", "H", "R", "D"]
```

An antiviral SEITHRD comparison adds `T`:

```json
"compartments": ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"]
```

## 3. Set Disease Parameters

Choose `R0`, durations, branching proportions, and relative infectiousness
values appropriate to the selected model. For example:

```json
"R0": "2.2",
"E_to_IPandIA_days": "0.7",
"IP_to_IS_days": "0.9",
"rel_inf_IP_to_IS": "0.45",
"rel_inf_IA_to_IS": "0.97"
```

For an antiviral SEITHRD scenario, also define treated progression and
infectiousness, such as:

```json
"T_to_R_days": "5",
"rel_inf_T_to_IS": "0.5"
```

## 4. Choose Travel Assumptions

Select a mobility matrix and identify which compartments travel and transmit.
For example, use the District of Columbia Q4 matrix:

```json
"flow": "../data/District-of-Columbia/District-of-Columbia_Q4-2019_mobility-matrix.csv"
```

SEIHRD travel settings might include:

```json
"traveling_compartments": {
  "IA": "0.97",
  "IP": "0.45"
},
"transmitting_compartments": {
  "IA": "0.97",
  "IP": "0.45",
  "IS": "1.0"
}
```

Travel does not migrate residents between counties. The dictionaries weight
infectious people who travel to another node and infectious residents who
expose incoming visitors, respectively. See
[Binomial Travel Model](../modeling/travel.md) for the full distinction.

When testing a model with `T`, decide whether treated people travel and include
their relative transmission contribution.

## 5. Add One Intervention

Keep the first comparison easy to interpret. For example, add an antiviral
stockpile while leaving vaccination and NPIs empty:

```json
"antiviral_stockpile": [
  {"day": "10", "amount": "100"}
],
"vaccine_model": {},
"non_pharma_interventions": []
```

Run separate comparisons for changes in release timing, amount, eligibility,
or compartment priority instead of changing all of them at once.

## Plan Runtime And Realizations

```{warning}
Runtime can increase substantially with the number of counties, population
size, simulation days, and realizations. Start with a small geography and a
short run before launching a full scenario set.
```

County count matters because the travel model evaluates movement and
transmission among county pairs. District of Columbia is useful for checking
disease-model behavior because it has one county-equivalent. Delaware is a
small three-county test of both disease and travel behavior. Large states such
as Texas take much longer.

The Gillespie SEATIRD model schedules individual events. Its runtime grows
poorly with realistic population sizes and large epidemics, so use small
populations or short, carefully targeted validation runs before attempting
population-scale scenarios.

“Deterministic” currently describes the disease-progression model, not the
entire simulation. The travel model still draws new exposures from a binomial
distribution. A deterministic disease scenario can therefore produce different
final outputs across realizations, although it has less stochastic variation
than a fully stochastic disease model.

### Do Not Use One Realization For The Dashboard

A single realization is useful for a quick smoke test, but it writes one JSON
file per simulated day under `output_sim<id>/`. That output format is not
ingested by `scripts/7a_process_output_to_db.R` and cannot be visualized by
`scripts/7b_sim_dashboard_app.R`.

Use at least two realizations when validating the `7a`/`7b` workflow. For a
first epidemiological review, run approximately 5 to 100 realizations,
depending on runtime:

```json
"realization_range": ["0", "24"]
```

This example runs 25 realizations and produces the batch CSV files expected by
`7a`. Increase the count after reviewing completion time and variability.

### Check That An Epidemic Can Emerge

Before interpreting an intervention, examine the untreated baseline:

- If baseline `R0` is below 1, infections are expected to decline on average.
  An intervention may show little additional benefit because the epidemic
  already tends to die out.
- Even when `R0` is above 1, early stochastic extinction is possible. A small
  seed can disappear before sustained transmission begins.
- Seeding very few infections in a small or rural county may produce many
  realizations with no substantial epidemic, especially when mobility and
  contact opportunities are limited.
- In a low-emergence scenario, hundreds or sometimes 1,000 or more realizations
  may be needed to estimate the probability and distribution of epidemic
  outcomes. Increasing the initial seed or choosing a more connected county
  answers a different scenario question and should be documented as such.

As a rule of thumb, first compare the fraction of baseline realizations that
produce a sustained epidemic, their peak sizes, and their time to peak. Then
compare interventions using enough realizations to distinguish intervention
effects from chance extinction and run-to-run variation.

## 6. Run Baseline And Comparison Scenarios

Run from the ignored test workspace. The relative paths then resolve to the
simulator and state data outside the workspace:

```bash
poetry run python3 ../src/simulator.py \
  -l INFO \
  -d 30 \
  -i INPUT_SEIHRD-STOCH_District-of-Columbia_R0-2.2_BASELINE.json
```

Run the antiviral input with the same duration and logging level. Equivalent
model configurations share a scenario hash; each execution receives a separate
batch UUID.

## 7. Process And Review Outputs

Point `scripts/7a_process_output_to_db.R` at the test workspace:

```r
SEARCH_ROOT  <- normalizePath(file.path(here::here(), "../District-of-Columbia_TEST"))
MASTER_CSV   <- file.path(SEARCH_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(SEARCH_ROOT, "sim_data")
```

Run `7a` to index metadata and create Parquet files. Then configure
`scripts/7b_sim_dashboard_app.R` to use the same workspace:

```r
REPO_ROOT    <- normalizePath(file.path(here::here(), "../District-of-Columbia_TEST"))
MASTER_CSV   <- file.path(REPO_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(REPO_ROOT, "sim_data")
```

Open `7b_sim_dashboard_app.R` in RStudio and select **Run App**. Review:

- completion counts and simulation times;
- baseline and intervention scenario hashes;
- batch UUIDs and metadata;
- network and node compartment trajectories;
- whether the intervention changed the expected compartments and outcomes.

Before deleting large CSV outputs, confirm that the corresponding
`(scenario_hash, batch_num)` rows appear in `metadata_master.csv` and that the
Parquet files exist under `sim_data/<scenario_hash>/<batch_num>/`.

## Recommended Scenario Comparisons

Keep a baseline scenario with no interventions except the initial infections.
Then compare:

- vaccination release timing and prioritization;
- antiviral release timing and prioritization;
- NPI timing, duration, and age targeting;
- mobility reductions;
- alternate initial infection locations.

## Naming Outputs

Use `metadata_tags` to record why an input file and scenario were created:

```json
"metadata_tags": {
  "creator": "YOUR_NAME",
  "disease": ["DISEASE"],
  "sim_day_0": null,
  "notes": ["PLACEHOLDER"]
}
```

These tags are optional notes for people. They do not change simulation
behavior and are not included in the scenario hash. A user may omit
`metadata_tags`, leave it as `{}`, use the conventional keys above, or
add any other JSON-safe keys that help document the scenario.

The supplied templates include:

- `creator`: the person or team responsible for the scenario;
- `disease`: one or more disease labels, such as `["influenza", "flu"]`;
- `sim_day_0`: the calendar date represented by simulation day 0, or `null`
  when the scenario is not tied to a date;
- `notes`: a list of purposes, assumptions, sweep labels, or reminders.

For example, a vaccination scenario tied to the 2024-2025 influenza season
may use:

```json
"metadata_tags": {
  "creator": "YOUR_NAME",
  "disease": ["influenza", "flu"],
  "sim_day_0": "2024-10-01",
  "notes": ["vaccination comparison", "state coverage schedule"]
}
```

The simulator copies the complete tag object into each metadata file.
`scripts/7a_process_output_to_db.R` preserves the complete object as JSON and
also extracts the four conventional fields into `metadata_master.csv`.
`scripts/7b_sim_dashboard_app.R` displays all four fields and allows filtering
by creator and disease tags.
Additional custom keys remain available in `metadata_tags_json`.
