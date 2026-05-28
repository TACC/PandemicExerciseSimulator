# What This Simulator Does

The simulator helps public health teams ask operational questions such as:

- How quickly could an outbreak spread across counties?
- Which age groups drive transmission under a given contact pattern?
- How much do vaccines, antivirals, travel, or NPIs change the epidemic curve?
- What happens when limited stockpiles are released on specific days?

Each run begins with an input JSON file. That file points to population,
contact, mobility, and high-risk ratio data, then selects disease, travel,
vaccine, antiviral, and NPI models.

The simulator advances one day at a time. On each day it can:

1. Release stockpiles to nodes.
2. Apply vaccines and antivirals to eligible groups.
3. Progress disease states within each county and demographic group.
4. Move infections through travel between counties.
5. Write outputs for the day.

The output can be used as an exercise artifact, a comparison between scenarios,
or a starting point for more formal calibration and sensitivity analysis.
