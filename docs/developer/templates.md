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

Current useful templates include:

- `INPUT_SEIRS-STOCH_BASELINE.json`
- `INPUT_SEITRS-STOCH_BASELINE.json`
- `INPUT_SEIHRD-STOCH_STATE_R0-2.2_BASELINE.json`
- `INPUT_SEIHRD-STOCH_STATE_R0-2.2_VAX.json`

SEITRS templates should include both a `T` compartment and an `antiviral_model`
block when treatment is part of the scenario.
