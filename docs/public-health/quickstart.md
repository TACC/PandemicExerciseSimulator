# Quickstart

## Install With Poetry

```bash
git clone https://github.com/TACC/PandemicExerciseSimulatorTACC.git
cd PandemicExerciseSimulatorTACC
poetry install --no-root
```

Check that the command-line interface works:

```bash
poetry run python3 src/simulator.py --help
```

Run a short example:

```bash
poetry run python3 src/simulator.py \
  -l INFO \
  -d 10 \
  -i data/Texas/INPUT_SEIHRD-STOCH_Texas_R0-2.2_BASELINE.json
```

## Install With Docker

```bash
docker build -t pes:0.1.0 .
docker run --rm pes:0.1.0 python3 src/simulator.py --help
```

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
