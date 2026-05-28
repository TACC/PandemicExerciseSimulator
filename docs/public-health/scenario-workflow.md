# Scenario Workflow

A practical scenario workflow is:

1. Choose a geography and verify the data files.
2. Choose the disease model and compartment list.
3. Set `R0`, disease durations, and relative infectiousness values.
4. Choose travel assumptions.
5. Add interventions one at a time.
6. Run a baseline, then run comparison scenarios.
7. Review daily outputs and metadata.

## Recommended Scenario Comparisons

Keep a baseline scenario with no interventions except the initial infections.
Then compare:

- vaccination release timing and prioritization;
- antiviral release timing and prioritization;
- NPI timing, duration, and age targeting;
- mobility reductions;
- alternate initial infection locations.

## Naming Outputs

Use `metadata_tags` in input JSON files to label runs with exercise-relevant
names, assumptions, or scenario families. The simulator also writes a metadata
file that records the resolved parameters and runtime attributes.
