# Testing

Run the full test suite with:

```bash
poetry run pytest
```

Run focused tests while developing:

```bash
poetry run pytest test/test_DiseaseModel.py
poetry run pytest test/test_StochasticSEIRS.py
poetry run pytest test/test_AntiviralStockpileStrategy.py
```

Good tests for this codebase usually check:

- Compartment totals are conserved where expected
- No compartment goes negative
- Stockpile caps are honored
- Dynamic compartment labels are respected
- Baseline beta re-derives the requested $R_0$
- Metadata captures parameters that were actually used
