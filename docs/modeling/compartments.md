# Compartment Models

The active compartments are chosen by the `disease_model.parameters.compartments`
list in the input JSON file. The list order becomes the internal compartment
index order.

Common stochastic models include:

| Model | Compartments | Notes |
| --- | --- | --- |
| SEIRS | `S, E, I, R` | Waning immunity through `R -> S`. |
| SEITRS | `S, E, I, T, R` | Adds treated infectious `T`; `T` is created by antiviral stockpile release. |
| SEATIRD | `S, E, A, T, I, R, D` | Gillespie model where `T` means Treated and is part of the queued infection trajectory. |
| SEIHRD | `S, E, IA, IP, IS, H, R, D` | Separates asymptomatic, presymptomatic, symptomatic, hospital, death. |
| SEITHRD | `S, E, IA, IP, IS, H, T, R, D` | SEIHRD plus treated `T`; `T` is created by antiviral stockpile release. |

## SEITRS Interpretation

In every antiviral-capable model, `T` means Treated. Anyone counted in `T` is
assumed to be receiving an antiviral.

In SEITRS, treated people remain infectious, but less so:

```text
infectious pressure = I + rel_inf_T_to_I * T
```

People do not enter `T` automatically. The antiviral model moves eligible
people from `E` or `I` into `T` subject to available doses and prioritization.
This is deliberate: treatment is an intervention constrained by stockpile
availability, not a spontaneous clinical transition.

The same rule applies to SEITHRD: eligible people can move from `E`, `IA`,
`IP`, or `IS` into `T` when antiviral doses are allocated. The disease model
then moves `T -> R` according to `T_to_R_days`.

In SEATIRD, people can enter treatment through the model's built-in queued
`A -> T` event. This event assigns antiviral treatment even without an
antiviral stockpile configuration. The optional stockpile model can also move
eligible `E`, `A`, or `I` people into `T`; their old queued path is invalidated
and a new `T -> I/R/D` path is drawn.
