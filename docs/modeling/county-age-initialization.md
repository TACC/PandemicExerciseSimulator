# County-Age Initial Infection Fitting

This page documents the Delaware manuscript example used to derive county- and age-specific initial conditions from state-level incident influenza hospitalization data.

The simulator input field is named `initial_infected`, but for SEIHRD-family models the current implementation places those people in the low-risk, unvaccinated `E` compartment. The quantities below are therefore low-risk-equivalent initial exposed people, indexed by county and age group.

## Delaware Example

The example starts simulations on August 9, 2025 and uses the Delaware age-stratified incident hospitalization time series from the Flu Scenario Modeling Hub target data archive. Delaware has three counties in the simulator population file:

| County FIPS | County |
| --- | --- |
| `10001` | Kent |
| `10003` | New Castle |
| `10005` | Sussex |

The script `scripts/6b_derive_initial_infections.R` estimates an initial exposure table and writes a complete runnable test input under `data/Delaware_TEST/`.

## State Hospitalizations To State Initial Exposed

Let $a$ index the five simulator age groups and let $H_a^{obs}$ be observed state-level incident hospitalizations in the calibration window beginning at simulation day 0. In the default Delaware example, the calibration window is the first eight weekly observations beginning August 9, 2025.

For a low-risk exposed person in age group $a$, the approximate probability of eventually entering `H` is:

```{math}
q_a = (1 - p_{A,a}) p_{H,L,a},
```

where:

- $p_{A,a}$ is `prop_E_to_IA`, the probability that an exposed person follows the asymptomatic path;
- $p_{H,L,a}$ is `prop_IS_to_H_lowrisk`, the low-risk realized hospitalization probability among symptomatic infectious people.

The statewide low-risk-equivalent exposed count is then:

```{math}
\tilde E_{0,a}^{state} = \frac{H_a^{obs}}{q_a}.
```

The script rounds this value and applies a configurable floor only when the calibration window contains at least one hospitalization for that age group:

```{math}
E_{0,a}^{state} =
\max\left(
\operatorname{round}(\tilde E_{0,a}^{state}),
\mathbf{1}[H_a^{obs} > 0]E_{min}
\right).
```

For the Delaware baseline parameters:

| Age group | `prop_E_to_IA` | `prop_IS_to_H_lowrisk` | $q_a$ |
| --- | ---: | ---: | ---: |
| 0-4 | 0.25 | 0.0132 | 0.009900 |
| 5-17 | 0.25 | 0.0099 | 0.007425 |
| 18-49 | 0.30 | 0.0295 | 0.020650 |
| 50-64 | 0.30 | 0.0594 | 0.041580 |
| 65+ | 0.30 | 0.0802 | 0.056140 |

In the first eight weeks after August 9, 2025, Delaware has two observed incident hospitalizations in ages 0-4 and two in ages 65+. The resulting state-level initial exposed estimates are:

| Age group | $H_a^{obs}$ | $E_{0,a}^{state}$ |
| --- | ---: | ---: |
| 0-4 | 2 | 202 |
| 5-17 | 0 | 0 |
| 18-49 | 0 | 0 |
| 50-64 | 0 | 0 |
| 65+ | 2 | 36 |

## State Initial Exposed To Counties

Let $c$ index counties. The county allocation uses low-risk county population by age and a mild county mobility centrality term:

```{math}
w_{c,a} = L_{c,a}^{\alpha} M_c^{\delta},
```

where:

- $L_{c,a} = N_{c,a}(1-r_{c,a})$ is the low-risk population in county $c$ and age group $a$;
- $N_{c,a}$ is county population;
- $r_{c,a}$ is the county high-risk ratio;
- $M_c$ is normalized outbound county mobility for the simulation-start quarter;
- $\alpha$ is the population exponent;
- $\delta$ is the mobility exponent.

This is a dasymetric proportional allocation rather than a fully fitted county-level epidemic model. The state-level hospitalization signal identifies $E_{0,a}^{state}$, and the county weights distribute that age-specific total using available ancillary information.

### Population Exponent

The population exponent $\alpha$ controls how strongly initial exposed people follow the county-age low-risk population. If county A has twice the low-risk population of county B in the same age group, and mobility is equal, then:

```{math}
\frac{w_{A,a}}{w_{B,a}} = 2^{\alpha}.
```

Interpretation:

| $\alpha$ | Effect |
| ---: | --- |
| 0 | Ignores county-age population; counties receive equal population weight before mobility. |
| 0.5 | Sublinear population weighting; larger counties receive more exposures, but less than proportional. |
| 1 | Proportional low-risk population allocation. This is the Delaware default. |
| >1 | Superlinear population weighting; larger counties receive disproportionately more exposures. |

The manuscript default $\alpha=1$ is the most transparent assumption: absent county-level infection surveillance, the expected number of initial exposures is proportional to the eligible low-risk county-age population.

### Mobility Exponent

The mobility exponent $\delta$ controls how much the allocation favors counties with greater normalized outbound mobility. If county A has twice the normalized mobility of county B, and low-risk population is equal, then:

```{math}
\frac{w_{A,a}}{w_{B,a}} = 2^{\delta}.
```

Interpretation:

| $\delta$ | Effect |
| ---: | --- |
| 0 | Ignores mobility; allocation uses only population weighting. |
| 0.25 | Mild mobility preference. A two-fold mobility difference gives only a $2^{0.25}\approx1.19$-fold weight difference. This is the Delaware default. |
| 1 | Mobility-proportional weighting. A two-fold mobility difference gives a two-fold weight difference. |
| >1 | Strong mobility concentration in more connected counties. |

The default $\delta=0.25$ keeps mobility as a secondary modifier rather than allowing mobility to dominate population. This is useful for an illustrative early-season exposure initializer because population is the better-measured denominator, while mobility centrality is an ancillary spatial-risk signal.

County exposures are allocated by normalized weights:

```{math}
\hat E_{0,c,a} = E_{0,a}^{state}
\frac{w_{c,a}}{\sum_{c'} w_{c',a}}.
```

The final integer table uses largest-remainder apportionment within each age group so that county totals preserve the state total exactly:

```{math}
\sum_c E_{0,c,a} = E_{0,a}^{state}.
```

### Sensitivity To Exponent Choices

The table below shows how Delaware county allocations change under three exponent choices. The `State age total matched` column is the $E_{0,a}^{state}$ value being distributed, and each scenario column sums to that value within age group. For example, the three county rows for ages 0-4 sum to 202 in every scenario, and the three county rows for ages 65+ sum to 36 in every scenario.

| County FIPS | Age group | State age total matched | $\alpha=1,\delta=0.25$ default | $\alpha=1,\delta=1$ | $\alpha=0.5,\delta=1$ |
| --- | --- | ---: | ---: | ---: | ---: |
| `10001` | 0-4 | 202 | 41 | 44 | 59 |
| `10003` | 0-4 | 202 | 119 | 123 | 97 |
| `10005` | 0-4 | 202 | 42 | 35 | 46 |
| `10001` | 65+ | 36 | 6 | 6 | 9 |
| `10003` | 65+ | 36 | 18 | 19 | 16 |
| `10005` | 65+ | 36 | 12 | 11 | 11 |

## Generated Initial Conditions

The default script writes the following `initial_infected` entries for the Delaware test input:

```json
[
  {"county": "10001", "infected": "41", "age_group": "0"},
  {"county": "10003", "infected": "119", "age_group": "0"},
  {"county": "10005", "infected": "42", "age_group": "0"},
  {"county": "10001", "infected": "6", "age_group": "4"},
  {"county": "10003", "infected": "18", "age_group": "4"},
  {"county": "10005", "infected": "12", "age_group": "4"}
]
```

The total initial low-risk exposed count is 238. The nonzero age groups reflect the hospitalization signal in the first eight weeks after the simulation start date; this is an intentionally conservative early-season initializer, not a full posterior calibration.

## Generated Files

Running `scripts/6b_derive_initial_infections.R` writes:

```text
data/Delaware/derived_initial_infected_Delaware_2025-08-09.csv
data/Delaware/derived_initial_infected_Delaware_2025-08-09.json
data/Delaware/derived_initial_infected_Delaware_2025-08-09_method.csv
data/Delaware_TEST/INPUT_SEIHRD-STOCH_Delaware_TEST_R0-2.2_BASELINE.json
```

The `Delaware_TEST` directory is ignored by git because it is a generated local test artifact.
