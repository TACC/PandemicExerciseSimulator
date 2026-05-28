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

- compartment totals are conserved where expected;
- no compartment goes negative;
- stockpile caps are honored;
- dynamic compartment labels are respected;
- baseline beta re-derives the requested \(R_0\);
- metadata captures parameters that were actually used.
