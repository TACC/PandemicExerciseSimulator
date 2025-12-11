# PES Scripts

R is easiest to work with in Rstudio. Opening the .Rproj opens an Rstudio instance with this dir set at the working directory and let's you run each script by either `source` or line by line. Good if you're generating data needed to run simulations or exploring with interactive visualizations (e.g. with `ggplotly`).

## Generating input data
To run US state-specific data generation pipeline open `0_generate_US-State_inputs.R` in the `scripts.Rproj`. Code sets are ordered 1-6 with some moderate dependencies between them, such as creating initial dirs and county population data. 

## Notes on inputs created
The term "high risk" means this subset of the population has an increased risk of hospitalization and death when infected with influenza. Therefore is best used with the SEIHRD compartmental model that has hospitalization (H) and death (D) compartments to capture this increase. Therefore, the templates used in step 6 are based on SEIHRD model. SEIR or SEIRS templates could easily be swapped out as vaccination is assumed to be 100% effective against infection for a fraction of the vaccinated population. Risk ratios are, however, required for all models and can impact intervention strategies, such as vaccination only available for 65+ and high risk population.
