# Input Templates

Templates live in:

```text
data/INPUT_FILE_TEMPLATES/
```

When adding a new model template:

1. Use an explicit model identity.
2. Include the exact compartment list required by the model.
3. Keep parameter names close to code names.
4. Include empty optional sections, such as `{}` for unused vaccine or antiviral models.
5. Prefer strings for numeric values if matching existing templates.
6. Use `"GENERATE"` for `output_dir_path` and `batch_num` unless a workflow
   requires fixed values.
7. Include editable `metadata_tags` examples for `creator`, `disease`,
   `sim_day_0`, and `notes`.

## Generated Output Names

The standard template header is:

```json
{
  "output_dir_path": "GENERATE",
  "realization_range": ["0", "99"],
  "batch_num": "GENERATE"
}
```

These two `GENERATE` values have different purposes:

- `output_dir_path: "GENERATE"` Creates a scenario directory named
  `<STATE>_<SCENARIO_HASH>`. The state or region name is read from the
  population-data path, and the scenario hash is the full SHA-256 hash of the
  canonical scenario configuration
- `batch_num: "GENERATE"` Creates a UUIDv7 for that execution. The UUID is used
  in output filenames such as `metadata_batch-<UUID>.json` and
  `network_batch-<UUID>.csv`

The scenario hash does not include the output path, batch UUID, random seed, or
JSON formatting differences such as numeric `1` versus `1.0`. Re-running an
equivalent scenario therefore produces the same scenario directory name but a
different batch UUID. This is the organization expected by the post-processing
and dashboard scripts.

Use a fixed output path only when outputs should go to a deliberately managed
directory. Use a fixed batch number only when an external workflow already
provides a unique identifier; reusing a batch number can overwrite or confuse
files from separate executions.

Current useful templates include:

- `INPUT_SEIRS-STOCH_BASELINE.json`
- `INPUT_SEAITRD-STOCH_ANTIVIRAL.json`
- `INPUT_SEITRS-STOCH_BASELINE.json`
- `INPUT_SEITRS-DET_ANTIVIRAL.json`
- `INPUT_SEIHRD-STOCH_STATE_R0-2.2_BASELINE.json`
- `INPUT_SEIHRD-STOCH_STATE_R0-2.2_VAX.json`
- `INPUT_SEIHRD-STOCH_ANTIVIRAL.json`

SEITRS templates should include both a `T` compartment and an `antiviral_model`
block when treatment is part of the scenario. SEIRS, SEITRS, SEIHRD, and
SEITHRD inputs can omit `T` when treatment is not modeled.
SEITHRD templates should also include `T_to_R_days`, `rel_inf_T_to_IS`,
`antiviral_effectiveness_hosp`, and antiviral `compartment_priority` values
that match the SEIHRD compartment labels. Use `IS_to_R_days = 7.0` and
`T_to_R_days = 5.0` for the default 2-day antiviral reduction, and use
`["IS"]` as the default SEITHRD `compartment_priority` unless the template is
specifically for prophylaxis.

SEAITRD templates must always include the Treated compartment `T` in
`disease_model.parameters.compartments`, for both deterministic and stochastic
SEAITRD. This is the main difference from the other model families. SEAITRD
enters `T` only through stockpile-constrained treatment from configured
eligible compartments such as `I`, `A`, or `E`; if no antiviral doses are
released, `T` remains empty. SEAITRD templates should provide `I_to_R_days` and
`T_to_R_days` separately, `I_to_D_invdays` for untreated mortality, and
`antiviral_effectiveness_death` in antiviral scenarios so treated mortality can
be derived.
