# Mechanistic Compartmental Models

The active compartments are chosen by the `disease_model.parameters.compartments`
list in the input JSON file. The list order becomes the internal compartment
index order.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Compartmental model | A mechanistic model that represents the population as counts in disease states and moves people between those states. |
| $R_0$ | Average secondary infections caused by one infectious person in a fully susceptible population under the configured contact structure. |
| Rate | Per-day transition intensity, usually the reciprocal of a mean waiting time in days. |
| Infectiousness | Ability of an infected person or compartment to transmit infection. |
| Susceptibility | Relative probability that a susceptible person becomes infected after infectious contact. |
| `S` | Susceptible to infection. |
| `E` | Exposed but not yet infectious. Initial exposures are placed here. |
| `I` | Infectious and actively transmitting the disease. |
| `IA` | Infectious asymptomatic. |
| `IP` | Infectious pre-symptomatic. |
| `IS` | Infectious symptomatic. |
| `A` | Asymptomatic infectious in SEAITRD. |
| `H` | Hospitalized and not infectious. We consider inpatient hospitalizations sufficiently isolated to stop spreading to the general public. |
| `T` | Treated with an antiviral, still infectious but less than an untreated person. |
| `R` | Recovered or otherwise removed from active infection. |
| `D` | Deceased. |

## Available Structures

The model `identity` chooses between stochastic or deterministic versions of a model, 
while `compartments` chooses whether optional states such as `T` are active. 
Even with added `T` the `identity` remains the same to match the Python script of source code.

Parameter values in the templates are runnable influenza examples, not universal
estimates for every pathogen, season, or population. Scenario authors should
record the epidemiological source and calibration rationale for substituted
values. Tags `notes` section of template is a great place for this.

| Model | Compartments | Notes |
| --- | --- | --- |
| SEIR | `S, E, I, R` | Use a SEIRS implementation without `R_to_S_days`, or set it to 0. |
| SEIRS | `S, E, I, R` | Adds waning immunity through `R -> S`. |
| SEITRS | `S, E, I, T, R` | Adds treated infectious `T`; People moved into `T` by antiviral stockpile release. |
| SEAITRD | `S, E, A, I, T, R, D` | Gillespie and deterministic model family with required treated `T`; treatment is populated by antiviral stockpile release. |
| SEIHRD | `S, E, IA, IP, IS, H, R, D` | Separates infectious into asymptomatic, pre-symptomatic, symptomatic; hospitalization, recovered and death not infectious. |
| SEITHRD | `S, E, IA, IP, IS, H, T, R, D` | SEIHRD plus treated `T`. |

All epidemics are initialized by moving the requested susceptible people into
`E`. A very short latent period can approximate immediate infectiousness, but
the initial state remains exposed. `E` is therefore a required compartment for all models.

## SEIR And SEIRS Parameters

The SEIR-family models build up in the following order of complexity:

:::{figure} ../figures/SEIR.png
:alt: SEIR compartment diagram showing susceptible, exposed, infectious, and recovered states.
:width: 80%

SEIR compartment structure.
:::

:::{figure} ../figures/SEIRS.png
:alt: SEIRS compartment diagram adding waning immunity from recovered back to susceptible.
:width: 80%

SEIRS compartment structure with waning immunity.
:::

:::{figure} ../figures/SEITRS.png
:alt: SEITRS compartment diagram adding treated infectious people to the SEIRS structure.
:width: 80%

SEITRS compartment structure with antiviral treatment.
:::

:::{figure} ../figures/SEITRS_Exposed.png
:alt: SEITRS compartment diagram where antiviral allocation may also move exposed people into treatment.
:width: 80%

SEITRS structure with exposed people eligible for antiviral allocation.
:::

In figures with `T`, dotted arrows into `T` indicate antiviral allocation
events. They are not disease-progression rates; they depend on available
doses and the configured priority order in the antiviral stockpile model.

| Parameter | Required | Description |
| --- | --- | --- |
| `compartments` | Yes | `["S", "E", "I", "R"]`, or include `T` for SEITRS. |
| `R0` | Yes | Target basic reproduction number used to derive baseline beta. |
| `E_to_I_days` | Yes | Mean duration from `E` to `I`. The internal rate is $1/\text{E_to_I_days}$. |
| `I_to_R_days` | Yes | Mean duration from `I` to `R`. The internal rate is $1/\text{I_to_R_days}$. |
| `R_to_S_days` | No | Mean duration from `R` to `S`. Omit or use 0 for permanent immunity during the simulation. |
| `relative_susceptibility` | No | One multiplier per age group; defaults to all 1.0. |
| `T_to_R_days` | SEITRS only | Mean treated duration before recovery. |
| `rel_inf_T_to_I` | SEITRS only | Infectiousness of `T` relative to untreated `I`; scalar or one value per age group. |

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

In SEAITRD, people enter treatment only through stockpile allocation. The
stockpile model moves eligible `I` people into `T`; their old queued path is
invalidated and a new `T -> R/D` path is drawn.

## SEIHRD And SEITHRD Parameters

SEIHRD represents infections that can transmit before symptoms and can result
in hospitalization and death:

:::{figure} ../figures/SEIHRD.png
:alt: SEIHRD compartment diagram with asymptomatic, pre-symptomatic, symptomatic, hospitalized, recovered, and deceased states.
:width: 90%

SEIHRD compartment structure.
:::

:::{figure} ../figures/SEITHRD.png
:alt: SEITHRD compartment diagram adding treated people to the SEIHRD structure.
:width: 90%

SEITHRD compartment structure with antiviral treatment.
:::

:::{figure} ../figures/SEITHRD_Exposed.png
:alt: SEITHRD compartment diagram where antiviral allocation may also move exposed people into treatment.
:width: 90%

SEITHRD structure with exposed people eligible for antiviral allocation.
:::

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

## SEAITRD Parameters

SEAITRD always uses `S, E, A, I, T, R, D`. Unlike the SEIRS, SEITRS,
SEIHRD, and SEITHRD families, `T` is not optional in SEAITRD inputs. Its
stochastic Gillespie implementation creates an individual event queue, while
its deterministic implementation uses daily Euler updates with the same
parameter meanings.

SEAITRD is a legacy model from when the original code base was in C++. We do not recommend using this model as
it's parameterization does not emulate the real-world well. However, it is a good example of a Gillespie model
and may be of use to students, developers, or those interested in comparing model runtimes/limitations.

:::{figure} ../figures/SEAITRD.png
:alt: SEAITRD compartment diagram with susceptible, exposed, asymptomatic, infectious, treated, recovered, and deceased states.
:width: 90%

SEAITRD compartment structure.
:::

| Parameter | Description |
| --- | --- |
| `R0` | Transmission target used with `beta_scale`. |
| `beta_scale` | Calibration divisor; baseline beta is `R0 / beta_scale`. |
| `E_to_A_days` | Mean duration from `E` to asymptomatic infectious `A`. |
| `A_to_I_days` | Mean duration from `A` to symptomatic infectious `I`. |
| `I_to_R_days` | Mean untreated infectious duration before recovery. |
| `T_to_R_days` | Mean treated infectious duration before recovery. Configure separately from `I_to_R_days`; a 2-day shorter treated course is represented directly here. |
| `I_to_D_invdays` | Age-specific low-risk mortality rate per day for untreated `I`. |
| `highrisk_death_multiplier` | Multiplier applied to `I_to_D_invdays` to derive high-risk mortality rates. Use `9` for the current template behavior. |
| `relative_susceptibility` | Age-specific susceptibility multipliers. |
| `rel_inf_T_to_I` | Optional relative infectiousness of treated people compared with untreated `I`; defaults to 1.0. |

SEAITRD currently treats `A`, `I`, and `T` as equally infectious in its contact
process. In both deterministic and Gillespie stochastic SEAITRD, `T` is entered
only through released antiviral stockpile allocation. When an antiviral model
is configured for SEAITRD, provide `antiviral_effectiveness_death`; the treated
mortality rate is derived from `I_to_D_invdays * (1 - antiviral_effectiveness_death)`.
