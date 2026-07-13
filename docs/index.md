# Pandemic Exercise Simulator

The Pandemic Exercise Simulator is a county-level outbreak simulation tool for
planning exercises, intervention comparisons, and epidemiological methods
development. It combines compartmental disease models, age-structured contact
matrices, county mobility, vaccination stockpiles, antiviral stockpiles, and
non-pharmaceutical interventions.

This documentation is written for two audiences:

- **Public health professionals** who need to run scenarios, read inputs, and
  interpret outputs
- **Epidemiologist developers** who need the model equations, stochastic
  assumptions, calibration details, and extension points

```{toctree}
:maxdepth: 2
:caption: Public Health Walkthrough

public-health/overview
public-health/quickstart
public-health/input-files
public-health/scenario-workflow
public-health/interventions
public-health/outputs
```

```{toctree}
:maxdepth: 2
:caption: Modeling Reference

modeling/compartments
modeling/simulation-methods
modeling/math
modeling/calibration
modeling/county-age-initialization
modeling/travel
modeling/npis-vaccines
modeling/antivirals
```

```{toctree}
:maxdepth: 2
:caption: Developer Guide

developer/architecture
developer/templates
developer/scripts
developer/testing
developer/readthedocs
```
