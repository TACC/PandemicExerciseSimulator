# Input Files

Each simulation is controlled by one JSON file. The main sections are:

| Section | Purpose |
| --- | --- |
| `output_dir_path` | Output directory, or `"GENERATE"` for a state-and-scenario-hash directory. |
| `batch_num` | Run identifier, or `"GENERATE"` for a new UUIDv7. |
| `data` | Paths to population, contact, mobility, and risk-ratio files. |
| `disease_model` | Disease model identity and model parameters. |
| `travel_model` | Travel model identity and travel parameters. |
| `initial_exposed` | Seed initial exposed people by county and age group. |
| `non_pharma_interventions` | Optional transmission reductions by day, place, and age. |
| `antiviral_model` | Optional daily antiviral stockpile release strategy. |
| `vaccine_model` | Optional daily vaccine stockpile release strategy. |

## Generated Names

The recommended settings are:

```json
"output_dir_path": "GENERATE",
"batch_num": "GENERATE"
```

`output_dir_path: "GENERATE"` names the directory
`<STATE>_<SCENARIO_HASH>`, for example:

```text
Texas_6a8d...f03c/
```

The state or region label comes from the population-data path. The hash
identifies the canonical scenario, so equivalent configurations receive the
same hash even when numeric values were written as `1` versus `1.0`.

`batch_num: "GENERATE"` assigns a new UUIDv7 to the execution. A scenario may
therefore contain several independently identifiable batches:

```text
Texas_<scenario-hash>/
├── input_batch-<batch-uuid>.json
├── metadata_batch-<batch-uuid>.json
├── network_batch-<batch-uuid>.csv
├── node_<fips>_batch-<batch-uuid>.csv
└── simulation_times_batch-<batch-uuid>.csv
```

The generated batch UUID is separate from the scenario hash. It lets repeated
or split executions of one scenario coexist and be tracked independently.

## Required Data Files

The data directory for a state or region should contain:

- `INPUT_*.json`: Simulation properties file
- `contact_matrix_*_Mistry2021_all.csv`: Age-by-age daily contacts from all settings ("home", "work", "school", "community")
- `county_pop_by_age_*.csv`: County population by age group
- `*_high-risk-ratios-*.csv`: Age-specific high-risk proportions; see
  [County-Age High-Risk Ratio Derivation](../model-inputs/high-risk-ratios.md)
- `*_mobility-matrix.csv`: County-by-county mobility matrix, examples based on pre-pandemic 2019 quarterly SafeGraph proportion population traveling

The order of age groups must match between the population file, contact matrix,
vaccine parameters, antiviral parameters, and any age-specific disease
parameters.

The binomial travel model uses `traveling_compartments` for infectious
residents who expose people at another node and `transmitting_compartments` for
infectious residents who expose visitors at their home node. Travel does not
change node population counts. See
[Binomial Travel Model](../modeling/travel.md) for all parameters and examples.

## Initial Exposures

Initial exposures are placed into the low-risk of hospitalization,
unvaccinated `E` compartment for the requested age group.

```json
"initial_exposed": [
  {
    "county": "48113",
    "infected": "10",
    "age_group": "2"
  }
]
```

If more people are requested than are susceptible in that group, the simulator
only exposes the available susceptible population.

For the Delaware manuscript example that derives county-age initial exposures
from state-level hospitalization observations, see
[County-Age Initial Exposure Fitting](../model-inputs/county-age-initialization.md).
