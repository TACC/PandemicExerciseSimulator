# Quickstart

## Install With Poetry

```bash
git clone https://github.com/TACC/PandemicExerciseSimulator.git
cd PandemicExerciseSimulator
poetry install --no-root
```

Check that the command-line interface works:

```bash
poetry run python3 src/simulator.py --help
```

## Run A Small Example

The state input files contain data paths beginning with `../data/`, so run them
from the repository's `data/` directory. Delaware has only three counties and
is a much faster introductory example than Texas.

```bash
cd data
poetry run python3 ../src/simulator.py \
  -l INFO \
  -d 10 \
  -i Delaware/INPUT_SEIHRD-STOCH_Delaware_R0-2.2_BASELINE.json
```

The command components are:

| Argument | Long form | Meaning |
| --- | --- | --- |
| `poetry run` | | Use the Poetry environment configured by the repository. |
| `python3 ../src/simulator.py` | | Start the simulator command-line program. |
| `-l INFO` | `--loglevel INFO` | Show normal progress messages. Use `DEBUG` for detailed model diagnostics; `WARNING` is the quieter default. Other accepted levels are `ERROR` and `CRITICAL`. |
| `-d 10` | `--days 10` | Simulate at most 10 days. The default is 365. A run can stop earlier if exposed and infectious compartments fall below the termination threshold. |
| `-i Delaware/...json` | `--input_filename Delaware/...json` | Load the named simulation input JSON. This argument is required. |

Use `INFO` for ordinary runs. `DEBUG` produces substantially more output and
is most useful while investigating configuration or model behavior.

## Install With Docker

```bash
docker build -t pes:latest .
docker run --rm pes:latest python3 src/simulator.py --help
```

`latest` is the local image tag for the most recently built code and does not
need to change for each software release.

## Run Tests

```bash
poetry run pytest
```

## Start From A Template

Input templates live in:

```text
data/INPUT_FILE_TEMPLATES/
```

Copy the template closest to your scenario, update the data paths and model
parameters, then pass that JSON file to `src/simulator.py`.
