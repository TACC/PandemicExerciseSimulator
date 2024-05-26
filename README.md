## PandemicExerciseSimulator

This is a Python command line implementation of a pandemic exercise simulator
using a SEATIRD compartment model.

#### Install:

```
$ git clone https://github.com/TACC/PandemicExerciseSimulator
$ pip install .
```

#### Test:

```
$ make run
$ make debug
$ pytest
```

#### Data:

Requires data in the following folder:
```
.
└── data
    └── texas
        ├── 3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json
        ├── contact_matrix.5
        ├── county_age_matrix.5
        ├── high_risk_ratios.5
        ├── vaccine_adherence.5
        ├── vaccine_effectiveness.5
        └── work_matrix_rel.csv
```

* **3D...json:** Simulation properties file (see schema)
* **contact_matrix.5:** 5x5 matrix of contact ratios between age groups
* **county_age_matrix.5:** Populations for each county divided into age groups
* **high_risk_ratios.5:** List of risk ratio for each age group
* **vaccine_adherence.5:** List of vaccine adherences for each age group
* **vaccine_effectiveness.5:** List of vaccine effectiveness for each age group
* **work_matrix_rel.csv:** NxN matrix (N=num of counties) for travel flow



## Description


