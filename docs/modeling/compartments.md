# Compartment Models

The active compartments are chosen by the `disease_model.parameters.compartments`
list in the input JSON file. The list order becomes the internal compartment
index order.

Common stochastic models include:

| Model | Compartments | Notes |
| --- | --- | --- |
| SEIRS | `S, E, I, R` | Waning immunity through `R -> S`. |
| SEITRS | `S, E, I, T, R` | Adds treated infectious `T`; `T` is created by antiviral stockpile release. |
| SEIHRD | `S, E, IA, IP, IS, H, R, D` | Separates asymptomatic, presymptomatic, symptomatic, hospital, death. |

## SEITRS Interpretation

In SEITRS, `T` means treated infectious. It is still infectious, but less so:

```text
infectious pressure = I + rel_inf_T_to_I * T
```

People do not enter `T` automatically. The antiviral model moves eligible
people from `E` or `I` into `T` subject to available doses and prioritization.
This is deliberate: treatment is an intervention constrained by stockpile
availability, not a spontaneous clinical transition.
