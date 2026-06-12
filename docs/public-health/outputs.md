# Outputs

For each simulation day, the simulator writes compartment totals and subgroup
details. For multiple simulations it writes CSV files; for a single
simulation it can write JSON and a plot. Running more than one simulation is preferable,
because stochastic models and the travel model inject noise into outcomes. You will
want to visualize a range of possibilities (spaghetti plots) in the Shiny dashboard.

Each output run also includes metadata describing:

- The input data files
- Disease, travel, NPI, vaccine, and antiviral model parameters
- Runtime attributes derived from the parameters
- A scenario hash
- Git commit and dirty-state information when available
- Random seed strategy

This metadata is important for reproducibility. When sharing results, include
the metadata file with the daily outputs.

## Scenario And Batch Identity

With `"output_dir_path": "GENERATE"`, outputs are written to:

```text
<STATE>_<SCENARIO_HASH>/
```

The full SHA-256 scenario hash groups semantically equivalent configurations.
It is based on normalized data paths, model identities and runtime attributes,
initial infections, and NPIs. Output location, tags, batch identifier, random seed,
and superficial numeric differences such as `1` versus `1.0` do not create a
new scenario hash.

With `"batch_num": "GENERATE"`, each execution receives a UUIDv7. The batch UUID
appears in every output filename and in the metadata. A rerun of the same
scenario therefore has the same scenario hash and a new batch UUID.

This two-level identity is used by `scripts/7a_process_output_to_db.R`:

```text
sim_data/<scenario_hash>/<batch_uuid>/
├── network.parquet
├── nodes.parquet
└── simulation_times.parquet
```

The pair `(scenario_hash, batch_num)` is the ingestion and deduplication key.
The dashboard in `scripts/7b_sim_dashboard_app.R` uses the same structure to
compare scenarios, inspect individual batches, and visualize simulation
trajectories.
