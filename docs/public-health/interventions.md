# Interventions

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

`location` can be a comma-separated list of county FIPS values. An
effectiveness of `0.9` means transmission for that age group is reduced by 90%
while the intervention is active.

## Vaccines

Vaccines are released from a stockpile and assigned to age/risk groups. The
`age_risk_priority_groups` parameter uses:

- `0`: nobody in that age group is eligible;
- `0.5`: high-risk people in that age group are eligible;
- `1`: everyone in that age group is eligible.

Vaccinated people move from the unvaccinated subgroup to the vaccinated
subgroup. Vaccine effectiveness is applied in disease and travel calculations.

## Antivirals

Anyone in compartment `T` is assumed to be receiving an antiviral. The
stockpile model moves eligible people into `T` according to available doses,
age/risk eligibility, daily capacity, and compartment priority.

As with vaccination, each `age_risk_priority_groups` value means:

- `0.0`: no one in that age group is eligible;
- `0.5`: only high-risk people in that age group are eligible;
- `1.0`: everyone in that age group is eligible.

The list must have one value per age group. For example,
`["0.0", "0.5", "1.0", "1.0", "0.5"]` excludes the first age group, targets
only high-risk people in the second and fifth groups, and targets everyone in
the third and fourth groups.

Common eligible compartments are:

- SEITRS: `E` and `I`;
- SEITHRD: `E`, `IA`, `IP`, and `IS`;
- Gillespie SEATIRD: `E`, `A`, and `I`.

```json
"antiviral_model": {
  "identity": "stockpile-age-risk",
  "parameters": {
    "age_risk_priority_groups": ["1", "1", "1", "1", "1"],
    "eligible_compartments": ["E", "I"],
    "compartment_priority": ["I", "E"],
    "antiviral_capacity_proportion": "1.0",
    "antiviral_half_life_days": null,
    "antiviral_stockpile": [
      {"day": "0", "amount": "1000"}
    ]
  }
}
```

For SEITRS and SEITHRD, no one enters `T` without stockpile allocation. Their
disease parameters control treated progression and infectiousness through
`T_to_R_days`, `rel_inf_T_to_I`, or `rel_inf_T_to_IS`.

SEATIRD is different: its queued infection trajectory already includes an
`A -> T` treatment event, so people may receive antiviral treatment without a
configured stockpile. Adding the stockpile model creates additional
resource-constrained treatment routes from `E`, `A`, or `I` into `T`. Treated
SEATIRD trajectories then follow `T -> I`, `T -> R`, or `T -> D` using `chi`,
`gamma`, and `nu`.

See [Antiviral Stockpile Model](../modeling/antivirals.md) for all parameter
defaults, validation rules, allocation behavior, and model-specific examples.
