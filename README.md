## PandemicExerciseSimulator

This is a Python command line implementation of a pandemic exercise simulator
using a SEATIRD compartment model.

### Install:

Depends on [Poetry](https://python-poetry.org/docs/#installation) for native install.
After installing Poetry, do:

```
$ git clone https://github.com/TACC/PandemicExerciseSimulator
$ cd PandemicExerciseSimulator/
$ poetry install --no-root
```

The above will create a virtual environment. You can automatically access the virtual
environment by prefacing your commands with 'poetry run'. For example:

```
$ poetry run python3 src/simulator.py --help
$ poetry run python3 src/simulator.py -l INFO -d 10 -i data/texas/INPUT.json
```


### Docker:

Instead of installing Poetry, you can run a containerized version of the simulator
with [Docker](https://docs.docker.com/engine/install/).

```
$ docker build -t pes:0.1.0 .
$ docker run --rm pes:0.1.0 python3 src/simulator.py --help
$ docker run --rm pes:0.1.0 python3 src/simulator.py -l INFO -d 10 -i data/texas/INPUT.json
```


### Test:

```
$ poetry run pytest
```

### Input Data Required:

The simulator requires the data from the following folder:
```
.
└── data
    └── texas
        ├── INPUT.json
        ├── contact_matrix.5
        ├── county_age_matrix.5
        ├── high_risk_ratios.5
        ├── nu_value_matrix.5
        ├── relative_susceptibility.5
        ├── vaccine_adherence.5
        ├── vaccine_effectiveness.5
        └── work_matrix_rel.csv
```

* **INPUT.json:** Simulation properties file (see schema)
* **contact_matrix.5:** 5x5 matrix of contact ratios between age groups
* **county_age_matrix.5:** Populations for each county divided into age groups
* **high_risk_ratios.5:** List of risk ratio for each age group
* **nu_value_matrix.5:** Nx4 columns (N=num of age groups) low/high death rate x low/high risk. Nu
  is the transmitting (asymptomatic/treatable/infectious) to deceased rate
* **relative_susceptibility.5** List of relative susceptibility for each age group
* **vaccine_adherence.5:** List of vaccine adherences for each age group
* **vaccine_effectiveness.5:** List of vaccine effectiveness for each age group
* **work_matrix_rel.csv:** NxN matrix (N=num of counties) for travel flow


### Parameters Required:

Among other things, the following parameters are expected to be defined in the 
INPUT.json file:

* **R0:** (ex: 1.8) Reproduction number
* **beta_scale:** (ex: 65) R0 correction factor - R0 is divided by this value and stored as beta
* **tau:** (ex: 0.83333333) exposed to asymptomatic rate
* **kappa:** (ex: 0.52631579) asymptomatic to treatable rate
* **gamma:** (ex: 0.24390244) transmitting (asymptomatic/treatable/infectious) to recovered rate
* **chi:** (ex: 1.0) treatable to infectious rate
* **nu_high**: ("yes" or "no") use high or low death rates
* **vaccine_wastage_factor:** (ex: 60) half the vaccine stockpile will be wasted every N days
* **antiviral_effectiveness:** (ex: 0.8) antiviral effectiveness factor
* **antiviral_wastage_factor:** (ex: 60) half the antiviral stockpile will be wasted every N days



### Notes

* contact_matrix.5, county_age_matrix.5, and work_matrix_rel.csv: all taken from original
  data
* vaccine_effectiveness.5: used to be in properties file under 'params', but the five age
  groups were hardcoded. Pulled this out into its own file
* vaccine_adherence.5: used to be in properties file under 'params', but the five age
  groups were hardcoded. Pulled this out into its own file
* relative_susceptibility.5: was hardcoded as `SIGMA` in `ModelParameters.cpp`, but pulled
  it out and made it its own file.
* high_risk_ratios.5: was hardcoded in `ModelParameters.cpp`, but pulled it out and made it
  its own file
* relative_susceptibility.5: was hardcoded as `nu[][]` in `ModelParameters.cpp`, took this out and
  made it its own file
* Params (chi=1.0): Chi was originally hardcoded in `ModelParameters.cpp`, took this out and made
  it a param.
* Params (vaccine_wastage_factor=60): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. "Every N days half the stock pile is wasted"
* Params (antiviral_wastage_factor=60): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. "Every N days half the stock pile is wasted"
* Params (antiviral_effectievness=0.8): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. 


### Future Development Notes

* Needs functionality to scroll to a certain date in time, change parameters, then
  continue run from there.
* Model should be checkpointable and show provenance of how it arrived there
* Should be able to compare counties easily
* Implement proper schema for inputs and outputs https://github.com/python-jsonschema/jsonschema
