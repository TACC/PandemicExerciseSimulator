# Antiviral Stockpile Model

Antivirals are modeled as a stockpile-constrained intervention. They move
people from eligible compartments into `T` by allocation, not by a disease-rate
equation. This is intentionally similar to vaccination: a stockpile is released,
distributed to nodes, and then applied within each node according to eligibility
and priority. Releases and allocation are deterministic fixed-count transfers;
the stockpile model does not draw a random number of doses or randomly sample
who receives a dose.

For SEITRS, eligible compartments are usually `E` and `I`. For SEITHRD, the
antiviral-capable SEIHRD variant, eligible compartments can be `E`, `IA`, `IP`,
and `IS`. For SEAITRD, eligible compartments can be `E`, `A`, and `I`; the
`T` compartment is required in this model family even when no doses are
released.

## Complete Configuration

The only supported antiviral model identity is `stockpile-age-risk`. A complete
five-age-group configuration looks like:

```json
"antiviral_model": {
  "identity": "stockpile-age-risk",
  "parameters": {
    "age_risk_priority_groups": ["0.0", "0.5", "1.0", "1.0", "0.5"],
    "compartment_priority": ["IS"],
    "antiviral_effectiveness_hosp": "0.25",
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

If supplies, daily capacity, and eligible compartment counts are sufficient,
everyone who meets the configured age/risk and compartment criteria can receive
an antiviral. People outside that eligibility are excluded from the scenario,
even if unused doses remain. To test a narrower or broader target population,
run a separate scenario with a different eligibility vector.

If omitted, every age group defaults to `1.0`.

### `compartment_priority`

This list defines the disease states eligible for antiviral treatment and the
order in which they are treated within an age/risk/vaccination group. It does
not prioritize one age group over another.

```json
"compartment_priority": ["IS"]
```

With this SEITHRD configuration, available doses move people from symptomatic
infectious `IS` to `T`. Every label must exist in the active model's
compartment list. If omitted, the default is `["I"]`. For SEITHRD symptomatic
treatment scenarios, set `compartment_priority` explicitly to `["IS"]`.

Including `E`, `IA`, or `IP` in SEITHRD changes the scenario from symptomatic
treatment toward prophylaxis or early treatment. Those people may spend more
calendar time in `T` than someone treated only after entering `IS`, so the
meaning of `T_to_R_days` and treated infectious time changes. The current
stockpile model treats eligible compartment members directly; it does not yet
represent a separate proportion or household-contact multiplier, such as
treating 1 to 5 family members per infectious person. Use earlier
compartments only for explicit prophylaxis scenarios.

### `antiviral_effectiveness_hosp`

This optional SEITHRD parameter is the treated relative reduction in
hospitalization risk. It accepts a scalar or one value per age group, with
values from `0.0` to `1.0`.

For oseltamivir-like treatment (Tamiflu), `"0.25"` represents a 25% hospitalization risk reduction,
or 75% relative risk, for treated people. Treated people can still be
hospitalized: SEITHRD moves `T -> H` or `T -> R`, and this parameter reduces
only the realized `T -> H` risk. If omitted, the default is `1.0`, meaning
complete protection from hospitalization for treated people. Set an explicit
smaller value, such as `0.25`, when modeling partial protection.

The treated hospitalization branch is anchored to the original symptomatic
hospitalization clock, `IS_to_H_days`. Internally, the model uses
`target_rate = 1 / IS_to_H_days` for both untreated `IS -> H` and treated
`T -> H`; treatment changes the desired realized hospitalization proportion,
not the baseline hospitalization clock itself.

For example, suppose a low-risk age group has the following parameters and
the default complete protection has been overridden with partial protection:

```json
"IS_to_H_days": "3.0",
"IS_to_R_days": "7.0",
"T_to_R_days": "5.0",
"prop_IS_to_H_lowrisk": ["0.10"],
"antiviral_effectiveness_hosp": "0.25"
```

Untreated symptomatic people have an eventual hospitalization proportion of
`0.10`, so about 100 of 1,000 people in `IS` would eventually move to `H`.
For treated people, the model computes:

```text
treated hospitalization proportion = 0.10 * (1 - 0.25) = 0.075
```

So about 75 of 1,000 people in `T` would eventually move to `H`, while the
remaining treated exits go to `R`. The model still uses the original
`IS_to_H_days` rate for the `T -> H` target clock, then adjusts the competing
`T -> H` versus `T -> R` branch multipliers so the realized treated
hospitalization proportion is `0.075`.

With the numbers above, the `T -> H` target rate is still
`1 / IS_to_H_days = 1 / 3 = 0.333` per day before branch weighting. The
competing-clock adjustment combines that target clock with
`T -> R = 1 / T_to_R_days = 1 / 5 = 0.200` per day and chooses branch
weights that realize 7.5% hospitalized among treated people. Treatment does
not replace `IS_to_H_days`; it lowers the realized hospitalization proportion
relative to the untreated `IS` pathway and shortens the recovery clock from
`IS_to_R_days = 7.0` to `T_to_R_days = 5.0`.

### `antiviral_effectiveness_death`

This SEAITRD antiviral parameter is the treated relative reduction in mortality
risk. It accepts a scalar or one value per age group, with values from `0.0`
to `1.0`. Provide it when an antiviral model is configured for SEAITRD.

For example, `"0.25"` represents a 25% mortality risk reduction, or 75%
relative risk, for treated people. In SEAITRD, this parameter reduces
the mortality intensity used for treated `T -> D` events:

```text
treated mortality rate = I_to_D_invdays * (1 - antiviral_effectiveness_death)
```

Set `0.0` to preserve the untreated SEAITRD mortality rate for treated people.
Set `1.0` only when treated people should have no `T -> D` event.

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
The configured `amount` is the number of doses entering the stockpile on that
day; it is not noised or sampled.

On each release day, doses are distributed among nodes in proportion to each
node's currently eligible population. Within a node, doses are allocated
proportionally among eligible age/risk/vaccination groups and then applied
according to `compartment_priority`. Fractional proportional shares are turned
into integer transfer counts with deterministic rounding and availability
limits. The only reason fewer people move into `T` than the release amount is
that doses are limited by eligibility, capacity, stockpile decay, or available
people in the prioritized compartments.

## Disease Parameters

Disease parameters then describe treated people:

| Parameter | Meaning |
| --- | --- |
| `T_to_R_days` | Average duration from treated infectious to recovered. |
| `rel_inf_T_to_I` | Relative infectiousness of treated people compared with untreated `I`. |
| `rel_inf_T_to_IS` | Relative infectiousness of treated people compared with symptomatic `IS` in SEITHRD. |
| `antiviral_effectiveness_hosp` | Antiviral-model parameter that reduces `T -> H` risk in SEITHRD; scalar or one value per age group. Defaults to `1.0`, complete protection from hospitalization. |
| `antiviral_effectiveness_death` | Antiviral-model parameter that reduces `T -> D` risk in SEAITRD; scalar or one value per age group. Required when SEAITRD uses an antiviral model. |

In SEITRS and SEITHRD, if the compartment list includes `T` but no antiviral
model is configured, the simulator warns. Those models can still run, but no
people enter `T`.

There are no disease-model rates such as `E_to_T_days` or `I_to_T_days`.
Movement into `T` is fully determined by released doses, daily capacity,
the population in `compartment_priority`. In SEITRS and SEITHRD,
movement out of `T` is controlled by `T_to_R_days`; SEITHRD also allows
treated people to enter `H`, with risk reduced by
`antiviral_effectiveness_hosp`. SEAITRD also uses `T_to_R_days`, separately
from `I_to_R_days`, and derives treated mortality from `I_to_D_invdays` and
`antiviral_effectiveness_death`.

## SEAITRD

SEAITRD requires `T`, and `T` means **Treated**, consistently with the other
antiviral-capable models. Anyone in `T` is assumed to be receiving an
antiviral, but no one enters `T` without stockpile allocation unless the input
explicitly initializes that compartment.

In the Gillespie stochastic SEAITRD model, untreated infection trajectories do
not enter `T`. Natural progression uses `E -> A -> I`; `A` behaves like a
pre-symptomatic compartment and does not recover or die directly.

When the optional stockpile model allocates an antiviral dose to someone in a
configured eligible compartment such as `I`, `A`, or `E`, the simulator:

1. moves one person into `T`;
2. marks the person's old source-compartment event trajectory as stale;
3. queues a new trajectory beginning in `T`.

Stockpile-created `T` entries follow the existing SEAITRD competing events:
`T -> R` or `T -> D`. Treated recovery uses `T_to_R_days`, while untreated
recovery uses `I_to_R_days`. Treated mortality is derived from
`I_to_D_invdays * (1 - antiviral_effectiveness_death)`.

SEAITRD contact events are stored at the demographic-group level, not linked to
person identifiers. Antiviral reconciliation replaces progression events but
keeps the existing contact queue. This is consistent with the current SEAITRD
assumption that `A`, `T`, and `I` use the same infectious contact process.
