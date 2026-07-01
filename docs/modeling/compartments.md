# Mechanistic Compartmental Models

The active compartments are chosen by the `disease_model.parameters.compartments`
list in the input JSON file. The list order becomes the internal compartment
index order.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Compartmental model | A model that represents the population as counts in disease states and moves people between those states. |
| $R_0$ | Average secondary infections caused by one infectious person in a fully susceptible population under the configured contact structure. |
| Rate | Per-day transition intensity, usually the reciprocal of a mean waiting time in days. |
| Infectiousness | Ability of an infected person or compartment to transmit infection. |
| Susceptibility | Relative probability that a susceptible person becomes infected after infectious contact. |
| `S` | Susceptible. |
| `E` | Exposed but not yet infectious. Initial infections are placed here. |
| `I` | Infectious. |
| `IA` | Infectious asymptomatic. |
| `IP` | Infectious pre-symptomatic. |
| `IS` | Infectious symptomatic. |
| `A` | Asymptomatic infectious in SEATIRD. |
| `H` | Hospitalized. |
| `T` | Treated with an antiviral. |
| `R` | Recovered or otherwise removed from active infection. |
| `D` | Deceased. |

## Available Structures

The model `identity` chooses between stochastic or deterministic versions of a model, 
while `compartments` chooses whether optional states such as `T` are active. 

Parameter values in the templates are runnable examples, not universal
estimates for every pathogen, season, or population. Scenario authors should
record the epidemiological source and calibration rationale for substituted
values.

| Model | Compartments | Notes |
| --- | --- | --- |
| SEIR | `S, E, I, R` | Use a SEIRS implementation without `immune_period_days`, or set it to 0. |
| SEIRS | `S, E, I, R` | Adds waning immunity through `R -> S`. |
| SEITRS | `S, E, I, T, R` | Adds treated infectious `T`; People moved into `T` by antiviral stockpile release. |
| SEATIRD | `S, E, A, T, I, R, D` | Gillespie model where `T` is treated and part of the queued infection trajectory. |
| SEIHRD | `S, E, IA, IP, IS, H, R, D` | Separates infectious into asymptomatic, pre-symptomatic, symptomatic; hospitalization, recovered and death not infectious. |
| SEITHRD | `S, E, IA, IP, IS, H, T, R, D` | SEIHRD plus treated `T`. |

All epidemics are initialized by moving the requested susceptible people into
`E`. A very short latent period can approximate immediate infectiousness, but
the initial state remains exposed. `E` is therefore a required compartment for all models.

## SEIR And SEIRS Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `compartments` | Yes | `["S", "E", "I", "R"]`, or include `T` for SEITRS. |
| `R0` | Yes | Target basic reproduction number used to derive baseline beta. |
| `latent_period_days` | Yes | Mean duration from `E` to `I`. The internal rate is $\sigma=1/\text{latent period}$. |
| `infectious_period_days` | Yes | Mean duration from `I` to `R`. The internal rate is $\gamma=1/\text{infectious period}$. |
| `immune_period_days` | No | Mean duration from `R` to `S`. Omit or use 0 for permanent immunity during the simulation. |
| `relative_susceptibility` | No | One multiplier per age group; defaults to all 1.0. |
| `T_to_R_days` | SEITRS only | Mean treated duration before recovery. |
| `rel_inf_T_to_I` | SEITRS only | Infectiousness of `T` relative to untreated `I`; scalar or one value per age group. |

## SEIHRD And SEITHRD Parameters

SEIHRD represents infections that can transmit before symptoms and can result
in hospitalization and death:

```{math}
E \rightarrow IA \text{ or } IP,\quad
IP \rightarrow IS,\quad
IS \rightarrow H \text{ or } R,\quad
H \rightarrow D \text{ or } R,\quad
IA \rightarrow R.
```

| Parameter | Description |
| --- | --- |
| `compartments` | `["S", "E", "IA", "IP", "IS", "H", "R", "D"]`; insert `T` for SEITHRD. |
| `R0` | Target basic reproduction number. |
| `E_to_IPandIA_days` | Mean exposed duration before the asymptomatic/pre-symptomatic split. |
| `IP_to_IS_days` | Mean pre-symptomatic infectious duration. |
| `IS_to_H_days` | Mean time from symptomatic infection to hospitalization. |
| `IS_to_R_days` | Mean time from symptomatic infection to recovery without hospitalization. |
| `IA_to_R_days` | Mean asymptomatic infectious duration before recovery. |
| `H_to_D_days` | Mean time from hospitalization to death. |
| `H_to_R_days` | Age-specific mean time from hospitalization to recovery. |
| `prop_E_to_IA` | Age-specific eventual proportion of exposed people who follow the asymptomatic path. |
| `prop_IS_to_H_lowrisk` | Age-specific eventual hospitalization proportion among low-risk symptomatic people. |
| `highrisk_hosp_multiplier` | Multiplier applied to low-risk hospitalization proportions for the high-risk group. |
| `prop_H_to_D` | Age-specific eventual proportion of hospitalized people who die. |
| `rel_inf_IP_to_IS` | Infectiousness of `IP` relative to `IS`. |
| `rel_inf_IA_to_IS` | Infectiousness of `IA` relative to `IS`. |
| `relative_susceptibility` | Optional age-specific susceptibility multipliers; defaults to all 1.0. |
| `T_to_R_days` | SEITHRD mean treated duration before recovery for treated people who are not hospitalized. |
| `rel_inf_T_to_IS` | SEITHRD infectiousness of `T` relative to `IS`; scalar or one value per age group. |

The configured split proportions are intended as eventual outcomes. When two
destinations have different exit rates, the simulator adjusts the branch
multipliers so the realized proportion still matches the requested value. See
[Mathematical Reference](math.md), under **Competing Clocks**.

## SEATIRD Parameters

SEATIRD uses `S, E, A, T, I, R, D`. Its stochastic Gillespie implementation creates an
individual event queue, while its deterministic implementation uses daily
Euler updates with the same parameter meanings.

| Parameter | Description |
| --- | --- |
| `R0` | Transmission target used with `beta_scale`. |
| `beta_scale` | Calibration divisor; baseline beta is `R0 / beta_scale`. |
| `tau` | Mean duration from `E` to `A`. |
| `kappa` | Mean duration from `A` to symptomatic infectious `I` in stochastic SEATIRD; deterministic SEATIRD still uses it for `A -> T`. |
| `chi` | Mean duration from `T` to symptomatic infectious `I`. |
| `gamma` | Recovery-period parameter for infectious `A`, `T`, and `I`. |
| `nu` | Age-specific low-risk mortality-rate parameter. High-risk values are currently nine times the configured values. |
| `sigma` | Age-specific relative susceptibility. |

SEATIRD currently treats `A`, `T`, and `I` as equally infectious in its contact
process. In the Gillespie stochastic model, `T` is entered only through
released antiviral stockpile allocation.

SEATIRD is a legacy model from when the original code base was in C++. We do not recommend using this model as
it's parameterization does not emulate the real-world well. However, it is a good example of a Gillespie model
and may be of use to students, developers, or those interested in comparing model runtimes/limitations.

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

The same rule applies to SEITHRD. For routine treatment, eligible people
should usually move from `IS` into `T` when antiviral doses are allocated.
Set `IS_to_R_days` to the untreated symptomatic recovery duration and
`T_to_R_days` to the treated duration; for example, `7` and `5` represent a
2-day antiviral reduction. Including `E`, `IA`, or `IP` in
`compartment_priority` changes the scenario toward prophylaxis or early
treatment, so treated infectious time is no longer directly comparable to
strict `IS` treatment. The disease model then moves `T -> H` or `T -> R`.
`antiviral_effectiveness_hosp` reduces the treated hospitalization risk; for
example, `0.25` represents a 25% risk reduction, or 75% relative risk, and
does not eliminate hospitalization.

In Gillespie SEATIRD, people enter treatment only through stockpile allocation.
The stockpile model can move eligible `E`, `A`, or `I` people into `T`; their
old queued path is invalidated and a new `T -> I/R/D` path is drawn.
