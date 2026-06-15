# Editing And Publishing These Docs

The documentation uses Sphinx, MyST Markdown, and Read the Docs.

## Edit Locally

Documentation source files live in:

```text
docs/
```

Most pages are Markdown files. Edit them in your normal editor and commit them
with the code.

## Build Locally

Install the documentation dependencies:

```bash
python3 -m pip install -r docs/requirements.txt
```

Build HTML:

```bash
sphinx-build -b html docs docs/_build/html
```

Open the local build:

```bash
open docs/_build/html/index.html
```

On Linux, use `xdg-open` instead of `open`.

## Preview Edits Live

For documentation editing, `sphinx-autobuild` is included in
`docs/requirements.txt` as an optional authoring tool. It is only needed by
contributors who want live browser refreshes while editing docs.

Install the documentation dependencies in your active Python environment:

```bash
python3 -m pip install -r docs/requirements.txt
```

Start the live preview server from the repository root:

```bash
sphinx-autobuild docs docs/_build/html --open-browser
```

If your shell cannot find the `sphinx-autobuild` command, confirm that the same
environment used for installation is active, or run it as a Python module:

```bash
python3 -m sphinx_autobuild docs docs/_build/html --open-browser
```

By default, the preview is served at `http://127.0.0.1:8000/` and rebuilds when
files under `docs/` change.

## Host On Read The Docs

1. Commit and push `.readthedocs.yaml`, `docs/conf.py`, and the `docs/` pages.
2. Create a Read the Docs account at `https://readthedocs.org/`.
3. Connect your GitHub account.
4. Import this repository as a new documentation project.
5. Let Read the Docs build the default branch.
6. In project settings, confirm that it is using `.readthedocs.yaml`.

After that, every push to the configured branch can trigger a new documentation
build.

## Configuration Files

`.readthedocs.yaml` tells Read the Docs:

- Which operating system image to use
- Which Python version to use
- Where the Sphinx configuration file lives
- Which documentation requirements to install

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
