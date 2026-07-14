# NPI And Vaccine Mathematics

This page describes how non-pharmaceutical interventions and the
`stockpile-age-risk` vaccine model are applied during simulation. The public
health [Interventions](../public-health/interventions.md) page provides the
input parameter reference and JSON examples.

## Daily Order

On simulation day $d$, intervention-related operations occur in this order:

1. Release vaccine doses scheduled for day $d$ and divide them among nodes
2. Vaccinate eligible susceptible people within each node
3. Progress disease within each node using NPI-adjusted beta and vaccine
   effectiveness
4. Draw travel-associated exposures, including vaccine effectiveness against
   infection

Day-0 vaccine allocation occurs before initial output is written. Initial
exposures were already placed into the exposed compartment and are therefore
not eligible for vaccination. For example, if you have a node with 1000 residents,
900 susceptible and 100 exposed, you can allocate 1000 vaccines on day-0 but only
900 could be distributed.

## NPI Schedule

For NPI $k$, let:

- $d_k$ be its start day
- $L_k$ be its duration
- $e_{k,a}$ be its effectiveness for age group $a$
- $\mathcal{N}_k$ be its selected nodes

The intervention is active on:

```{math}
d \in \{d_k, d_k+1, \ldots, d_k+L_k-1\}.
```

A location of `"0"` assigns $\mathcal{N}_k$ to every node. Otherwise, the
location string is converted from county/node identifiers to network indices.

### Overlapping NPIs

The schedule begins with combined effectiveness $E_{d,n,a}=0$. Adding an
active NPI with effectiveness $e$ updates it as:

```{math}
E'_{d,n,a}
=
E_{d,n,a} + (1-E_{d,n,a})e.
```

For all active interventions in a node, day, and age group, the equivalent
closed form is:

```{math}
E_{d,n,a}
=
1-\prod_k(1-e_{k,a}).
```

Thus, two interventions with effectiveness 0.5 produce:

```{math}
1-(1-0.5)^2 = 0.75.
```

This combines reductions in the transmission that remains; overlapping
effectiveness is not added directly.

### Modification Of Beta

The scheduled effectiveness modifies baseline beta:

```{math}
\beta_{d,n,a}
=
\beta_0(1-E_{d,n,a}).
```

The current disease-model loops use the beta multiplier associated with the
infectious/contacted age group when summing contact pressure. In compact form:

```{math}
\lambda_i(d,n)
=
s_i
\sum_j
\beta_{d,n,j}
C_{ij}
\frac{I_j^\ast}{N_n},
```

where $s_i$ is relative susceptibility, $C_{ij}$ is the contact matrix, and
$I_j^\ast$ is weighted infectious population.

NPIs currently modify within-node disease transmission. The binomial travel
model uses the disease model's baseline beta and does not apply the NPI
schedule to travel-associated exposure.

## Vaccine Release Timing

For stockpile entry $r$, let $d_r$ be its configured release day and $\ell$ be
`vaccine_eff_lag_days`. Its effective allocation day is:

```{math}
d_r^\ast = \max(0, d_r+\ell).
```

Entries mapping to the same effective day are summed:

```{math}
Q_d = \sum_{r:d_r^\ast=d} q_r.
```

The lag therefore shifts when people move from the unvaccinated susceptible
group to the vaccinated susceptible group. It is not a separate partially
protected state. The release amount $Q_d$ is deterministic: it is the fixed
sum of configured stockpile entries for that effective day, not a random draw.

## Age And Risk Eligibility

For age group $a$, the configured priority value selects risk groups:

```{math}
\mathcal{R}_a =
\begin{cases}
\varnothing, & p_a=0,\\
\{H\}, & p_a=0.5,\\
\{L,H\}, & p_a=1.
\end{cases}
```

These values define eligibility, not ordering. Doses are allocated
proportionally among eligible populations.

If enough doses, capacity, susceptible headroom, and adherence headroom are
available, every eligible susceptible person can be vaccinated. Targeting a
subgroup is therefore a scenario design choice, not a hidden priority queue:
people outside the configured age/risk eligibility are excluded from that run.
For example, a scenario can make all high-risk people eligible and also make
everyone in the 65-and-older age group eligible. The current vaccine stockpile
model does not support staged expansion of eligibility as the simulation
progresses, such as high-risk people first and everyone later. To compare
rollout targets, run separate scenarios with different eligibility vectors and
release schedules.

## Allocation Among Nodes

Let $P_n^{eligible}$ be the total population in eligible age/risk groups in
node $n$, including all disease and vaccine states. Let:

```{math}
P^{eligible} = \sum_n P_n^{eligible}.
```

For a release of $Q_d$ doses, the expected share for node $n$ is:

```{math}
x_n = Q_d\frac{P_n^{eligible}}{P^{eligible}}.
```

Each node first receives $\lfloor x_n\rfloor$, i.e. a node gets vaccines equivalent
to their share of the network population. If a node has half the total network population
then they'll receive half of the vaccine doses that become available. Remaining whole doses are
assigned one at a time to nodes with the largest fractional remainders:

```{math}
r_n = x_n-\lfloor x_n\rfloor.
```

This is the largest-remainder method. It preserves integer allocations while
keeping them as close as possible to population-proportional shares, 
i.e. having 50.35% of the population requires us to choose how to allocate 0.35% of doses.
No random sampling is used in this node-allocation step.

The network eligibility denominator is calculated when the vaccine strategy
is initialized. It includes all disease compartments, so ordinary disease
progression and vaccination do not change the proportional node weights.

## Stockpile Decay

For half-life $h$, the daily remaining-stock multiplier is:

```{math}
w = 0.5^{1/h}.
```

For node stock $V_{n,d}$ on days after day 0:

```{math}
V_{n,d}^{decayed} = wV_{n,d}.
```

Decay is applied to unused node stock before capacity and eligibility are
evaluated. Day-0 stock does not decay because it represents vaccination
already effective at the start of the epidemic.

## Daily Capacity

For capacity proportion $c$ and total node population $N_n$, the daily
capacity is:

```{math}
C_n = \left\lfloor cN_n \right\rfloor.
```

The doses offered for within-node allocation are:

```{math}
A_{n,d} = \min(V_{n,d}^{decayed}, C_n).
```

With the default $c=1$, day 0 may use up to the node's full population. Unused
stock above capacity rolls to the next day.

## Adherence Headroom

Within a node, consider eligible age/risk group $g$. Let:

- $S_g^U$ be unvaccinated susceptible people
- $N_g$ be total people in the age/risk group across all disease and vaccine
  states
- $V_g$ be all people already in the vaccinated subgroup
- $a_g$ be age-specific adherence

Remaining adherence capacity is:

```{math}
H_g^{adh}
=
\max(0,a_gN_g-V_g).
```

The group can receive at most:

```{math}
H_g
=
\min(S_g^U,H_g^{adh}).
```

This makes adherence a cumulative ceiling, not a daily probability. A group
with adherence 0.6 cannot exceed 60% ever vaccinated, even when additional
doses remain.

## Allocation Within A Node

Let total available headroom be:

```{math}
H = \sum_g H_g.
```

The expected allocation to group $g$ is:

```{math}
y_g = A_{n,d}\frac{H_g}{H}.
```

Each group first receives the floored amount, bounded by its headroom:

```{math}
v_g = \left\lfloor \min(y_g,H_g) \right\rfloor.
```

Remaining whole doses are assigned by largest fractional remainder to groups
that still have adherence and susceptible headroom. Doses that cannot be used
because of capacity, eligibility, susceptibility, or adherence roll to the
next day. This within-node allocation is deterministic: it transfers fixed
integer counts where eligible people are available.

Vaccination then conserves population by moving:

```{math}
S_g^U \rightarrow S_g^V
```

for exactly $v_g$ people. It does not move people between disease
compartments. Because people are discrete for allocation, a decayed residual
below one dose cannot vaccinate anyone and may be discarded by integer
rounding.

## Effectiveness Against Infection

For vaccinated susceptible age group $i$, infection effectiveness
$VE_i^{inf}$ multiplies force of infection:

```{math}
\lambda_i^V
=
(1-VE_i^{inf})\lambda_i^U.
```

Thus:

- $VE_i^{inf}=0$ gives no reduction
- $VE_i^{inf}=1$ gives complete modeled protection from infection

The same multiplier is applied to travel-associated exposure probability:

```{math}
p_{i,\mathrm{travel}}^V
=
(1-VE_i^{inf})p_{i,\mathrm{travel}}^U.
```

## Effectiveness Against Hospitalization

SEIHRD and SEITHRD apply hospitalization effectiveness to vaccinated
symptomatic people. Let $\pi_{H,r,i}$ be the corrected hospitalization split
multiplier for risk group $r$ and age $i$, and let $\eta_H$ be the base
`IS -> H` rate. The vaccinated hospitalization hazard is:

```{math}
r_{IS\to H}^{V}
=
\pi_{H,r,i}\eta_H(1-VE_i^{hosp}).
```

The competing `IS -> R` hazard is unchanged:

```{math}
r_{IS\to R}^{V}
=
(1-\pi_{H,r,i})\eta_R.
```

The realized probability of hospitalization among the two competing exits is
therefore:

```{math}
P(H\mid IS,V)
=
\frac{r_{IS\to H}^{V}}
{r_{IS\to H}^{V}+r_{IS\to R}^{V}}.
```

Vaccine effectiveness against hospitalization does not directly modify death
after hospitalization. It reduces deaths indirectly by reducing movement into
`H`.

## Current Boundaries

- Vaccine protection does not wane
- Only susceptible people are vaccinated
- Vaccine age/risk eligibility is fixed at scenario start; staged rollout to
  new target groups during the same run is not currently represented
- There are two vaccine groups: unvaccinated and vaccinated; boosters and
  multiple products are not represented
- NPI effectiveness modifies beta but does not change contact matrices,
  mobility flows, or travel-associated beta
- Vaccine allocation uses deterministic proportional allocation and integer
  largest-remainder rounding; it is not randomly sampled
