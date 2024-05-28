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
        ├── relative_susceptibility.5
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

The input properties file, e.g.
`3D_Fast_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.json`,
should be generated by the user or by the GUI. Here are some notes on each
part of that file and the input data:


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

* Params (chi=1.0): Chi was originally hardcoded in `ModelParameters.cpp`, took this out and made
  it a param.

* Params (vaccine_wastage_factor=60): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. "Every N days half the stock pile is wasted"

* Params (antiviral_wastage_factor=60): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. "Every N days half the stock pile is wasted"

* Params (antiviral_effectievness=0.8): was orginally hardcoded in `ModelParameters.cpp`, took this
  out and made it a param. 

* Params (nu): This is still hard coded, not sure what to do with this:
```
    // This is the lower death rate.  Ideally, these numbers will just be in the config file.
    if ( lowDeathRate ) {
        nu ( 0, 0 ) = 2.23193e-05;
        nu ( 1, 0 ) = 4.09747056486e-05;
        nu ( 2, 0 ) = 8.37293183202e-05;
        nu ( 3, 0 ) = 6.18089564208e-05;
        nu ( 4, 0 ) = 8.97814893927e-06;

        nu ( 0, 1 ) = 0.000201089;
        nu ( 1, 1 ) = 0.000370019305934;
        nu ( 2, 1 ) = 0.000756613214362;
        nu ( 3, 1 ) = 0.000557948045036;
        nu ( 4, 1 ) = 8.08383088526e-05;
    } else {
        nu ( 0, 0 ) = 0.00201371;
        nu ( 1, 0 ) = 0.000766898700611;
        nu ( 2, 0 ) = 0.00131294401009;
        nu ( 3, 0 ) = 0.000481092688113;
        nu ( 4, 0 ) = 0.000127992694545;

        nu ( 0, 1 ) = 0.0200626;
        nu ( 1, 1 ) = 0.00724895553818;
        nu ( 2, 1 ) = 0.0127322284368;
        nu ( 3, 1 ) = 0.00443918094028;
        nu ( 4, 1 ) = 0.00116150251502;
    }
}
```


