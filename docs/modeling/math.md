# Mathematical Reference

This page summarizes the core equations. The stochastic implementation uses
integer-valued daily transitions, typically drawn from Poisson processes and
capped by compartment counts. The deterministic implementation uses the same
daily transition structure but evaluates the transition amounts directly from
rates (fractions of people) instead of drawing Poisson counts. The deterministic
model is Euler's method, so it will not converge without non-integer people
being allowed to progress forward in time.

Intervention allocation and effectiveness equations are documented separately
in [NPI And Vaccine Mathematics](npis-vaccines.md) and
[Antiviral Stockpile Model](antivirals.md).

## Force Of Infection

For susceptible age group $i$, the force of infection is:

```{math}
\lambda_i(t) =
\beta_i(t)
\sum_j C_{ij}
\frac{I_j^\ast(t)}{N}
```

where:

- $C_{ij}$ is the average number of daily contacts that a person in group $i$ (contact initiator) has with people in group $j$ (contactee)
- $N$ is node population (e.g. county)
- $I_j^\ast$ is the weighted infectious population in age group $j$
- $\beta_i(t)$ is the baseline beta after NPI modification

For SEITRS and deterministic SEITRS:

```{math}
I_j^\ast = I_j + \rho_T T_j
```

where $\rho_T =$ `rel_inf_T_to_I`.

For SEITHRD:

```{math}
I_j^\ast =
\rho_{IP} IP_j +
\rho_{IA} IA_j +
IS_j +
\rho_T T_j
```

where $\rho_{IP} =$ `rel_inf_IP_to_IS`,
$\rho_{IA} =$ `rel_inf_IA_to_IS`, and
$\rho_T =$ `rel_inf_T_to_IS`.

## Model Equation Systems

The systems below show the mean compartment flows without age, risk, vaccine,
or node subscripts. Each equation applies separately to those groups, while
$\lambda$ includes the infectious pressure summed across the interacting
groups. We'll let the uncapped mean-field incidence be:

```{math}
F = \lambda S.
```

The simulator advances these systems in one-day steps rather than using a
continuous ODE solver. Deterministic models use capped mean flows; stochastic
daily models replace eligible flows with capped Poisson draws.

### SEIR And SEIRS

Let $\sigma$ be the `E -> I` rate, $\gamma$ the `I -> R` rate, and
$\omega$ the `R -> S` rate. For SEIR, set $\omega=0$.

:::{container} ode-system
```{math}
\begin{aligned}
\dot S &= -F + \omega R, \\
\dot E &= F - \sigma E, \\
\dot I &= \sigma E - \gamma I, \\
\dot R &= \gamma I - \omega R.
\end{aligned}
```
:::

### SEITRS

Let $d_T$ denote the configured duration `T_to_R_days`, so
$\tau_T = 1/d_T$. At the start of a simulation day, the antiviral stockpile
model may move eligible people into `T`. Let $E_{\mathrm{before}}$,
$I_{\mathrm{before}}$, and $T_{\mathrm{before}}$ be the compartment counts
immediately before allocation. If $u_E$ exposed people and $u_I$ infectious
people receive treatment, the counts immediately after allocation are:

```{math}
\begin{aligned}
E_{\mathrm{after}} &= E_{\mathrm{before}} - u_E, \\
I_{\mathrm{after}} &= I_{\mathrm{before}} - u_I, \\
T_{\mathrm{after}} &= T_{\mathrm{before}} + u_E + u_I.
\end{aligned}
```

where $u_E$ and $u_I$ are allocated dose counts, not continuous disease rates.
“After” means after antiviral allocation on the same simulation day, not the
next day. The disease-progression step then uses these updated counts:

:::{container} ode-system
```{math}
\begin{aligned}
\dot S &= -F + \omega R, \\
\dot E &= F - \sigma E, \\
\dot I &= \sigma E - \gamma I, \\
\dot T &= -\tau_T T, \\
\dot R &= \gamma I + \tau_T T - \omega R.
\end{aligned}
```
:::

Here $F$ uses $I^\ast=I+\rho_TT$. With no allocated doses and no initialized
treated population, $u_E=u_I=0$ and $T$ remains zero.

### SEIHRD

Let $\alpha$ be the `E -> IA/IP` rate, $p_A$ the asymptomatic branch
proportion, $\kappa$ the `IP -> IS` rate, $\gamma_A$ the `IA -> R` rate,
$h$ the effective `IS -> H` rate, $\gamma_S$ the `IS -> R` rate, $\mu_H$
the `H -> D` rate, and $\gamma_H$ the `H -> R` rate. The effective
hospitalization rate $h$ includes the configured age, risk, and vaccine
modifiers.

:::{container} ode-system
```{math}
\begin{aligned}
\dot S  &= -F, \\
\dot E  &= F - \alpha E, \\
\dot{IA} &= p_A\alpha E - \gamma_A IA, \\
\dot{IP} &= (1-p_A)\alpha E - \kappa IP, \\
\dot{IS} &= \kappa IP - (h+\gamma_S)IS, \\
\dot H  &= hIS - (\mu_H+\gamma_H)H, \\
\dot R  &= \gamma_A IA + \gamma_S IS + \gamma_H H, \\
\dot D  &= \mu_H H.
\end{aligned}
```
:::

The stochastic implementation draws and caps the daily transitions, then
resolves competing exits from the remaining source population.

### SEITHRD

SEITHRD uses the SEIHRD progression rates above and adds treated recovery.
At the start of a simulation day, antiviral allocation may transfer people
from `E`, `IA`, `IP`, and `IS` into `T`. For each compartment, “before” means
immediately before that day's allocation and “after” means immediately after
allocation, before disease progression:

```{math}
\begin{aligned}
E_{\mathrm{after}}  &= E_{\mathrm{before}} - u_E, \\
IA_{\mathrm{after}} &= IA_{\mathrm{before}} - u_{IA}, \\
IP_{\mathrm{after}} &= IP_{\mathrm{before}} - u_{IP}, \\
IS_{\mathrm{after}} &= IS_{\mathrm{before}} - u_{IS}, \\
T_{\mathrm{after}}  &= T_{\mathrm{before}}
                        + u_E + u_{IA} + u_{IP} + u_{IS}.
\end{aligned}
```

The $u$ values are whole-person daily allocations from the stockpile model.
They are not rates in the ODE system, and these equations do not describe a
change from one day to the next.

:::{container} ode-system
```{math}
\begin{aligned}
\dot S  &= -F, \\
\dot E  &= F - \alpha E, \\
\dot{IA} &= p_A\alpha E - \gamma_A IA, \\
\dot{IP} &= (1-p_A)\alpha E - \kappa IP, \\
\dot{IS} &= \kappa IP - (h+\gamma_S)IS, \\
\dot H  &= hIS - (\mu_H+\gamma_H)H, \\
\dot T  &= -\tau_T T, \\
\dot R  &= \gamma_A IA + \gamma_S IS + \gamma_H H + \tau_T T, \\
\dot D  &= \mu_H H.
\end{aligned}
```
:::

Here $F$ uses the weighted infectious population defined in the Force Of
Infection section above, including treated infectiousness.

### SEATIRD

The deterministic SEATIRD mean-flow system uses $\tau$ for `E -> A`,
$\kappa$ for `A -> T`, $\chi$ for `T -> I`, $\gamma$ for recovery, and
$\nu$ for mortality:

:::{container} ode-system
```{math}
\begin{aligned}
\dot S &= -F, \\
\dot E &= F - \tau E, \\
\dot A &= \tau E - (\kappa+\gamma+\nu)A, \\
\dot T &= \kappa A - (\chi+\gamma+\nu)T, \\
\dot I &= \chi T - (\gamma+\nu)I, \\
\dot R &= \gamma(A+T+I), \\
\dot D &= \nu(A+T+I).
\end{aligned}
```
:::

The stochastic SEATIRD model follows these pathways with a Gillespie-style
queue of individual events rather than numerically solving this ODE system.
Its built-in `A -> T` pathway is part of the disease trajectory; optional
stockpile treatment additionally replaces an eligible person's queued
trajectory with a newly drawn trajectory beginning in `T`.

## SEIRS Daily Transitions

For SEIRS:

```{math}
S \rightarrow E,\quad
E \rightarrow I,\quad
I \rightarrow R,\quad
R \rightarrow S
```

with rates:

```{math}
\sigma = \frac{1}{\text{latent period}}, \quad
\gamma = \frac{1}{\text{infectious period}}, \quad
\omega = \frac{1}{\text{immune period}}.
```

The stochastic transition counts are:

```{math}
\Delta_{S \to E} = \min(\operatorname{Pois}(\lambda S), S)
```

```{math}
\Delta_{E \to I} = \min(\operatorname{Pois}(\sigma E), E),\quad
\Delta_{I \to R} = \min(\operatorname{Pois}(\gamma I), I),\quad
\Delta_{R \to S} = \min(\operatorname{Pois}(\omega R), R).
```

The deterministic model uses the same capped transitions, replacing each
Poisson draw with its mean, for example
$\Delta_{E \to I} = \min(\sigma E, E)$.

## SEITRS Daily Transitions

SEITRS disease progression is:

```{math}
S \rightarrow E,\quad
E \rightarrow I,\quad
I \rightarrow R,\quad
T \rightarrow R,\quad
R \rightarrow S.
```

The disease model does not contain an `E -> T` or `I -> T` rate. Treatment
entry is handled by the antiviral stockpile model before disease progression
for that day. It is analogous to vaccine allocation: doses are released,
distributed to nodes, and then applied to eligible people until the dose supply
or eligible population is exhausted.

The antiviral stockpile model creates treatment movements:

```{math}
\Delta_{E \to T}^{AV},\quad
\Delta_{I \to T}^{AV}
```

where each $\Delta^{AV}$ is an allocation count from available doses, not a
disease-rate draw. If no antiviral stockpile is released, these movement counts
are zero forever and `T` remains zero unless initialized externally.

After antiviral allocation, the SEITRS disease step includes:

```{math}
\Delta_{T \to R} =
\min(\operatorname{Pois}(\tau_T T), T),
\quad
\tau_T = \frac{1}{d_T}
```

where $d_T$ is `T_to_R_days`. For stochastic SEITRS, the transition is drawn
from the Poisson distribution above. Deterministic SEITRS uses
$\Delta_{T \to R} = \min(\tau_T T, T)$.

## SEITHRD Daily Transitions

SEITHRD is the antiviral-enabled SEIHRD variant with compartment order:

```{math}
S, E, IA, IP, IS, H, T, R, D.
```

The disease progression transitions are:

```{math}
S \rightarrow E,\quad
E \rightarrow IA \text{ or } IP,\quad
IP \rightarrow IS,\quad
IS \rightarrow H \text{ or } R,\quad
H \rightarrow D \text{ or } R,\quad
IA \rightarrow R,\quad
T \rightarrow R.
```

As with SEITRS, the disease model has no rate into `T`. Antiviral allocation
creates the possible treatment movements:

```{math}
\Delta_{E \to T}^{AV},\quad
\Delta_{IA \to T}^{AV},\quad
\Delta_{IP \to T}^{AV},\quad
\Delta_{IS \to T}^{AV}.
```

These are governed by `eligible_compartments`, `compartment_priority`, node
allocation, daily capacity, and stockpile availability. Disease progression
then moves treated people out of `T`:

```{math}
\Delta_{T \to R} =
\min(\operatorname{Pois}(\tau_T T), T),
\quad
\tau_T = \frac{1}{d_T}.
```

Here $d_T$ is `T_to_R_days`. No stockpile release means no new `T` entries.

## Gillespie SEATIRD Events

SEATIRD is event-driven rather than a daily Poisson compartment update. At
infection time, each person receives an event schedule:

```{math}
E \rightarrow A,\quad
A \rightarrow T \text{ or } R \text{ or } D,\quad
T \rightarrow I \text{ or } R \text{ or } D,\quad
I \rightarrow R \text{ or } D.
```

Here `T` means Treated, and anyone in `T` is assumed to be receiving an
antiviral. The event times are drawn when the infection trajectory is created.
The built-in `A -> T` event assigns treatment as part of that trajectory, even
without an antiviral stockpile.

The optional stockpile model adds external queue edits:

```{math}
E \xrightarrow{\text{dose}} T,\quad
A \xrightarrow{\text{dose}} T,\quad
I \xrightarrow{\text{dose}} T.
```

For each stockpile-allocated dose, the old source trajectory is marked stale
and a new `T` trajectory is drawn. There is no daily antiviral transition
rate. Every event moves one person out of one compartment and into another.
Therefore, if $N_{c,\mathrm{before}}$ and $N_{c,\mathrm{after}}$ are the
counts in compartment $c$ immediately before and after one event:

```{math}
\sum_c N_{c,\mathrm{after}} = \sum_c N_{c,\mathrm{before}}.
```

This is an immediate event-level comparison, not a comparison between
simulation days. Population is preserved because each event removes and adds
the same one person. An event is discarded if its source person was already
moved by treatment.

Progression events are reconciled after treatment. Contact events remain in the
existing group-level contact queue because SEATIRD currently applies the same
contact-generation process across `A`, `T`, and `I`.

## Competing Clocks

When a compartment has competing exits and the desired realized fraction is
$p_i$, the simulator adjusts branch multipliers $\pi_i$ so:

```{math}
\frac{\pi_i r_i}{\sum_j \pi_j r_j} = p_i.
```

The implemented solution is:

```{math}
\pi_i =
\frac{p_i / r_i}{\sum_j p_j / r_j}.
```

For two branches, this reduces to the helper
`DiseaseModel.adjust_two_way_split_proportion`.
