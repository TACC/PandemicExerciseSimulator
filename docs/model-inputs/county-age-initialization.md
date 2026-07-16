# County-Age Initial Exposure Fitting

This page documents the external initializer implemented by
`scripts/6b_derive_initial_exposures.R`. The script derives state/DC
age-specific initial exposed counts from incident influenza hospitalization
data, allocates those counts to counties, and writes simulator-ready test
inputs.

The simulator input field is named `initial_exposed`. The implementation places
those people in the low-risk, unvaccinated `E` compartment. The quantities
below are therefore low-risk-equivalent initial exposed people, indexed by
county and age group.

## Scope And Defaults

The current script runs all states and DC by default. Its default settings are:

| Setting | Default |
| --- | --- |
| Simulation start | `2025-08-09` |
| Hospitalization source | `data/Flu-Hub-Data/time-series_2026-07-13.csv` |
| Template input | `data/INPUT_FILE_TEMPLATES/INPUT_SEIHRD-STOCH_ANTIVIRAL.json` |
| Output directory | `STATE_INIT_TEST/` |
| Population exponent | `1.0` |
| Mobility exponent | `0.25` |
| Minimum timing weight | `0.25` |
| Minimum active state-age exposed count | `1` |

The hospitalization source is the Flu Scenario Modeling Hub time-series file.
The script uses age-stratified `inc hosp` observations, excludes the aggregate
`0-130` age group, and maps `65-130` to the simulator's `65+` age group.

## State Hospitalizations To State Initial Exposed

Let $s$ index states and $a$ index the five simulator age groups. For each
state-age pair, the script finds the first strictly positive incident
hospitalization observation on or after simulation day 0:

```{math}
H_{s,a}^{first}.
```

If no positive observation appears for a state-age pair, that pair receives
zero initial exposures. The script still writes a complete state-age summary
row with zero hospitalization signal and zero initial exposed people.

For a low-risk exposed person in age group $a$, the approximate probability of
eventually entering `H` is:

```{math}
q_a = (1 - p_{A,a}) p_{H,L,a},
```

where:

- $p_{A,a}$ is `prop_E_to_IA`, the probability that an exposed person follows
  the asymptomatic path;
- $p_{H,L,a}$ is `prop_IS_to_H_lowrisk`, the low-risk realized
  hospitalization probability among symptomatic infectious people.

The expected time from exposure to hospitalization is read from the template:

```{math}
d_{E \rightarrow H} =
d_{E \rightarrow IP/IA} + d_{IP \rightarrow IS} + d_{IS \rightarrow H}.
```

The default antiviral template gives:

```{math}
d_{E \rightarrow H} = 0.7 + 0.9 + 3.74 = 5.34 \text{ days}.
```

The script converts this to a weekly exponential timing rate:

```{math}
\lambda = \frac{1}{d_{E \rightarrow H}/7}.
```

If the first positive hospitalization occurs $t_{s,a}$ weeks after the
simulation start, its timing weight is:

```{math}
\tau_{s,a} =
\tau_{min} + (1-\tau_{min})\exp(-\lambda t_{s,a}),
```

where $\tau_{min}=0.25$ by default. This keeps later first observations from
implying as many day-0 exposures as observations close to simulation start,
while still giving them a nonzero floor.

The effective hospitalization signal and state-level exposed estimate are:

```{math}
H_{s,a}^{eff} = H_{s,a}^{first}\tau_{s,a}
```

```{math}
\tilde E_{0,s,a}^{state} = \frac{H_{s,a}^{eff}}{q_a}.
```

The integer state-age total is rounded and bounded below only for active
state-age pairs:

```{math}
E_{0,s,a}^{state} =
\max\left(
\operatorname{round}(\tilde E_{0,s,a}^{state}),
\mathbf{1}[H_{s,a}^{first} > 0]E_{min}
\right).
```

The default $E_{min}$ is 1.

For the default antiviral template:

| Age group | `prop_E_to_IA` | `prop_IS_to_H_lowrisk` | $q_a$ |
| --- | ---: | ---: | ---: |
| 0-4 | 0.25 | 0.0132 | 0.009900 |
| 5-17 | 0.25 | 0.0099 | 0.007425 |
| 18-49 | 0.30 | 0.0295 | 0.020650 |
| 50-64 | 0.30 | 0.0594 | 0.041580 |
| 65+ | 0.30 | 0.0802 | 0.056140 |

## State Initial Exposed To Counties

Let $c$ index counties. For each state and age group, the script allocates the
state-age total to counties using low-risk county-age population and a county
mobility multiplier:

```{math}
w_{c,a} = L_{c,a}^{\alpha} M_c^{\delta},
```

where:

- $L_{c,a} = N_{c,a}(1-r_{c,a})$ is the low-risk population in county $c$ and
  age group $a$;
- $N_{c,a}$ is county population;
- $r_{c,a}$ is the county high-risk ratio;
- $M_c$ is county total population outflow divided by the state mean county
  total population outflow for the simulation-start quarter;
- $\alpha$ is `POPULATION_POWER`, default `1.0`;
- $\delta$ is `MOBILITY_POWER`, default `0.25`.

The mobility rank file is filtered to the calendar quarter containing
simulation day 0. With the default August 9 start date, this is quarter 3.
Missing high-risk ratios are treated as 0, and missing mobility multipliers are
treated as 1.

County exposures are allocated by normalized weights:

```{math}
\hat E_{0,c,a} = E_{0,s,a}^{state}
\frac{w_{c,a}}{\sum_{c' \in s} w_{c',a}}.
```

The final integer table uses largest-remainder apportionment within each
state-age group so county totals preserve the state-age total exactly:

```{math}
\sum_{c \in s} E_{0,c,a} = E_{0,s,a}^{state}.
```

Rows with zero allocated exposures are omitted from the generated
`initial_exposed` JSON array.

## Delaware Example

Delaware has three counties in the simulator population file:

| County FIPS | County |
| --- | --- |
| `10001` | Kent |
| `10003` | New Castle |
| `10005` | Sussex |

Under the current default script and the `time-series_2026-07-13.csv`
hospitalization file, Delaware's first positive observations after
August 9, 2025 produce the following state-age estimates:

| Age group | First positive date | First hosp count | Weeks from start | Timing weight | Effective hosps | State initial exposed |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 0-4 | 2025-09-20 | 2 | 6 | 0.250288 | 0.500576 | 51 |
| 5-17 | 2025-11-15 | 1 | 14 | 0.250000 | 0.250000 | 34 |
| 18-49 | 2025-11-08 | 1 | 13 | 0.250000 | 0.250000 | 12 |
| 50-64 | 2025-11-08 | 1 | 13 | 0.250000 | 0.250000 | 6 |
| 65+ | 2025-08-30 | 2 | 3 | 0.264695 | 0.529389 | 9 |

The resulting Delaware county-age allocation is:

| County FIPS | Age group | State age total matched | Initial exposed |
| --- | --- | ---: | ---: |
| `10001` | 0-4 | 51 | 10 |
| `10003` | 0-4 | 51 | 30 |
| `10005` | 0-4 | 51 | 11 |
| `10001` | 5-17 | 34 | 7 |
| `10003` | 5-17 | 34 | 20 |
| `10005` | 5-17 | 34 | 7 |
| `10001` | 18-49 | 12 | 2 |
| `10003` | 18-49 | 12 | 8 |
| `10005` | 18-49 | 12 | 2 |
| `10001` | 50-64 | 6 | 1 |
| `10003` | 50-64 | 6 | 3 |
| `10005` | 50-64 | 6 | 2 |
| `10001` | 65+ | 9 | 1 |
| `10003` | 65+ | 9 | 5 |
| `10005` | 65+ | 9 | 3 |

The Delaware `initial_exposed` entries written to the generated input JSON are:

```json
[
  {"county": "10001", "infected": "10", "age_group": "0"},
  {"county": "10003", "infected": "30", "age_group": "0"},
  {"county": "10005", "infected": "11", "age_group": "0"},
  {"county": "10001", "infected": "7", "age_group": "1"},
  {"county": "10003", "infected": "20", "age_group": "1"},
  {"county": "10005", "infected": "7", "age_group": "1"},
  {"county": "10001", "infected": "2", "age_group": "2"},
  {"county": "10003", "infected": "8", "age_group": "2"},
  {"county": "10005", "infected": "2", "age_group": "2"},
  {"county": "10001", "infected": "1", "age_group": "3"},
  {"county": "10003", "infected": "3", "age_group": "3"},
  {"county": "10005", "infected": "2", "age_group": "3"},
  {"county": "10001", "infected": "1", "age_group": "4"},
  {"county": "10003", "infected": "5", "age_group": "4"},
  {"county": "10005", "infected": "3", "age_group": "4"}
]
```

The total Delaware initial low-risk exposed count is 112. The value is an
early-season initializer derived from the first observed age-stratified
hospitalization signal, not a posterior calibration of the full epidemic
trajectory.

## Generated Files

Running `scripts/6b_derive_initial_exposures.R` writes:

```text
STATE_INIT_TEST/derived_initial_exposed_state_age_2025-08-09.csv
STATE_INIT_TEST/derived_initial_exposed_county_age_2025-08-09.csv
STATE_INIT_TEST/INPUT_JSONS/INPUT_SEIHRD-STOCH_<STATE>_INIT_TEST_ANTIVIRAL.json
```

Each generated JSON is copied from the antiviral template, has `STATE` tokens
replaced with the state directory name, sets `output_dir_path` to
`<STATE>_INIT_TEST`, sets `batch_num` to `0`, appends a metadata note describing
the initialization source, and replaces `initial_exposed` with the derived
county-age rows for that state.

The output directory is a generated test artifact and is not part of the
canonical state input directories under `data/<STATE>/`.
