# Mathematical Reference

This page summarizes the core equations. The stochastic implementation uses
integer-valued daily transitions, typically drawn from Poisson processes and
capped by compartment counts. The deterministic implementation uses the same
daily transition structure but evaluates the transition amounts directly from
rates instead of drawing Poisson counts.

## Force Of Infection

For susceptible age group \(i\), the force of infection is:

```{math}
\lambda_i(t) =
\beta_i(t)
\sum_j C_{ij}
\frac{I_j^\ast(t)}{N}
```

where:

- \(C_{ij}\) is the contact matrix from susceptible age group \(i\) to
  infectious age group \(j\);
- \(N\) is node population;
- \(I_j^\ast\) is the weighted infectious population in age group \(j\);
- \(\beta_i(t)\) is the baseline beta after NPI modification.

For SEITRS and deterministic SEITRS:

```{math}
I_j^\ast = I_j + \rho_T T_j
```

where \(\rho_T =\) `rel_inf_T_to_I`.

For SEITHRD:

```{math}
I_j^\ast =
\rho_{IP} IP_j +
\rho_{IA} IA_j +
IS_j +
\rho_T T_j
```

where \(\rho_{IP} =\) `rel_inf_IP_to_IS`,
\(\rho_{IA} =\) `rel_inf_IA_to_IS`, and
\(\rho_T =\) `rel_inf_T_to_IS`.

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
\(\Delta_{E \to I} = \min(\sigma E, E)\).

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

where each \(\Delta^{AV}\) is an allocation count from available doses, not a
disease-rate draw. If no antiviral stockpile is released, these movement counts
are zero forever and `T` remains zero unless initialized externally.

After antiviral allocation, the SEITRS disease step includes:

```{math}
\Delta_{T \to R} =
\min(\operatorname{Pois}(\tau_T T), T),
\quad
\tau_T = \frac{1}{\text{T_to_R_days}}
```

for stochastic SEITRS. Deterministic SEITRS uses
\(\Delta_{T \to R} = \min(\tau_T T, T)\).

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
\tau_T = \frac{1}{\text{T_to_R_days}}.
```

No stockpile release means no new `T` entries.

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
rate. Every event is a one-person move, so:

```{math}
\sum_c N_c(t^+) = \sum_c N_c(t^-)
```

for every processed event, and an event is discarded if its source person was
already moved by treatment.

Progression events are reconciled after treatment. Contact events remain in the
existing group-level contact queue because SEATIRD currently applies the same
contact-generation process across `A`, `T`, and `I`.

## Competing Clocks

When a compartment has competing exits and the desired realized fraction is
\(p_i\), the simulator adjusts branch multipliers \(\pi_i\) so:

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
