## Pandemic Exercise Simulator Documentation

This branch is for building and publishing the Read the Docs site for the
Pandemic Exercise Simulator:

```text
https://pandemicexercisesimulator-test.readthedocs.io/en/latest/
```

Read the Docs builds the site from the files in `docs/`. Sphinx is the
documentation build engine used by Read the Docs and by the local preview
commands below.

This documentation branch is separate from the simulator code branch. The
simulator codebase, runtime instructions, data preparation workflow, tests, and
release-specific source files are on the `main` branch of the
`TACC/PandemicExerciseSimulator` repository, or in a tagged release.

### Requirements

Documentation dependencies are managed with
[Poetry](https://python-poetry.org/docs/#installation). This branch requires
Python 3.11 or newer for the documentation build tools.

If Poetry selects an older Python, point it at a supported interpreter:

```bash
poetry env use python3
```

Install the documentation dependencies:

```bash
poetry install --with docs --no-root
```

### Build The Docs

Build the Read the Docs HTML site locally from the repository root:

```bash
poetry run sphinx-build docs docs/_build/html
```

The generated site starts at:

```text
docs/_build/html/index.html
```

### Preview Edits Live

Run the live documentation preview from the repository root:

```bash
poetry run sphinx-autobuild docs docs/_build/html
```

By default, the preview is served at:

```text
http://127.0.0.1:8000/
```

Keep the command running while editing files under `docs/`. The site rebuilds
automatically when documentation source files change.

### Read The Docs

Read the Docs uses `.readthedocs.yaml`, `docs/conf.py`, `pyproject.toml`, and
`poetry.lock` to build this branch for the hosted documentation site.

Commit documentation source changes from `docs/` along with any dependency
updates in `pyproject.toml` and `poetry.lock`.
