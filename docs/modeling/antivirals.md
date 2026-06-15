# Antiviral Stockpile Model

Antivirals are modeled as a stockpile-constrained intervention. They move
people from eligible compartments into `T` by allocation, not by a disease-rate
equation. This is intentionally similar to vaccination: a stockpile is released,
distributed to nodes, and then applied within each node according to eligibility
and priority.

For SEITRS, eligible compartments are usually `E` and `I`. For SEITHRD, the
antiviral-capable SEIHRD variant, eligible compartments can be `E`, `IA`, `IP`,
and `IS`. For Gillespie SEATIRD, eligible compartments can be `E`, `A`, and
`I`.

## Complete Configuration

The only supported antiviral model identity is `stockpile-age-risk`. A complete
five-age-group configuration looks like:

```json
"antiviral_model": {
  "identity": "stockpile-age-risk",
  "parameters": {
    "age_risk_priority_groups": ["0.0", "0.5", "1.0", "1.0", "0.5"],
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

JSON numbers or numeric strings are accepted for the numeric values shown
above.

### `age_risk_priority_groups`

This list uses the same targeting semantics as vaccination. It must contain one
value for each configured age group, in the same order as the model's age
groups.

| Value | Eligible people in that age group |
| --- | --- |
| `0.0` | No one. |
| `0.5` | High-risk people only. |
| `1.0` | Everyone, including both low- and high-risk people. |

No other values are allowed. For example:

```json
"age_risk_priority_groups": ["0.0", "0.5", "1.0", "1.0", "0.5"]
```

means:

- Nobody in age group 0 is eligible
- Only high-risk people in age groups 1 and 4 are eligible
- Everyone in age groups 2 and 3 is eligible

This parameter controls age/risk eligibility, not ordering between age groups.
Available doses are allocated proportionally among eligible groups. Both
vaccinated and unvaccinated people may receive antivirals if they satisfy the
age/risk and compartment criteria.

If omitted, every age group defaults to `1.0`.

### `compartment_priority`

This list defines the disease states eligible for antiviral treatment and the
order in which they are treated within an age/risk/vaccination group. It does
not prioritize one age group over another.

```json
"compartment_priority": ["I", "E"]
```

With this configuration, available doses first move people from `I` to `T`,
then move people from `E` to `T`. Every label must exist in the active model's
compartment list. If omitted, the default is `["I", "E"]`.

### `antiviral_capacity_proportion`

This value limits how many people can be treated in one node on one day. The
daily limit is:

```{math}
\left\lfloor
\text{antiviral_capacity_proportion}
\times
\text{node population}
\right\rfloor.
```

For example, `"0.10"` allows at most 10% of a node's total population to begin
treatment that day. Unused doses roll forward to the next day. The default is
`1.0`, allowing treatment up to the node's full population per day.

### `antiviral_half_life_days`

This optional positive value models stockpile loss over time. For a half-life
$h$, stock remaining after day 0 is multiplied each day by:

```{math}
0.5^{1/h}.
```

For example, `"30"` gives a 30-day stockpile half-life. Use `null`, or omit the
parameter, to disable stockpile decay. This affects unused doses, not people
already in `T`.

### `antiviral_stockpile`

This list schedules doses entering the network stockpile:

```json
"antiviral_stockpile": [
  {"day": "0", "amount": "1000"},
  {"day": "14", "amount": "500"}
]
```

Each `day` is an integer simulation day and each `amount` is a dose count.
Multiple entries on the same day are combined. A negative release day is
reassigned to day 0 with a warning. If no eligible people are available,
unused doses roll forward to the next day. If omitted, the stockpile is empty.

On each release day, doses are distributed among nodes in proportion to each
node's currently eligible population. Within a node, doses are allocated
proportionally among eligible age/risk/vaccination groups and then applied
according to `compartment_priority`.

## Disease Parameters

Disease parameters then describe treated people:

| Parameter | Meaning |
| --- | --- |
| `T_to_R_days` | Average duration from treated infectious to recovered. |
| `rel_inf_T_to_I` | Relative infectiousness of treated people compared with untreated `I`. |
| `rel_inf_T_to_IS` | Relative infectiousness of treated people compared with symptomatic `IS` in SEITHRD. |

In SEITRS and SEITHRD, if the compartment list includes `T` but no antiviral
model is configured, the simulator warns. Those models can still run, but no
people enter `T`.

There are no disease-model rates such as `E_to_T_days` or `I_to_T_days`.
Movement into `T` is fully determined by released doses, daily capacity,
the population in `compartment_priority`. In SEITRS and SEITHRD,
movement out of `T` is controlled by `T_to_R_days`.

## Gillespie SEATIRD

SEATIRD already contains `T`, and `T` means **Treated**, consistently with the
other antiviral-capable models. Anyone in `T` is assumed to be receiving an
antiviral.

Unlike SEITRS and SEITHRD, SEATIRD has a built-in queued `A -> T` event.
Therefore, SEATIRD can assign people to antiviral treatment even when no
stockpile model is configured. Every infection receives its queued individual
trajectory when it enters `E`, including whether it will enter `T`.

When the optional stockpile model allocates an antiviral dose to someone in
`E`, `A`, or `I`, the simulator:

1. moves one person into `T`;
2. marks the person's old source-compartment event trajectory as stale;
3. queues a new trajectory beginning in `T`.

Both built-in and stockpile-created `T` entries follow the existing SEATIRD
competing events:
`T -> I`, `T -> R`, or `T -> D`. It uses `chi`, `gamma`, and `nu`; SEATIRD does
not use `T_to_R_days`.

SEATIRD contact events are stored at the demographic-group level, not linked to
person identifiers. Antiviral reconciliation replaces progression events but
keeps the existing contact queue. This is consistent with the current SEATIRD
assumption that `A`, `T`, and `I` use the same infectious contact process.
