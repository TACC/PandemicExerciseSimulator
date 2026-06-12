# Binomial Travel Model

The `binomial` travel model adds exposure between nodes without permanently
moving population. A traveler leaves their home node for the day's contact
calculation and returns home afterward. The population count assigned to each
node therefore remains unchanged.

Travel is evaluated after within-node disease progression each simulation day.
It can create new exposures in either direction for an origin-destination
pair:

1. infectious residents travel from their home node and expose susceptible
   people at the destination;
2. susceptible visitors travel to another node and encounter infectious
   residents who remained there.

Only the resulting susceptible-to-exposed movements are applied. Travelers
themselves are not removed from one node and added to another.

## Complete Configuration

```json
"travel_model": {
  "identity": "binomial",
  "parameters": {
    "rho": "1.0",
    "flow_reduction": ["1.0", "1.0", "1.0", "1.0", "1.0"],
    "traveling_compartments": {
      "I": "0.2"
    },
    "transmitting_compartments": {
      "I": "1.0"
    }
  }
}
```

| Parameter | Required | Description |
| --- | --- | --- |
| `identity` | Yes | Travel implementation. The supported value is `"binomial"`. |
| `rho` | Yes | Global multiplier on travel-associated transmission. `1.0` leaves the calculated pressure unchanged; `0.0` prevents travel-associated exposure. |
| `flow_reduction` | Yes | One positive divisor per susceptible age group. `1.0` means no reduction; `2.0` halves travel-associated transmission for that age group. |
| `traveling_compartments` | Yes | Compartment labels and effective weights for infectious residents who can travel and expose people at another node. |
| `transmitting_compartments` | Yes | Compartment labels and effective weights for infectious residents who can expose susceptible visitors arriving at their node. |

Every compartment label must exist in the selected disease model. Numeric
values may be JSON numbers or numeric strings.

## Traveling Versus Transmitting

The two dictionaries describe different contact routes:

| Setting | Who is infectious? | Who is exposed? |
| --- | --- | --- |
| `traveling_compartments` | A resident of the origin node who travels for the day | Susceptible people in the destination node |
| `transmitting_compartments` | A resident who remains associated with their local node | Susceptible visitors arriving from another node |

`transmitting_compartments` applies only to the travel calculation. It does
not select compartments for ordinary within-node disease transmission, which
is defined by the disease model.

The transmitting weight may reasonably be greater than the traveling weight.
Symptomatic people may continue to expose household or local contacts while
being less likely to travel.

For a model with one combined infectious compartment:

```json
"traveling_compartments": {
  "I": "0.2"
},
"transmitting_compartments": {
  "I": "1.0"
}
```

This treats 20% of `I` as an effective traveling infectious population while
all of `I` contributes to exposure of visitors at the home node. It can
approximate a scenario where 20% of infections are asymptomatic and continue
traveling even though the model does not have a separate asymptomatic
compartment.

## Effective Weights

Each value is a multiplier on the number of people in that compartment. It can
represent:

- the fraction who make relevant trips;
- infectiousness relative to a reference compartment;
- a combined assumption about travel behavior and relative infectiousness.

When asymptomatic and symptomatic states are modeled separately, the weights
can preserve the disease model's relative-infectiousness assumptions:

```json
"traveling_compartments": {
  "IA": "0.97",
  "IP": "0.45"
},
"transmitting_compartments": {
  "IA": "0.97",
  "IP": "0.45",
  "IS": "1.0"
}
```

Here `IS` is the reference infectious compartment. `IA` and `IP` use their
infectiousness relative to `IS`, while symptomatic `IS` does not travel but
can expose visitors locally.

If only a fraction of a compartment travels, combine that fraction with
relative infectiousness. For example, if `T` is half as infectious as `I` and
40% of treated people travel, its effective traveling weight is:

```{math}
0.5 \times 0.4 = 0.2.
```

The model does not separately identify those two components, so scenario notes
should record how each configured weight was derived.

## Exposure Draw

Travel flow, weighted infectious populations, the contact matrix, beta,
relative susceptibility, `rho`, and `flow_reduction` are combined into an
age-specific probability. New exposures in each susceptible age, risk, and
vaccine group are then drawn as:

```{math}
X_{\mathrm{travel}} \sim
\operatorname{Binom}(S, p_{\mathrm{travel}}).
```

Vaccine effectiveness reduces the probability for vaccinated susceptible
groups. The probability is capped between 0 and 1, and the binomial draw
cannot expose more people than are currently susceptible.

Because this draw is stochastic, using a deterministic disease model does not
make the complete network simulation deterministic while binomial travel is
enabled.
