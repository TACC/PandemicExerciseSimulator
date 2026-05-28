# Antiviral Stockpile Model

Antivirals are modeled as a stockpile-constrained intervention. They can move
people from eligible compartments, usually `E` and `I`, into `T`.

Important parameters:

| Parameter | Meaning |
| --- | --- |
| `antiviral_stockpile` | List of release days and dose counts. |
| `age_risk_priority_groups` | Age/risk targeting. `0`, `0.5`, and `1` match vaccine targeting semantics. |
| `eligible_compartments` | Compartments that may receive treatment, usually `["E", "I"]`. |
| `compartment_priority` | Order used when a group has both `E` and `I` candidates. |
| `antiviral_capacity_proportion` | Maximum fraction of node population that can be treated per day. |
| `antiviral_half_life_days` | Optional stockpile decay after day 0. |

Disease parameters then describe treated people:

| Parameter | Meaning |
| --- | --- |
| `T_to_R_days` | Average duration from treated infectious to recovered. |
| `rel_inf_T_to_I` | Relative infectiousness of treated people compared with untreated `I`. |

If the compartment list includes `T` but no antiviral model is configured, the
simulator warns. The model can still run, but no people enter `T`.
