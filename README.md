## Pandemic Exercise Simulator

This is a stand-alone Python command line implementation of an outbreak
simulator using your choice of stochastic or deterministic compartmental model with a binomial travel model.

### Install Using Poetry:

Depends on [Poetry](https://python-poetry.org/docs/#installation) for native installation.
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
$ poetry run python3 src/simulator.py -l INFO -d 10 -i data/Texas/INPUT_SEIHRD-STOCH_Texas_R0-2.2_BASELINE.json
```
Each state has at least a baseline and vaccination template based on the 2024-25 influenza vaccination coverage
time series and effectiveness. Details on this can be found in `scripts/5_vaccine_coverage_by_state.R`. We generated
additional input files for Alabama as an example based on the templates available in `data/INPUT_FILE_TEMPLATES`.

### Test:

```
$ poetry run pytest
```

### Run Using Docker (Preferred):

As an alternative to Poetry, you can instead run a containerized version of the
simulator with [Docker](https://docs.docker.com/engine/install/).

```
$ docker build -t pes:0.1.0 .
$ docker run --rm pes:0.1.0 python3 src/simulator.py --help
$ docker run --rm pes:0.1.0 python3 src/simulator.py -l INFO -d 10 -i data/Texas/INPUT_SEIHRD-STOCH_Texas_R0-2.2_BASELINE.json
```

### Input Data Required:

The simulator requires the data from the following folder:
```
.
└── data
    └── State
        ├── INPUT_*.json
        ├── contact_matrix_State_Mistry2021_all.csv
        ├── county_pop_by_age_State_2019-2023ACS.csv
        ├── state_State_high-risk-ratios-flu-only.csv or county_State_high-risk-ratios-flu-only.csv
        ├── State_Q*-2019_mobility-matrix.csv for quarters 1-4
        ├── State_quarterly-2019_mobility.csv
        └── State_quarterly-2019_county-connection-ranking.csv
```

* **INPUT_\*.json:** Simulation properties file
* **contact_matrix_State_Mistry2021_all.csv:** Age x Age matrix of daily contacts between age groups taken from Epydemix python package (see `scripts/`). 
  * Top to bottom must match the left to right order of age groups in population file.
* **county_pop_by_age_State_2019-2023ACS.csv:** Populations for each county divided into age groups
* **\*_State_high-risk-ratios-flu-only.csv:** state or county specific high risk ratios for proportion of population at increased risk of severe outcome (hospitalization/death).
* **State_Q\*-2019_mobility-matrix.csv:** County x County mobility matrix of the fraction of the population that visits the other counties per day. 
  * Must be ordered to match fips order of population file, i.e. sequential FIPS codes of counties.
* **State_quarterly-2019_mobility.csv** Non-matrix form of mobility data with column labels, file the matrices are derived from.
* **State_quarterly-2019_county-connection-ranking.csv:** Ranking of connectivity of counties by quarter to help you decide on where to initialize infections.


### Parameters Required:

Examples of required parameter inputs per model are available in `data/INPUT_FILE_TEMPLATES`

There also must be at least one county with one initial infected person. Provide the
county FIPS (as listed in the population file), number of initial infected, and the age
group index of the infected. All people will be initialized in the low severity risk group of Exposed compartment. 
If you initialize more than the people available the model will only infect susceptibles available after vaccinations are distributed.
```
"initial_infected": [
    {
      "county": "1",
      "infected": "100",
      "age_group": "1"
    }
]
```

### Optional Parameters

**NPIs:** Any number of non-pharmaceutical interventions can be added. 
Interventions are assigned a name, a start day, a duration (number of days the
intervention should be applied), a location (comma separated list of county FIPS, or "0" for
all counties), and a list of effectivenesses per age group. The effectiveness models the
reduction in transmission (beta) in that age group for the duration of the intervention:

```
"non_pharma_interventions": [
  {
    "name": "School Closure",
    "day": "20",
    "duration": "10",
    "location": "48113,48141,48201,48375,48453",
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
**Vaccination:** Vaccines currently release from a stockpile and take `vaccine_eff_lag_days` before
becoming effective. `age_risk_priority_groups` of 0 means no one in this age group receives the vaccine
even if it is available, 0.5 mean only high risk, and 1 is everyone. The vaccines in the stockpile can 
deteriorate as well with `vaccine_half_life_days`. Currently, people move completely into the vaccinated subgroup
and do not leave for the rest of the simulation. `vaccine_capacity_proportion` is what fraction of the population
can the area vaccinate per day, i.e. with 1M people and 1M doses can you only vaccinate 100K per day, then it's 10% or 0.1.
`vaccine_adherence` is age stratified to estimate the proportion of that age group who would seek a vaccine if available. 
We plan to make this county-specific as well in future updates. `vaccine_effectiveness` is the effectiveness against infection once
someone has moved into the vaccinated subgroup. Setting to 1 means its completely effective and appropriate if you're assuming
a fraction of those vaccinated from coverage data receive full effectiveness and the rest do not. 
`vaccine_effectiveness_hosp` is the effectiveness against hospitalization and only available in the SEIHRD model if the vaccination
against infection is less than one (<1). Stockpile release days can be negative to account for doses given sufficiently before an 
epidemic begins, e.g. normal influenza season vaccination schedule people may get dose in early September but epidemic starts in mid-October.
To shift a long time series you can simply alter the `vaccine_eff_lag_days`.

```
"vaccine_model": {
    "identity": "stockpile-age-risk",
    "parameters": {
      "age_risk_priority_groups": ["0","0.5","0.5","1","1"],
      "vaccine_half_life_days": null,
      "vaccine_capacity_proportion": "1.0",
      "vaccine_adherence": ["1","1","1","1","1"],
      "vaccine_effectiveness": ["1","1","1","1","1"],
      "vaccine_eff_lag_days": 14,
      "vaccine_stockpile": [
        {
          "day": "-14",
          "amount": "10000"
        },
        {
          "day": "0",
          "amount": "100"
        },
      ]
    }
```



### Development Notes
This simulator can run stand-alone, or as the backend to a related project which provides a
front end GUI: https://github.com/TACC/PandemicExerciseTool
