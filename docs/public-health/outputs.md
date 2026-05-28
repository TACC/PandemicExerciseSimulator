# Outputs

For each simulation day, the simulator writes compartment totals and subgroup
details. For multiple realizations it writes CSV files; for a single
realization it can write JSON and a plot.

Each output run also includes metadata describing:

- the input data files;
- disease, travel, NPI, vaccine, and antiviral model parameters;
- runtime attributes derived from the parameters;
- a scenario hash;
- git commit and dirty-state information when available;
- random seed strategy.

This metadata is important for reproducibility. When sharing results, include
the metadata file with the daily outputs.
