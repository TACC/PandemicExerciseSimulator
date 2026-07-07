# Stochastic And Deterministic Methods

The simulator contains several numerical methods. A model name ending in
`-stochastic` includes random draws within each node. A model ending in
`-deterministic` moves expected fractions of the population instead.

The travel model is separate from the disease model. The available binomial
travel model is stochastic, so a deterministic disease model can still produce
different network-level results across realizations when travel is enabled.
Vaccine and antiviral stockpile releases are deterministic scheduled counts:
they transfer fixed numbers of doses or people where eligible, and do not add
another random draw to the simulation.

## Method Summary

| Method | Models | Population representation | Main runtime driver |
| --- | --- | --- | --- |
| Gillespie-style event queue | `seaitrd-stochastic` | Individual people and scheduled events | Total infections and events in the queue |
| Daily Poisson tau-leaping | `seir-stochastic`, `seirs-stochastic`, `seitrs-stochastic`, `seihrd-stochastic`, and SEITHRD configurations | Integer compartment counts | Nodes, demographic groups, and simulation days |
| Daily Euler update | `seirs-deterministic`, including SEIR and SEITRS compartment configurations; `seaitrd-deterministic` | Fractional compartment counts | Nodes, demographic groups, and simulation days |
| Binomial travel | `binomial` travel with any disease model | Integer new exposures | Origin-destination node pairs |

## Gillespie-Style SEAITRD

`seaitrd-stochastic` assigns a queued infection trajectory when a person enters
`E`. Waiting times are sampled with `rand_exp_min1`, which enforces at least one
day in each sampled stage. The queue then processes one-person progression
events such as:

```{math}
E \rightarrow A,\quad
A \rightarrow I,\quad
I,T \rightarrow R \text{ or } D.
```

The `T` compartment is entered only through stockpile-allocated antiviral
treatment from configured eligible compartments such as `I`, `A`, or `E`.
Natural untreated progression bypasses `T`.

Because each infected person creates several scheduled events, runtime grows
with population size and epidemic size. This model can become impractical for
real county populations, especially with a high $R_0$ or many realizations.
Use a small population or short validation scenario before committing to a
large run.

The event queue preserves population: every valid progression event removes
one person from its source compartment and adds one person to its destination.
Events invalidated by earlier antiviral treatment are discarded.

## Daily Poisson Tau-Leaping

The other stochastic models update compartment counts once per simulation day.
For a transition with rate $r$ and source count $X$, the proposed movement is:

```{math}
\Delta \sim \operatorname{Pois}(rX).
```

Each draw is capped by the people remaining in the source compartment. For
competing exits, the implementation draws from the remaining population so
compartments cannot become negative.

Tau-leaping is much faster than the individual SEAITRD queue because it tracks
counts rather than a separate trajectory for every infected person. Runtime is
usually more sensitive to the number of counties, demographic groups, and
realizations than to the absolute population count.

## Daily Euler Updates

Deterministic models use the same one-day transition structure but move the
expected amount directly instead of drawing from a Poisson distribution. This
allows fractional people and produces smooth within-node trajectories.

Euler updates can approach zero without reaching exactly zero because
fractions continue moving between compartments. The simulator therefore uses
a stopping tolerance rather than requiring every infectious compartment to be
exactly zero.

Stochastic and deterministic versions of the same compartment structure use
the same biological parameter meanings. Their difference is whether daily
movements are random integer draws or expected fractional movements.

## Binomial Travel

At the end of each simulation day, the travel model evaluates origin-
destination node pairs. Infectious travelers can seed exposure at their
destination, and susceptible travelers can be exposed to infection at the
destination.

For each susceptible age, risk, and vaccine subgroup, new travel-associated
exposures are drawn from a binomial distribution:

```{math}
X_{\mathrm{travel}} \sim \operatorname{Binom}(S, p_{\mathrm{travel}}).
```

The probability combines the mobility flow, contact matrix, disease
transmission coefficient, relative susceptibility, vaccination, and the
configured transmitting and traveling compartments.

Consequently, `-deterministic` describes disease progression within nodes; it
does not make the complete network simulation deterministic while binomial
travel is active (more than one node in the network).

See [Binomial Travel Model](travel.md) for the complete parameter reference and
the distinction between traveling and locally transmitting compartments.

## Choosing Realizations

One realization is useful for checking that an input runs, but not for
estimating a stochastic outcome. Begin with roughly 5 to 100 realizations,
depending on runtime and variability, then increase the count when rare
epidemic emergence or extinction dominates the result. Small populations,
$R_0$ close to 1, or few initial infections will drive-up stochasticity.

For example, an $R_0$ below 1 should naturally decline without intervention.
Conversely, seeding very few infections in a rural county may require hundreds
or thousands of realizations to distinguish a failed introduction from a
scenario where an epidemic can emerge.
