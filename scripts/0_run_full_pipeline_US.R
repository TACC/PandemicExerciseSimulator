#////////
#### Script Overview ####
#////////
#' This file is the main RStudio-facing control script for the state pipeline.
#'
#' Typical use:
#'   1. Open the scripts/scripts.rproj so getwd() is this scripts directory.
#'   2. Edit the Section 0 Pipeline Settings below.
#'   3. Click Source in RStudio to run full pipeline.
#'   4. Open 7b and change DASHBOARD_DATA_DIR to visualize data processed by 7a
#'
#' Minimum experiment inputs:
#'   - SIM_DAY_0_ARG: one date or comma-separated dates, no spaces.
#'   - SIMULATION_DAYS: number of simulated days for each date.
#'   - PIPELINE_OUTPUT_DIR: parent folder where generated inputs/outputs live.
#'   - SELECTED_RUN_STATES: state directory names to run locally for preview.
#'   - SELECTED_RUN_SCENARIOS: which generated scenario labels to run/preview.
#'   - NONE_TEMPLATE_FILE: the no-intervention JSON shape.
#'   - INTERVENTION_TEMPLATE_FILES: named intervention JSON shapes.
#'
#' Scenario labels are not intervention mechanics. SELECTED_RUN_SCENARIOS only
#' chooses which templates are written and run. The actual intervention structure
#' comes from the JSON templates:
#'   - NPI: non_pharma_interventions rows in the NPI/all-interventions template.
#'   - ANTIVIRAL: antiviral_model parameters in the antiviral/all template.
#'   - VACCINE: vaccine_model parameters in the vaccine/all template.
#'
#' The small experiment knobs below let you override common effectiveness values
#' from RStudio without editing the template files. They only change fields that
#' already exist in a template, so generic templates without those components are
#' left alone. These values become part of the generated input JSONs; when they
#' change, the simulator hash changes and 6f will run the new combination while
#' keeping previous outputs.
#'
#' Note:
#' 1. Some parent files, such as BRFSS, are large and will take awhile to process,
#'     so plan to an hour+ to run just input generation if starting from scratch
#'     - Double check specific script headers for links to the parent files needed
#' 2. You need an API key for tidycensus, I've sourced mine from 
#'     "../data/private_input_data/api_keys.R" which contains the code
#'        CENSUS_API_KEY="YOUR_API_KEY" # the key is in quotes as it's a string
#'        tidycensus::census_api_key(CENSUS_API_KEY)
#'     This directory is ignored, so create it and the file to source
#' 3. When choosing US states, the more nodes the longer it takes, so this may 
#'     run for multiple hours if you've selected all interventions and mutliple states

#////////
#### Section 0 Package Setup ####
#////////
#' Assuming the poetry env has been set-up to run Python scripts
#' If not run `poetry install --no-root` in the parent dir
if(!require("pacman")){ # Download the preliminary library
 install.packages("pacman")
}
pacman::p_load(
  tidyverse,  # Tidy universe with packages like ggplot, dplyr, etc
  tidycensus, # Download ACS data and geometries
  tigris,     # Spatial geometry actions like moving AK and HI on map
  sf,         # Turn df's into spatial objects (sf's), drop geometry from df's
  reticulate, # Run python code within R
  srvyr,      # Get prevalence with survey design methods
  ggpmisc,    # Adds equation to ggplot lines fit to data
  jsonlite,   # Create json model input files
  haven,      # Open XPT and SAS files
  rsconnect   # Needs to push live shiny app online
  #plotly     # interactive plot option, these line commented out in code
)

#////////
#### Section 0 Pipeline Settings ####
#////////
#' Optional command-line equivalent, for example:
#' Rscript 0_run_full_pipeline_US.R --acs-year-range=2020-2024 --sim-day-0=2025-09-27,2025-10-04 --simulation-days=200 --output-dir=Example_TEST --npi-effectiveness=0.5,0.5,0.5,0.5,0.5 --antiviral-effectiveness-hosp=0.25 --pediatric-vaccine-effectiveness=0.38 --adult-vaccine-effectiveness=0.30
trailing_args <- commandArgs(trailingOnly = TRUE)
get_arg_value <- function(prefix, default) {
  match <- trailing_args[startsWith(trailing_args, prefix)]
  if (length(match) == 0) {
    return(default)
  }
  sub(prefix, "", match[[1]], fixed = TRUE)
}
get_bool_arg <- function(prefix, default) {
  value <- get_arg_value(prefix, if (default) "true" else "false")
  tolower(value) %in% c("1", "true", "yes", "y")
}
split_arg <- function(value, default) {
  if (is.null(value) || length(value) == 0 || !nzchar(value)) return(default)
  pieces <- trimws(unlist(strsplit(value, ",", fixed = TRUE)))
  pieces[nzchar(pieces)]
}
split_numeric_arg <- function(value, default) {
  pieces <- split_arg(value, as.character(default))
  numeric_pieces <- suppressWarnings(as.numeric(pieces))
  if (any(is.na(numeric_pieces))) {
    stop("Expected numeric value(s), got: ", value)
  }
  numeric_pieces
}

ACS_YEAR_RANGE    = get_arg_value("--acs-year-range=", "2020-2024")
ACS_YEAR          = as.integer(stringr::str_extract(ACS_YEAR_RANGE, "\\d{4}$"))
# comma-separated dates, no spaces e.g. "2025-09-27,2025-10-04"
SIM_DAY_0_ARG <- get_arg_value("--sim-day-0=", "2025-10-04") # "2025-09-27,2025-10-04"
SIM_DAY_0_VALUES <- as.Date(split_arg(SIM_DAY_0_ARG, character())) 
if (any(is.na(SIM_DAY_0_VALUES))) {
  stop("Invalid --sim-day-0 value. Use one date or comma-separated dates like 2025-09-27,2025-10-04.")
}
SIM_DAY_0         = SIM_DAY_0_VALUES[[1]]
SIM_DAY_0_LABEL   = as.character(SIM_DAY_0)
SIMULATION_DAYS   = as.integer(get_arg_value("--simulation-days=", "200"))
PIPELINE_OUTPUT_DIR = get_arg_value("--output-dir=", "STATE_WKLYFIT_TEST")
INPUT_TEMPLATE_DIR = get_arg_value("--input-template-dir=", "../data/INPUT_FILE_TEMPLATES")
NONE_TEMPLATE_FILE = get_arg_value(
  "--none-template=",
  file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_NONE_H3N2.json")
)
INTERVENTION_TEMPLATE_FILES = c(
  VACCINE = get_arg_value("--vaccine-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_VAX_H3N2.json")),
  ANTIVIRAL = get_arg_value("--antiviral-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_ANTIVIRAL_H3N2.json")),
  NPI = get_arg_value("--npi-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_NPI_H3N2.json")),
  ALL_INTERVENTIONS = get_arg_value("--all-interventions-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_ALL_INTERVENTIONS_H3N2.json"))
)
# NPI effectiveness is per model age group, in order:
#   0-4, 5-17, 18-49, 50-64, 65+
# For the default weekend NPI, 0.5 means 50% lower transmission/contact effect
# for that age group during the NPI row's active days.
NPI_EFFECTIVENESS_BY_AGE = split_numeric_arg(
  get_arg_value("--npi-effectiveness=", "0.5,0.5,0.5,0.5,0.5"),
  c(0.5, 0.5, 0.5, 0.5, 0.5)
)
ANTIVIRAL_EFFECTIVENESS_HOSP = as.numeric(get_arg_value("--antiviral-effectiveness-hosp=", "0.25"))
PEDIATRIC_VACCINE_EFFECTIVENESS = as.numeric(get_arg_value("--pediatric-vaccine-effectiveness=", "0.38"))
ADULT_VACCINE_EFFECTIVENESS = as.numeric(get_arg_value("--adult-vaccine-effectiveness=", "0.30"))
if (
  any(NPI_EFFECTIVENESS_BY_AGE < 0 | NPI_EFFECTIVENESS_BY_AGE > 1) ||
  ANTIVIRAL_EFFECTIVENESS_HOSP < 0 || ANTIVIRAL_EFFECTIVENESS_HOSP > 1 ||
  PEDIATRIC_VACCINE_EFFECTIVENESS < 0 || PEDIATRIC_VACCINE_EFFECTIVENESS > 1 ||
  ADULT_VACCINE_EFFECTIVENESS < 0 || ADULT_VACCINE_EFFECTIVENESS > 1
) {
  stop("Effectiveness values must be between 0 and 1.")
}
EPYDEMIX_NSIM = as.integer(get_arg_value("--epydemix-nsim=", "1000"))
RUN_WEB_PREVIEW = get_bool_arg("--run-web-preview=", TRUE)
SELECTED_RUN_STATES = split_arg(
  get_arg_value("--selected-states=", ""),
  c("District-of-Columbia", # Only 1 "county" b/c it's a single territory 
    "Connecticut",   #  8 counties
    # "Massachusetts", # 14
    # "Maine",         # 16
    "New-Jersey"#  ,    # 21
 #    "Oregon",        # 36
 #    "New-York"       # 62
))
SELECTED_RUN_SCENARIOS = split_arg(
  get_arg_value("--selected-scenarios=", ""),
  c("NONE", names(INTERVENTION_TEMPLATE_FILES))
)
WEB_PREVIEW_STATES = SELECTED_RUN_STATES
DEPLOY_SHINYAPPS = get_bool_arg("--deploy-shinyapps=", FALSE)
SHINYAPPS_ACCOUNT = get_arg_value("--shinyapps-account=", "")
SHINYAPPS_APP_NAME = get_arg_value("--shinyapps-app-name=", "PandemicSimExplorer")
MOBILITY_YR = 2025 # Advan for 2025 and SafeGraph for 2019

repo_root <- normalizePath("..", mustWork = TRUE)
pipeline_output_root <- normalizePath(
  file.path(repo_root, PIPELINE_OUTPUT_DIR),
  mustWork = FALSE
)
dir.create(pipeline_output_root, showWarnings = FALSE, recursive = TRUE)
pipeline_started_at <- format(Sys.time(), "%Y%m%d_%H%M%S")
pipeline_log_file <- file.path(
  pipeline_output_root,
  paste0("pipeline_0_run_full_pipeline_US_", pipeline_started_at, ".log")
)

stdout_log_con <- file(pipeline_log_file, open = "at")
sink(stdout_log_con, split = TRUE)
globalCallingHandlers(
  message = function(condition) {
    cat(conditionMessage(condition), "\n", file = pipeline_log_file, append = TRUE, sep = "")
  },
  warning = function(condition) {
    cat("Warning: ", conditionMessage(condition), "\n", file = pipeline_log_file, append = TRUE, sep = "")
  },
  error = function(condition) {
    cat("Error: ", conditionMessage(condition), "\n", file = pipeline_log_file, append = TRUE, sep = "")
  }
)
on.exit({
  while (sink.number() > 0) sink()
  close(stdout_log_con)
}, add = TRUE)

section_banner <- function(section_label) {
  cat(
    "\n\n",
    "#////////\n",
    "#### ", section_label, " ####\n",
    "#////////\n\n",
    sep = ""
  )
}

run_logged_command <- function(command, args = character(), workdir = NULL) {
  command_line <- paste(c(shQuote(command), shQuote(args)), collapse = " ")
  if (!is.null(workdir)) {
    command_line <- paste("cd", shQuote(workdir), "&&", command_line)
  }
  cat("Running shell command:\n  ", command_line, "\n", sep = "")
  shell_line <- paste(
    command_line,
    "2>&1 | sed -E 's/(CENSUS_API_KEY=)[^[:space:]]+/\\1<redacted>/g' | tee -a",
    shQuote(pipeline_log_file),
    "; exit ${PIPESTATUS[0]}"
  )
  system(paste("bash -lc", shQuote(shell_line)))
}

json_sim_day_0_matches <- function(path, expected_sim_day_0) {
  config <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
  sim_day_0 <- tryCatch(config$metadata_tags$sim_day_0, error = function(e) NA_character_)
  if (is.null(sim_day_0)) sim_day_0 <- NA_character_
  identical(
    as.character(sim_day_0),
    as.character(expected_sim_day_0)
  )
}

calibrated_sim_day_0_matches <- function(path, expected_sim_day_0) {
  config <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
  sim_day_0 <- tryCatch(config$metadata_tags$sim_day_0, error = function(e) NA_character_)
  if (is.null(sim_day_0)) sim_day_0 <- NA_character_
  epydemix_sim_start <- tryCatch(config$metadata_tags$epydemix_fit$simulation_start_date, error = function(e) NA_character_)
  if (is.null(epydemix_sim_start)) epydemix_sim_start <- NA_character_
  expected_sim_day_0 <- as.character(expected_sim_day_0)
  identical(as.character(sim_day_0), expected_sim_day_0) ||
    identical(as.character(epydemix_sim_start), expected_sim_day_0)
}

section_banner("Section 0 Pipeline Settings")
cat("Pipeline log file: ", pipeline_log_file, "\n", sep = "")
cat("Pipeline settings:\n")
cat("  ACS_YEAR_RANGE = ", ACS_YEAR_RANGE, "\n", sep = "")
cat("  ACS_YEAR = ", ACS_YEAR, "\n", sep = "")
cat("  SIM_DAY_0 = ", paste(as.character(SIM_DAY_0_VALUES), collapse = ", "), "\n", sep = "")
cat("  SIMULATION_DAYS = ", SIMULATION_DAYS, "\n", sep = "")
cat("  PIPELINE_OUTPUT_DIR = ", PIPELINE_OUTPUT_DIR, "\n", sep = "")
cat("  NONE_TEMPLATE_FILE = ", NONE_TEMPLATE_FILE, "\n", sep = "")
cat("  INTERVENTION_TEMPLATE_FILES = ", paste(names(INTERVENTION_TEMPLATE_FILES), INTERVENTION_TEMPLATE_FILES, sep = ":", collapse = ", "), "\n", sep = "")
cat("  NPI_EFFECTIVENESS_BY_AGE = ", paste(NPI_EFFECTIVENESS_BY_AGE, collapse = ", "), "\n", sep = "")
cat("  ANTIVIRAL_EFFECTIVENESS_HOSP = ", ANTIVIRAL_EFFECTIVENESS_HOSP, "\n", sep = "")
cat("  PEDIATRIC_VACCINE_EFFECTIVENESS = ", PEDIATRIC_VACCINE_EFFECTIVENESS, "\n", sep = "")
cat("  ADULT_VACCINE_EFFECTIVENESS = ", ADULT_VACCINE_EFFECTIVENESS, "\n", sep = "")
cat("  EPYDEMIX_NSIM = ", EPYDEMIX_NSIM, "\n", sep = "")
cat("  RUN_WEB_PREVIEW = ", RUN_WEB_PREVIEW, "\n", sep = "")
cat("  SELECTED_RUN_STATES = ", paste(SELECTED_RUN_STATES, collapse = ", "), "\n", sep = "")
cat("  SELECTED_RUN_SCENARIOS = ", paste(SELECTED_RUN_SCENARIOS, collapse = ", "), "\n", sep = "")
cat("  DEPLOY_SHINYAPPS = ", DEPLOY_SHINYAPPS, "\n", sep = "")
cat("  SHINYAPPS_ACCOUNT = ", ifelse(nzchar(SHINYAPPS_ACCOUNT), SHINYAPPS_ACCOUNT, "<not set>"), "\n", sep = "")
cat("  SHINYAPPS_APP_NAME = ", SHINYAPPS_APP_NAME, "\n", sep = "")

#////////
#### Section 0b Ensuring Poetry Dependencies ####
#////////
section_banner("Section 0b Ensuring Poetry Dependencies")
poetry_install_args <- c("install", "--no-root")
cat("Ensuring Poetry dependencies are installed:\n")
cat("  poetry ", paste(shQuote(poetry_install_args), collapse = " "), "\n", sep = "")
poetry_install_status <- run_logged_command("poetry", poetry_install_args, workdir = repo_root)
if (!identical(poetry_install_status, 0L)) {
  stop("Poetry dependency installation failed with exit status ", poetry_install_status)
}
  
#////////
#### Section 1 Population Data ####
#////////
#' "../data/all_US_county_pop_by_age_2020-2024ACS.csv" is provided along with
#'  the code to generate it if you have an API key for tidycensus
section_banner("Section 1 Running Population Data")
source("1_county_age_pop_totals.R")

#////////
#### Section 2 Contact Matrices ####
#////////
#' Downloaded with the epydemix package
section_banner("Section 2 Running Contact Matrices")
contact_matrix_files <- list.files(
  "../data",
  pattern = "^contact_matrix_.*_Mistry2021_all\\.csv$",
  recursive = TRUE,
  full.names = TRUE
)
if (length(contact_matrix_files) >= 51) {
  cat("Contact matrices already exist for ", length(contact_matrix_files), " state/DC directories.\n", sep = "")
} else {
  cat("Only found ", length(contact_matrix_files), " contact matrices; generating missing contact matrices.\n", sep = "")
  library(reticulate)
  poetry_python     = system("poetry env info --path", intern = TRUE)
  poetry_python_bin = file.path(poetry_python, "bin", "python")
  use_python(poetry_python_bin, required = TRUE)
  py_run_file("2_epydemix_contact_matrix_generation.py")
} # end if contact matrices not made yet

#////////
#### Section 3 County Mobility Networks ####
#////////
#' First create the crosswalk from 2019 to 2023+ county boundaries
section_banner("Section 3 Running County Mobility Networks")
source("3a_ct_ak_crosswalks.R")

#' Next generate the quarterly mobility matrices per state if not state dirs
#'  Both 2019 and 2025 matrices per quarter have been generated at county-level within each US state and DC
#' 
#' To Use Public Safegraph 2019 data
#'  Assumes you've cloned the gitrepo of data or have it in 
#'   "../../COVID19USFlows-DailyFlows/daily_flows/county2county"
#'  Resulting files named 2019 mobility because that is the year of data collected
#'   they have been translated to 2023+ spatial geometries with some round error
#'   of ~40-50 more people introduced per county in CT and AK only
#'  First time running pipeline will take ~2sec per day to clean
#'  
#' To Use Advan data with UT Login
#'  Assumes you've gone to https://app.deweydata.io/ logged in with SSO
#'  to download
#'   "../../neighborhood-patterns-us-home-panel-summary/"
#'   "../../YYYY-us-dc-mobility-data-csv/"
#'  This is a large amount of data and process on TACC, not locally

if(MOBILITY_YR == "2025"){
  # Uses ACS year defined above as 2020-2024 was most recent mid-2026
  source("3c_advan_county_mobility.R")
}else if(MOBILITY_YR == "2019"){
  # Uses 2019-2023 ACS to be closer to 2019 population but with new AK+CT counties
  source("3b_county_mobility_timeseries_post2020census.R")
}

#////////
#### Section 4 Influenza High Risk Ratios ####
#////////
#' Generates the state and age stratified proportion of the pop with
#'  at least 1 high risk comorbidity  
#' This will take a bit of time (~45min M1 MacBook Pro) to run because 
#'  it's a lot of data to fit across multiple models
section_banner("Section 4 Running Influenza High Risk Ratios")
if(!file.exists("../data/Wyoming/state_Wyoming_high-risk-ratios-flu-only.csv")){
  start_time= Sys.time()
  source("4a_flu_state_high_risk_by_age.R")
  end_time = Sys.time()
  elapsed_time = end_time - start_time
  print(as.numeric(elapsed_time, units = "mins"))
}else{
  print("State-level high risk ratios already exist")
} # end if need to make state-level BRFSS/NSCH data


#' State and age high risk distributed to counties based on CDC PLACES 
#'  comorbid conditions available for 2024 release
#' Need to finalize file headers and how data will be taken into python code
county_high_risk_detail_file <- "../data/RISK_RATIOS/all_US_county_high-risk-ratios-detailed.csv"
state_county_high_risk_files <- list.files(
  "../data",
  pattern = "^county_.*_high-risk-ratios-flu-only\\.csv$",
  recursive = TRUE,
  full.names = TRUE
)
if (file.exists(county_high_risk_detail_file) && length(state_county_high_risk_files) >= 51) {
  print("County-level high risk ratios already exist")
} else {
  source("4b_flu_county_high_risk_by_age.R")
}

for (SIM_DAY_0 in SIM_DAY_0_VALUES) {
  SIM_DAY_0 <- as.Date(SIM_DAY_0)
  SIM_DAY_0_LABEL <- as.character(SIM_DAY_0)
  section_banner(paste0("Running Date-Dependent Pipeline For ", SIM_DAY_0_LABEL))

#////////
#### Section 5a Seed None Inputs ####
#////////
section_banner("Section 5a Running Seed None Inputs")
seed_input_dir <- file.path(pipeline_output_root, "SEED_INPUT_JSONS", SIM_DAY_0_LABEL)
validation_fit_data_dir <- file.path(pipeline_output_root, "validation_fit_data")
derived_initial_exposed_dir <- file.path(pipeline_output_root, "DERIVED_INITIAL_EXPOSED")
state_initial_exposed_file <- file.path(
  derived_initial_exposed_dir,
  paste0("derived_initial_exposed_state_age_", SIM_DAY_0_LABEL, ".csv")
)
county_initial_exposed_file <- file.path(
  derived_initial_exposed_dir,
  paste0("derived_initial_exposed_county_age_", SIM_DAY_0_LABEL, ".csv")
)
seed_input_files <- list.files(
  seed_input_dir,
  pattern = "^INPUT_SEIHRD-STOCH_.*_SEED_NONE\\.json$",
  full.names = TRUE
)
validation_fit_files <- list.files(
  validation_fit_data_dir,
  pattern = paste0("^validation_fit_inc_hosp_.*_", SIM_DAY_0_LABEL, "\\.csv$"),
  full.names = TRUE
)
seed_inputs_match_sim_day_0 <- length(seed_input_files) >= 51 &&
  all(vapply(seed_input_files, json_sim_day_0_matches, logical(1), expected_sim_day_0 = SIM_DAY_0_LABEL))

if (
  file.exists(state_initial_exposed_file) &&
  file.exists(county_initial_exposed_file) &&
  length(seed_input_files) >= 51 &&
  length(validation_fit_files) >= 51 &&
  seed_inputs_match_sim_day_0
) {
  cat(
    "Seed no-intervention inputs already exist for sim_day_0 ",
    SIM_DAY_0_LABEL,
    ": ",
    length(seed_input_files),
    " seed JSONs and ",
    length(validation_fit_files),
    " validation fit files.\n",
    sep = ""
  )
} else {
  cat("Seed no-intervention inputs missing or not all for sim_day_0 ", SIM_DAY_0_LABEL, "; running 5a.\n", sep = "")
  source("5a_derive_initial_exposures.R")
}

#////////
#### Section 5b Epydemix Fits ####
#////////
section_banner("Section 5b Running Epydemix Fits")
epydemix_input_dir <- normalizePath(
  file.path(repo_root, PIPELINE_OUTPUT_DIR, "SEED_INPUT_JSONS", SIM_DAY_0_LABEL),
  mustWork = FALSE
)
epydemix_output_dir <- normalizePath(
  file.path(repo_root, PIPELINE_OUTPUT_DIR, "epydemix_fit", SIM_DAY_0_LABEL),
  mustWork = FALSE
)
dir.create(epydemix_output_dir, showWarnings = FALSE, recursive = TRUE)
epydemix_seed_files <- list.files(
  epydemix_input_dir,
  pattern = "^INPUT_SEIHRD-STOCH_.*_SEED_NONE\\.json$",
  full.names = TRUE
)
expected_calibrated_jsons <- file.path(
  epydemix_output_dir,
  tools::file_path_sans_ext(basename(epydemix_seed_files)),
  paste0(tools::file_path_sans_ext(basename(epydemix_seed_files)), "_EPYDEMIX_R0_ONLY.json")
)
calibrated_jsons_match_sim_day_0 <- length(expected_calibrated_jsons) >= 51 &&
  all(file.exists(expected_calibrated_jsons)) &&
  all(vapply(
    expected_calibrated_jsons,
    calibrated_sim_day_0_matches,
    logical(1),
    expected_sim_day_0 = SIM_DAY_0_LABEL
  ))

if (length(epydemix_seed_files) >= 51 && calibrated_jsons_match_sim_day_0) {
  cat(
    "Epydemix calibrated JSONs already exist for sim_day_0 ",
    SIM_DAY_0_LABEL,
    ": ",
    length(expected_calibrated_jsons),
    " state/DC fits.\n",
    sep = ""
  )
} else {
  cat("Epydemix calibrated JSONs missing or not all for sim_day_0 ", SIM_DAY_0_LABEL, "; running 5b.\n", sep = "")
  epydemix_args <- c(
    "run",
    "python3",
    file.path(repo_root, "scripts", "5b_epydemix_fit_seihrd_hospitalizations.py"),
    "--all-states",
    "--input-json-dir",
    epydemix_input_dir,
    "--output-dir",
    epydemix_output_dir,
    "--nsim",
    as.character(EPYDEMIX_NSIM),
    "--write-calibrated-json"
  )
  cat("Epydemix command:\n")
  cat("  poetry ", paste(shQuote(epydemix_args), collapse = " "), "\n", sep = "")
  epydemix_status <- run_logged_command("poetry", epydemix_args, workdir = repo_root)
  if (!identical(epydemix_status, 0L)) {
    stop("Epydemix fitting failed with exit status ", epydemix_status)
  }
}

#////////
#### Section 6 Intervention Inputs ####
#////////
#' Build vaccine stockpiles and NPI schedules only after calibrated no-intervention inputs exist.
section_banner("Section 6 Running Intervention Inputs")
source("6a_vaccine_coverage_by_state.R")
source("6b_outpatient_antiviral_coverage_by_state.R")
source("6c_weekend_npi_schedule.R")
source("6d_create_intervention_inputs.R")

}

#////////
#### Section 6e Parallel Command Generation ####
#////////
section_banner("Section 6e Running Parallel Command Generation")
source("6e_create_parallel_commands.R")

#////////
#### Section 6f Selected Local Scenarios ####
#////////
if (RUN_WEB_PREVIEW) {
  section_banner("Section 6f Running Selected Local Scenarios")
  source("6f_run_selected_scenarios.R")
}

#////////
#### Section 7-8 Output ETL And Dashboard Bundle ####
#////////
if (RUN_WEB_PREVIEW) {
  section_banner("Section 7-8 Running Output ETL And Dashboard Bundle")
  source("7a_process_output_to_db.R")
  source("8_prepare_shinyapps_bundle.R")
  
#////////
#### Section 8b shinyapps.io Deployment ####
#////////
  if (DEPLOY_SHINYAPPS) {
    section_banner("Section 8b Deploying shinyapps.io Bundle")
    if (!requireNamespace("rsconnect", quietly = TRUE)) {
      stop("Package rsconnect is required for shinyapps.io deployment. Install it with install.packages('rsconnect').")
    }
    if (!nzchar(SHINYAPPS_ACCOUNT)) {
      stop("Set --shinyapps-account=<account-name> when --deploy-shinyapps=true.")
    }
    
    shinyapps_bundle_dir <- normalizePath(
      file.path(repo_root, "deploy", "shinyapps", "PandemicSimExplorer"),
      mustWork = TRUE
    )
    message("Deploying shinyapps.io bundle:")
    message("  appDir = ", shinyapps_bundle_dir)
    message("  account = ", SHINYAPPS_ACCOUNT)
    message("  appName = ", SHINYAPPS_APP_NAME)
    rsconnect::deployApp(
      appDir = shinyapps_bundle_dir,
      appName = SHINYAPPS_APP_NAME,
      account = SHINYAPPS_ACCOUNT
    )
  } else {
    message("Prepared shinyapps.io bundle but did not deploy.")
    message("To deploy later, run:")
    message(
      "  rsconnect::deployApp(appDir = 'deploy/shinyapps/PandemicSimExplorer', ",
      "appName = '", SHINYAPPS_APP_NAME, "', account = '<your-shinyapps-account>')"
    )
  }
}
