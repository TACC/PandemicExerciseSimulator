# County-Age High-Risk Ratio Derivation

This page documents how the simulator's county- and age-specific high-risk
ratios are constructed from state-level survey estimates and county-level
comorbidity burden. These values are model inputs, not fitted simulator code.

In the simulator, high risk means higher risk of hospitalization or death after
infection. It does not mean higher risk of becoming infected.

The generated input files are:

```text
data/<STATE>/state_<STATE>_high-risk-ratios-flu-only.csv
data/<STATE>/county_<STATE>_high-risk-ratios-flu-only.csv
```

## State Age Estimates

The state-level high-risk proportion is estimated separately for each of the
five simulator age groups:

| Simulator age group | Primary source |
| --- | --- |
| 0-4 | National Survey of Children's Health |
| 5-17 | National Survey of Children's Health |
| 18-49 | Behavioral Risk Factor Surveillance System |
| 50-64 | Behavioral Risk Factor Surveillance System |
| 65+ | Behavioral Risk Factor Surveillance System |

The adult estimates use BRFSS conditions associated with severe influenza
outcomes. The pediatric estimates use NSCH survey weights and pediatric
conditions associated with severe influenza outcomes. The condition set follows
CDC influenza high-risk guidance as closely as the source surveys allow.

Let $s$ index states and $a$ index simulator age groups. The state survey stage
produces:

```{math}
r_{s,a}^{state},
```

the estimated proportion of people in state $s$ and age group $a$ who are in
the influenza high-risk hospitalization group.

## County Burden Adjustment

State survey data are not detailed enough to directly estimate stable
county-age high-risk proportions for every county. The county input therefore
starts with the state-age estimate and redistributes relative burden across
counties using CDC PLACES county comorbidity measures.

Let $B_c$ be the county comorbidity burden score after selecting available
PLACES measures, standardizing them, and combining them into a county-level
relative burden index. The county factor is normalized within each state so
that it shifts risk between counties without changing the state-age target:

```{math}
F_c = \frac{B_c}{\sum_{c' \in s} \omega_{c'} B_{c'}},
```

where $\omega_c$ is the county population share used for the state
normalization. A value above 1 means the county has higher comorbidity burden
than the state average; a value below 1 means lower burden.

The provisional county-age high-risk proportion is:

```{math}
\tilde r_{c,a} = r_{s,a}^{state} F_c.
```

The final value is bounded to remain a valid proportion:

```{math}
r_{c,a} = \min\left(\max\left(\tilde r_{c,a}, 0\right), 1\right).
```

The resulting county values are hypothesis-driven allocations of state-level
risk to counties. They are intended to give the simulator county-specific
hospitalization-risk structure when county-age survey estimates are not
available.

## Interpretation

The county high-risk ratio affects how each county-age population is split
between low-risk and high-risk hospitalization groups:

```{math}
N_{c,a}^{high} = N_{c,a} r_{c,a}
```

```{math}
N_{c,a}^{low} = N_{c,a} \left(1-r_{c,a}\right).
```

Those groups then use the simulator's high-risk and low-risk disease
progression probabilities. The high-risk ratio does not modify contact rates,
mobility, susceptibility, or the probability of initial exposure unless a
separate input derivation explicitly uses it.

## Relationship To Initial Exposure Fitting

The county-age initial exposure fitting method uses $r_{c,a}$ to estimate
low-risk county-age population:

```{math}
L_{c,a} = N_{c,a}\left(1-r_{c,a}\right).
```

That makes the high-risk-ratio file an input to the external allocation math
used for the Delaware example. The allocation itself is documented in
[County-Age Initial Exposure Fitting](county-age-initialization.md).

## Producing The Files

The files are produced by the input-preparation scripts:

| Step | Script | Result |
| --- | --- | --- |
| 4a | `scripts/4a_flu_state_high_risk_by_age.R` | State-and-age influenza high-risk proportions from BRFSS and NSCH. |
| 4b | `scripts/4b_flu_county_high_risk_by_age.R` | County-age high-risk ratios using the state estimates and CDC PLACES burden. |

The script provenance and full input pipeline are summarized in
[Data Preparation And Analysis Scripts](../developer/scripts.md).
