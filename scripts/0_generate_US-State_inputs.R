#///////////////////////////////////////////////////////////////////////////
#' This file orchestrates the production of all the needed files to run 
#'  US state level simulations at county level.
#' The scripts could be adapted to census-tract or ZIP Code-level analyses
#'  but exercise caution with the number of nodes in the network.
#///////////////////////////////////////////////////////////////////////////

#///////////////////////////////////////////////////////////////////////////
#' 0. Get packages used by all scripts
#' Assuming the poetry env has been set-up to run Python scripts
#' If not run `poetry install --no-root` in the parent dir
if(!require("pacman")){ # Download the preliminary library
 install.packages("pacman")
}
pacman::p_load(
  tidyverse,  # Tidy universe with packages like ggplot, dplyr, etc
  tidycensus, # Download ACS data and geometries
  tigris,     # Spatial geometry actions like moving AK and HI on map
  reticulate, # Run python code within R
  srvyr,      # Get prevalence with survey design methods
  ggpmisc,    # Adds equation to ggplot lines fit to data
  jsonlite    # Create json model input files
)
  
#/////////////////////////////////////////////////////////////////////////////
#' 1. Population data 
#' "../data/all_US_county_pop_by_age_2019-2023ACS.csv" is provided along with
#'  the code to generate it if you have an API key for tidycensus
source("1_county_age_pop_totals.R")

#////////////////////////////////////
#' 2. Age-stratified contact matrices
#' Downloaded with the epydemix package
if(!file.exists("../data/Wyoming/contact_matrix_Wyoming_Mistry2021_all.csv")){
  library(reticulate) # MallocStackLogging messages not important
  poetry_python     = system("poetry env info --path", intern = TRUE)
  poetry_python_bin = file.path(poetry_python, "bin", "python")
  use_python(poetry_python_bin, required = TRUE)
  py_run_file("2_epydemix_contact_matrix_generation.py")
} # end if contact matrices not made yet

#/////////////////////////////
#' 3. County mobility networks
#' First create the crosswalk from 2019 to 2023+ county boundaries
source("3a_ct_ak_crosswalks.R")

#' Next generate the quarterly mobility matrices per state
#'  Assumes you've cloned the gitrepo of data or have it in 
#'   "../../COVID19USFlows-DailyFlows/daily_flows/county2county"
#'  Resulting files named 2019 mobility because that is the year of data collected
#'   they have been translated to 2023+ spatial geometries with some round error
#'   of ~40-50 more people introduced per county in CT and AK only
source("3b_county_mobility_timeseries_post2020census.R")

#///////////////////////////////////////////////////////////////////////////
#' 4. Influenza high risk ratios
#' Generates the state and age stratified proportion of the pop with
#'  at least 1 high risk comorbidity  
#' This will take a bit of time (~45min M1 mac book) to run because 
#'  it's a lot of data to fit across multiple models
start_time= Sys.time()
source("4a_flu_state_high_risk_by_age.R")
end_time = Sys.time()
elapsed_time = end_time - start_time
print(as.numeric(elapsed_time, units = "mins"))

#' State and age high risk distributed to counties based on CDC PLACES 
#'  comorbid conditions available for 2024 release
#' Need to finalize file headers and how data will be taken into python code
#source("4b_flu_county_high_risk_by_age.R")

#///////////////////////////////////////////////////////////////////////////
#' 5. Flu vaccination time series
#' Based on H1N1 vaccine effectiveness, so not a one size fits all flu output
#' We use proportion of the population 100% protected from infection by vaccine
#'  to avoid fitting the correct proportion of hospitalization and infection prevention 
source("5_vaccine_coverage_by_state.R")

#///////////////////////////////////////////////////////////////////////////
#' 6. Baseline and vaccine input files + LS6 parallel commands
#' Based on the input templates we change the "STATE" to real state names
#'  and populate those with baseline (no interventions) or vaccination ts
#source("6_create_input_files_and_parallel_commands.R")









