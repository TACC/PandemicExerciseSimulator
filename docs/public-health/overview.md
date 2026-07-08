# What This Simulator Does

The simulator helps public health teams ask operational questions such as:

- How quickly could an outbreak spread across counties
- Which age groups drive transmission under a given contact pattern
- How much do vaccines, antivirals, travel, or non-pharmaceutical interventions (NPIs) change the epidemic curve
- What happens when limited stockpiles are released on specific days

Each run begins with an input JSON file. That file points to population,
contact, mobility, and high risk of hospitalization ratios, then selects disease, travel,
vaccine, antiviral, and NPI models. Population and contact are state-specific age-stratified values, while high risk of hospitalization ratios are derived from state-level data to be county-specific. Mobility is county-specific based on cellphone travel data provided by SafeGraph from 2019 that was made opensource during the COVID-19 pandemic. The simulator uses the same contact and mobility matrices each day, so we do not have weekend effects.

The term "risk" currently always refers to risk of hospitalization. Higher risk of infection and targeting interventions for front line workers is a planned addition for future iterations.

The simulator advances one day at a time. On each day it can:

1. Release stockpiles of antivirals or vaccines to nodes/counties or limit travel with an NPI.
2. Give vaccines and antivirals to eligible groups by age and/or risk.
3. Progress disease states within each county and demographic subgroup.
4. Spread disease through travel between counties.
5. Write outputs for the day.

The output can be used as a comparison between scenarios or a starting point for more formal calibration and sensitivity analysis.

## Current Boundaries

- Contact and mobility matrices are constant by simulation day; weekend,
  holiday, and behavioral feedback effects are not modeled automatically
- “Risk” means risk of hospitalization. Separate infection-risk categories,
  such as occupational exposure for frontline workers, are not yet available
- Vaccination has unvaccinated and vaccinated groups but no waning, boosters,
  or multiple vaccine products
- Vaccine stockpile eligibility by age and hospitalization-risk group is fixed
  for a scenario. The simulator does not currently model staged rollout from
  one target group to another during the same run.
- The daily stochastic models use Poisson transitions. Alternative
  distributions for superspreading, such as a negative binomial force of
  infection, are not currently implemented
- County connectivity rankings are produced by the preparation pipeline, but
  centrality is not itself a disease-model parameter
- National result maps and sensitivity-analysis figures are analysis products,
  not generated automatically by the simulator
