# LS6 pipeline container

Build from the repository root using `containers/ls6-pipeline.def`. The public
base is [`rocker/geospatial:4.4.2`](https://hub.docker.com/r/rocker/geospatial/tags).
No personal SIF, home-directory R library, or host Python installation is needed.
The image adds Python 3.12, Poetry 2.1.3 in a separate tools environment, Python
main dependencies from `pyproject.toml` / `poetry.lock`, and the R packages used
by orchestration and fitting. It does not promise every optional dashboard or
publication dependency. R package versions and the Python patch/build are
resolved at build time; the recipe is not bit-for-bit reproducible.

## Build on LS6

Use an allocated compute node with sufficient temporary disk space, time, and
network access. Start your normal `idev` allocation before these commands.
Run from your checkout's root; use your own output path:

```bash
module load tacc-apptainer
export APPTAINER_CACHEDIR="$SCRATCH/apptainer-cache"
export APPTAINER_TMPDIR="${TMPDIR:-/tmp}/pes-apptainer-build"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

apptainer build --fakeroot "$WORK/pes_pipeline_r442_py312.sif" containers/ls6-pipeline.def
```

The recipe's `%files` copies only repository files. Python and R dependencies
are installed at build time; inputs, outputs, and source code stay outside the
image. Rebuild when dependency requirements change. Keep `pyproject.toml` and
`poetry.lock` synchronized. The build checks imports and ordinary Rscript
invoking Poetry. Do not bypass failing build tests.

The earlier recipe extended one user's SIF and copied that user's R library.
That dependency has been removed. Existing images built with the earlier
recipe can still use the wrapper below. Sharing a completed SIF also lets
collaborators run the same environment without independently rebuilding it;
no image has been published automatically.

A working unprivileged/fakeroot build configuration is required. A missing
external fakeroot helper can be a warning; a namespace or permission failure
that stops installation requires TACC support or building on another x86_64
Linux host with the required privileges. Copy the completed SIF back to LS6.
Allow substantial space for the base image, Python environments, and R builds.
The public base includes curl, tar, certificates, and the geospatial toolchain;
additional R system-dependency failures, if any, must be resolved in the recipe.
This revised public-base image has not been built or executed by Codex.

## Configure generated fitting and scenario commands

Set `execution_target = "ls6"` in the pipeline inputs and call script 0
normally. Both fitting and scenario commands automatically run through
`scripts/ls6_container_exec.sh`; no command rewriting or extra image setting
is required. Their shell launchers automatically load `tacc-apptainer`,
preserving allocation edits.

At job execution, the wrapper selects `$WORK/pes_pipeline_r442_py312.sif`.
This is the output location used by the build command above. `$WORK` is resolved
on LS6, so script 0 can also generate commands from another machine.
For an image stored elsewhere, optionally set `ls6_container_image` to its SIF
path in the experiment inputs, use `--ls6-container-image=...`, or export
`PES_CONTAINER_IMAGE` in the job environment. An explicit configuration path
takes precedence over the environment variable. `execution_target = "local"`
keeps local commands native even if an image override is present.

The wrapper uses `--cleanenv`, clears the earlier injected host PATH/library
workarounds, binds the checkout plus `/work,/scratch`, and sets the repository's
`containers/ls6-runtime.Rprofile`. This restores the image's Python and Poetry
paths after R startup, including for older successfully built images. It does
not require `Rscript --vanilla`. Do not bind host `/opt` over the container's
`/opt`, where its environments live. Set `PES_CONTAINER_BINDPATH` to override
the default extra bind list if using a different cluster or filesystem layout.

## Smoke test and submit

From the checkout root, test the actual simulator import path without running
simulations:

```bash
bash scripts/ls6_container_exec.sh --image "$WORK/pes_pipeline_r442_py312.sif" \
  poetry run python3 src/simulator.py --help

bash scripts/ls6_container_exec.sh --image "$WORK/pes_pipeline_r442_py312.sif" \
  Rscript -e 'print(Sys.which(c("poetry", "python3"))); stopifnot(system2("poetry", c("run", "python3", "--version")) == 0L)'
```

Inspect the generated command and allocation settings before submitting the
existing launcher through your normal `sbatch` workflow. PyLauncher stays on
the host; each fitting or scenario command runs inside the container.
