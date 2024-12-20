## PandemicExerciseSimulator

This is a stand-alone Python command line implementation of a pandemic exercise
simulator using a SEATIRD compartment model and binomial travel model.

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

As an alternative to Poetry, you can instead run a containerized version of the
simulator with [Docker](https://docs.docker.com/engine/install/).

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
        ├── contact_matrix.csv
        ├── county_age_matrix.csv
        ├── flow_reduction.csv
        ├── high_risk_ratios.csv
        ├── relative_susceptibility.csv
        └── work_matrix_rel.csv
```

* **INPUT.json:** Simulation properties file (see schema)
* **contact_matrix.csv:** 5x5 matrix of contact ratios between age groups
* **county_age_matrix.csv:** Populations for each county divided into age groups
* **flow_reduction.csv:** Factor for reducing travel frequency by age group
* **high_risk_ratios.csv:** List of risk ratio for each age group
* **relative_susceptibility.csv** List of relative susceptibility for each age group
* **work_matrix_rel.csv:** NxN matrix (N=num of counties) for travel flow


### Parameters Required:

At a minimum, the following parameters are expected to be defined in the 
INPUT.json file:

* **R0:** (ex: 1.2) Reproduction number
* **beta_scale:** (ex: 65) R0 correction factor - R0 is divided by this value and stored as beta
* **tau:** (ex: 1.2) latency period in days (exposed to asymptomatic)
* **kappa:** (ex: 1.9) asymptomatic infectious period in days (asymptomatic to treatable)
* **gamma:** (ex: 4.1) total infectious period in days (transmitting (A/T/I) to recovered)
* **chi:** (ex: 1.0) treatable to infectious period in days
* **rho:** (ex: 0.39) multiplier to reduce age-specific mixing rate pattern to account for reduced rate of contact when traveling
* **nu**: (["0.01", "0.01", ..., "0.01"]) list of mortality rates per age group (units of 1/days)


There also must be at least one county with initial infected population. Provide the 
county ID (as listed in the population file), number of initial infected, and the age
group index of the infected, e.g.:
```
"initial_infected": [
    {
      "county": "1",
      "infected": "10000",
      "age_group": "1"
    }
]
```

### Optional Parameters

Any number of non-pharmaceutical interventions can be added. Following the example in
INPUT.json, interventions are assigned a name, a start day, a duration (number of days the
intervention should be applied), a location (comma separated list of county IDs, or "0" for
all counties), and a list of effectivenesses per age group. The effectiveness models the 
reduction in transmission in that age group for the duration of the intervention:

```
"non_pharma_interventions": [
  {
    "name": "School Closure",
    "day": "20",
    "duration": "10",
    "location": "113,141,201,375,453",
    "effectiveness": [
      "0.9",
      "0.9",
      "0.0",
      "0.0",
      "0.0"
    ]
  }
]
```

### Development Notes

This simulator can run stand-alone, or as the backend to a related project which provides a 
front end GUI: https://github.com/TACC/PandemicExerciseTool
