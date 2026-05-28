# Input Files

Each simulation is controlled by one JSON file. The main sections are:

| Section | Purpose |
| --- | --- |
| `data` | Paths to population, contact, mobility, and risk-ratio files. |
| `disease_model` | Disease model identity and model parameters. |
| `travel_model` | Travel model identity and travel parameters. |
| `initial_infected` | Seed infections by county and age group. |
| `non_pharma_interventions` | Optional transmission reductions by day, place, and age. |
| `antiviral_model` | Optional antiviral stockpile strategy. |
| `vaccine_model` | Optional vaccine stockpile strategy. |

## Required Data Files

The data directory for a state or region should contain:

- `INPUT_*.json`: simulation properties file.
- `contact_matrix_*_Mistry2021_all.csv`: age-by-age daily contacts.
- `county_pop_by_age_*.csv`: county population by age group.
- `*_high-risk-ratios-*.csv`: age-specific high-risk proportions.
- `*_mobility-matrix.csv`: county-by-county mobility matrix.

The order of age groups must match between the population file, contact matrix,
vaccine parameters, antiviral parameters, and any age-specific disease
parameters.

## Initial Infections

Initial infections are placed into the low-risk unvaccinated exposed
compartment for the requested age group.

```json
"initial_infected": [
  {
    "county": "48113",
    "infected": "10",
    "age_group": "2"
  }
]
```

If more people are requested than are susceptible in that group, the simulator
only exposes the available susceptible population.
