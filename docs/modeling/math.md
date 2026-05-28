# Mathematical Reference

This page summarizes the core equations. The stochastic implementation uses
integer-valued daily transitions, typically drawn from Poisson processes and
capped by compartment counts.

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

For SEITRS:

```{math}
I_j^\ast = I_j + \rho_T T_j
```

where \(\rho_T =\) `rel_inf_T_to_I`.

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

## SEITRS Daily Transitions

SEITRS disease progression is:

```{math}
S \rightarrow E,\quad
E \rightarrow I,\quad
I \rightarrow R,\quad
T \rightarrow R,\quad
R \rightarrow S.
```

The antiviral stockpile model creates treatment transitions:

```{math}
E \xrightarrow{\text{dose available}} T,\quad
I \xrightarrow{\text{dose available}} T.
```

This keeps treatment resource-constrained. If no antiviral stockpile is
released, the treatment transition count is zero.

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
