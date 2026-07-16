# Editing And Publishing These Docs

The documentation uses Sphinx, MyST Markdown, and Read the Docs.
It is maintained on the repository's documentation branch, separate from the
simulator code on `main`.

The hosted site is:

```text
https://pandemicexercisesimulator-test.readthedocs.io/en/latest/
```

## Edit Locally

Documentation source files live in:

```text
docs/
```

Most pages are Markdown files. Edit them in your normal editor and commit the
documentation changes to the documentation branch. Code changes belong on the
repository's `main` branch.

## Build Locally

Install the documentation dependencies from the repository root:

```bash
poetry install --with docs --no-root
```

Build HTML:

```bash
poetry run sphinx-build -b html docs docs/_build/html
```

Open the local build:

```bash
open docs/_build/html/index.html
```

On Linux, use `xdg-open` instead of `open`.

## Preview Edits Live

For documentation editing, `sphinx-autobuild` is included in the Poetry
`docs` dependency group. It is only needed by contributors who want live
browser refreshes while editing docs.

Start the live preview server from the repository root:

```bash
poetry run sphinx-autobuild docs docs/_build/html
```

By default, the preview is served at `http://127.0.0.1:8000/` and rebuilds when
files under `docs/` change.

## Host On Read The Docs

Read the Docs builds this documentation branch using `.readthedocs.yaml`.
That file installs Poetry, runs `poetry install --with docs --no-root`, and
builds HTML with:

```bash
poetry run sphinx-build -b html docs $READTHEDOCS_OUTPUT/html
```

For routine publishing:

1. Commit and push `.readthedocs.yaml`, `docs/conf.py`, `pyproject.toml`,
   `poetry.lock`, and the `docs/` pages when they change.
2. Confirm the Read the Docs project is configured to build the documentation
   branch, not the simulator-code `main` branch.
3. In project settings, confirm that it is using `.readthedocs.yaml`.

After that, every push to the configured branch can trigger a new documentation
build.

## Configuration Files

`.readthedocs.yaml` tells Read the Docs:

- Which operating system image to use
- Which Python version to use
- Where the Sphinx configuration file lives
- Which Poetry dependency group to install
- Which Sphinx build command to run

`docs/conf.py` configures Sphinx itself. It enables Markdown, LaTeX math, and
the Read the Docs theme.

## Writing Math

Use MyST math blocks:

````markdown
```{math}
R_0 = \rho(K)
```
````

Inline math can use dollar syntax, such as `$R_0$`.
