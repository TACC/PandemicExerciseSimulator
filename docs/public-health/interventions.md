# Interventions

Interventions are configured in the simulation input JSON. Age-specific lists
must contain one value per age group and use the same age-group order as the
population and disease-model data.

## Non-Pharmaceutical Interventions

NPIs reduce transmission by age group for specified days and locations.

```json
"non_pharma_interventions": [
  {
    "name": "School Closure",
    "day": "20",
    "duration": "10",
    "location": "48113,48141",
    "effectiveness": ["0.9", "0.9", "0.0", "0.0", "0.0"]
  }
]
```

| Parameter | Required | Description |
| --- | --- | --- |
| `name` | Yes | Human-readable intervention name retained with the scenario configuration. |
| `day` | Yes | Integer simulation day on which the intervention begins. Day 0 is the first simulation day. |
| `duration` | Yes | Number of consecutive days the intervention remains active. |
| `location` | Yes | Comma-separated county or node identifiers. Use `"0"` to apply the intervention to every node. |
| `effectiveness` | Yes | Transmission reduction for each age group, expressed from `0.0` to `1.0`. A value of `0.9` reduces transmission for that age group by 90%. |

When interventions overlap, their effectiveness is combined as:

```{math}
E_{\mathrm{combined}} = E_A + (1-E_A)E_B.
```

For example, two overlapping interventions with effectiveness `0.5` produce a
combined effectiveness of `0.75`, not `1.0`.

## Vaccines

The supported vaccine model identity is `stockpile-age-risk`. It releases
doses from a stockpile and vaccinates susceptible people according to age,
hospitalization-risk group, adherence, and daily capacity.

Matching observed coverage and vaccine effectiveness can require additional
fitting. The generated state influenza schedules use a simplified
fully-protected-equivalent approach:

1. set modeled effectiveness against infection to `1.0`;
2. multiply observed coverage by the strain-season effectiveness estimate;
3. release that reduced number as the effective stockpile.

For example, 100 observed vaccinations with 20% effectiveness become 20
modeled doses with 100% effectiveness. This avoids applying the same
effectiveness twice. For custom scenarios, users may instead release all 100
doses and set `vaccine_effectiveness` to `0.2`.

Vaccine effectiveness is used by the disease and travel models. When no
effectiveness values are configured, both default to age-specific zeros.

```json
"vaccine_model": {
  "identity": "stockpile-age-risk",
  "parameters": {
    "age_risk_priority_groups": ["0.0", "0.5", "1.0", "1.0", "0.5"],
    "vaccine_adherence": ["0.70", "0.75", "0.80", "0.85", "0.90"],
    "vaccine_effectiveness": ["0.50", "0.50", "0.50", "0.50", "0.50"],
    "vaccine_effectiveness_hosp": ["0.80", "0.80", "0.80", "0.80", "0.80"],
    "vaccine_capacity_proportion": "0.10",
    "vaccine_eff_lag_days": "14",
    "vaccine_half_life_days": "60",
    "vaccine_stockpile": [
      {"day": "0", "amount": "1000"},
      {"day": "30", "amount": "500"}
    ]
  }
}
```

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `identity` | Yes | None | Vaccine allocation strategy. The supported value is `"stockpile-age-risk"`. |
| `age_risk_priority_groups` | No | All `1.0` | Eligibility for each age and hospitalization-risk group. Allowed values are `0.0`, `0.5`, and `1.0`, as defined below. |
| `vaccine_adherence` | Yes for stockpile allocation | None | Proportion of each age group willing to be vaccinated, from `0.0` to `1.0`. Supply beyond the adhering eligible population rolls forward. |
| `vaccine_effectiveness` | No | All `0.0` | Age-specific reduction in susceptibility to infection, from `0.0` to `1.0`. |
| `vaccine_effectiveness_hosp` | No | All `0.0` | Age-specific reduction in hospitalization risk, from `0.0` to `1.0`. Used by disease models that include hospitalization, such as SEIHRD and SEITHRD. |
| `vaccine_capacity_proportion` | No | `1.0` | Maximum fraction of a node's total population that can be vaccinated per day. |
| `vaccine_eff_lag_days` | No | `0` | Nonnegative number of days between a stockpile release and its effective availability. Negative values are changed to 0. |
| `vaccine_half_life_days` | No | `null` | Positive stockpile half-life in days. Use `null` to disable decay. This affects unused doses, not vaccinated people. |
| `vaccine_stockpile` | No | Empty list | Doses released. Each entry requires an integer simulation `day` and a dose `amount`. Entries with the same effective day are combined. |

The `age_risk_priority_groups` values mean:

| Value | Eligible people in that age group |
| --- | --- |
| `0.0` | No one. |
| `0.5` | People in the high-risk hospitalization group only. |
| `1.0` | Everyone in both low- and high-risk hospitalization groups. |

Vaccination moves people from the unvaccinated susceptible subgroup to the
corresponding vaccinated susceptible subgroup. It does not directly move
people between disease compartments, and vaccine protection does not currently
wane. Disease compartments are time-varying states; age, risk, and vaccination
group are demographic attributes retained throughout the simulation.

Stockpile `day` is the release day, while
`day + vaccine_eff_lag_days` is the day those doses become effective and
available for allocation. Unused doses roll forward to the next simulation
day.

The strategy first divides a release among nodes in proportion to each node's
eligible population. Within a node, it then allocates doses among eligible
age/risk groups. Population-size allocation and age/risk targeting are
therefore two stages of the same `stockpile-age-risk` strategy, not separate
model identities.

`vaccine_adherence` is a lifetime ceiling for each age group. A value of `0.6`
means at most 60% of that age group can be moved into the vaccinated subgroup,
even if additional stock remains.

Initial infections are seeded into the unvaccinated exposed group and cannot
be vaccinated. For example, if 100 of 1,000 people are initialized in `E`, no
more than the remaining 900 susceptible people can receive day-0 vaccine,
before applying age/risk eligibility and adherence limits.

A seasonal campaign does not require a separate vaccination model. Represent
it as a sequence of dated `vaccine_stockpile` releases. Release days may be
negative when a campaign begins before simulation day 0; after applying
`vaccine_eff_lag_days`, any effective day before zero is reassigned to day 0.

## Antivirals

The supported antiviral model identity is `stockpile-age-risk`. Anyone in
compartment `T` is **Treated** and assumed to be receiving an antiviral. The
stockpile model moves eligible people into `T` according to available doses,
age/risk eligibility, daily capacity, and compartment priority.

Allow `E` to receive antivirals when modeling post-exposure prophylaxis or
treatment of exposed close contacts. For treatment after symptom onset,
prioritize `I` in SEITRS or `IS` in SEITHRD. CDC guidance notes that clinical
benefit is greatest when influenza antivirals are administered early,
especially within 48 hours of illness onset; see the
[CDC clinician summary](https://www.cdc.gov/flu/hcp/antivirals/summary-clinicians.html).

The daily compartment models do not prioritize people by time already spent in
an eligible compartment. Scenario parameters can account for delayed or
incomplete treatment through stockpile timing, capacity, eligibility,
`rel_inf_T_to_I` or `rel_inf_T_to_IS`, and `T_to_R_days`.

```json
"antiviral_model": {
  "identity": "stockpile-age-risk",
  "parameters": {
    "age_risk_priority_groups": ["0.0", "0.5", "1.0", "1.0", "0.5"],
    "eligible_compartments": ["E", "I"],
    "compartment_priority": ["I", "E"],
    "antiviral_capacity_proportion": "0.10",
    "antiviral_half_life_days": "30",
    "antiviral_stockpile": [
      {"day": "0", "amount": "1000"},
      {"day": "14", "amount": "500"}
    ]
  }
}
```

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `identity` | Yes | None | Antiviral allocation strategy. The supported value is `"stockpile-age-risk"`. |
| `age_risk_priority_groups` | No | All `1.0` | Eligibility for each age and hospitalization-risk group. Allowed values are `0.0`, `0.5`, and `1.0`, with the same meanings as vaccination. |
| `eligible_compartments` | No | `["E", "I"]` | Disease compartments whose members can receive a dose and move into `T`. Every label must exist in the selected disease model. |
| `compartment_priority` | No | `["I", "E"]` | Order in which eligible compartments receive treatment within a demographic group. Every listed compartment must also be eligible. |
| `antiviral_capacity_proportion` | No | `1.0` | Maximum fraction of a node's total population that can begin treatment per day. |
| `antiviral_half_life_days` | No | `null` | Positive stockpile half-life in days. Use `null` to disable decay. This affects unused doses, not people already in `T`. |
| `antiviral_stockpile` | No | Empty list | Dose releases. Each entry requires an integer simulation `day` and a dose `amount`. Same-day entries are combined and negative days are reassigned to day 0. |

Common eligible compartments are:

| Disease model | Eligible-compartment example | Priority example |
| --- | --- | --- |
| SEITRS, stochastic or deterministic | `["E", "I"]` | `["I", "E"]` |
| SEITHRD | `["E", "IA", "IP", "IS"]` | `["IS", "IP", "IA", "E"]` |
| Gillespie SEATIRD | `["E", "A", "I"]` | `["I", "A", "E"]` |

The stockpile parameters control movement **into** `T`. Disease model
parameters control what happens after treatment begins:

| Disease parameter | Model | Description |
| --- | --- | --- |
| `T_to_R_days` | SEITRS and SEITHRD | Average number of days from treated to recovered. |
| `rel_inf_T_to_I` | SEITRS | Infectiousness of `T` relative to untreated `I`. |
| `rel_inf_T_to_IS` | SEITHRD | Infectiousness of `T` relative to symptomatic `IS`. |
| `chi`, `gamma`, and `nu` | SEATIRD | Existing queued-event parameters governing `T -> I`, `T -> R`, and `T -> D`. |

For SEITRS and SEITHRD, no one enters `T` without stockpile allocation. There
are no disease-rate parameters that move people into treatment.

SEATIRD is different: its queued Gillespie trajectory already includes a
possible `A -> T` treatment event, even without a configured stockpile. Adding
the stockpile model creates additional resource-constrained routes from `E`,
`A`, or `I` into `T`.

See [Antiviral Stockpile Model](../modeling/antivirals.md) for validation rules,
allocation behavior, and model-specific details.
