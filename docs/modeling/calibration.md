# Calibration And Beta

The stochastic SEIRS and SEIHRD-family models derive a baseline transmission
coefficient $\beta$ from the requested $R_0$ and the next-generation matrix.

## Contact Matrix

The age-stratified contact matrix $C$ replaces the single contact-rate scalar
used in a homogeneous-mixing model. An element $C_{ij}$ is the average number of 
daily contacts that a person in group $i$ (contact initiator) has with people in group $j$ (contactee).

The matrix can be asymmetric. Children may have frequent contact with adult
teachers and caregivers even though many adults have little contact with
children. The repository's state matrices use the combined home, work, school,
and community setting from the Epydemix implementation of Mistry 2021.

Changing the contact matrix changes the transmission coefficient required to
produce the same requested $R_0$.

## Next-Generation Matrix

Let:

```{math}
K = \beta S C \operatorname{diag}(w)
```

where:

- $S$ is a diagonal relative susceptibility matrix;
- $C$ is the contact matrix;
- $w$ is an age-specific infectiousness-duration weight.

The simulator solves:

```{math}
\rho(K) = R_0
```

so:

```{math}
\beta = \frac{R_0}{\rho(S C \operatorname{diag}(w))}.
```

For basic SEIRS:

```{math}
w_i = \frac{1}{\gamma}.
```

If susceptibility and infectious duration are equal across ages and the
spectral radius of $C$ is 1, this reduces to the familiar homogeneous result:

```{math}
\beta = R_0\gamma.
```

For SEIHRD, $w$ combines the probability of entering the asymptomatic or
symptomatic path, time spent in `IA`, `IP`, and `IS`, and each compartment's
relative infectiousness:

```{math}
w_j =
(1-p_{A,j})
\left(
\rho_{IP}d_{IP} + d_{IS}
\right)
+
p_{A,j}\rho_{IA}d_{IA}.
```

Here $p_{A,j}$ is `prop_E_to_IA` for age group $j$, the $d$ terms are mean
infectious durations, and the $\rho$ terms are relative infectiousness.

The simulator logs both the estimated beta and the $R_0$ re-derived from the
resulting next-generation matrix.

For intervention scenarios such as antiviral treatment, baseline $\beta$
should be calibrated to untreated natural history. The intervention then
changes realized transmission during simulation by moving people into treated
compartments with lower infectiousness.

SEATIRD is currently a special case: it uses the configured
`beta = R0 / beta_scale` relationship rather than the general
next-generation-matrix estimator.

Deterministic SEIRS currently uses the simplified
`beta = R0 * gamma / spectral_radius(C)` form. This is equivalent to the
general expression when relative susceptibility and infectious duration are
uniform across age groups.
