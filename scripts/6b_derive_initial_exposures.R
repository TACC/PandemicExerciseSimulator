#//////////////////////////////////////////////////////////////////////////////////////
#' Derive Delaware county-age initial low-risk exposures from age-stratified
#' incident influenza hospitalization data.
#' 
#' Taken from: https://github.com/midas-network/flu-scenario-modeling-hub/blob/main/auxiliary-data/target-data_archive/time-series_2026-07-13.csv
#'
#' The PES JSON field is named initial_exposed, but the simulator currently moves
#' these people from S to E in the low-risk, unvaccinated subgroup. This script
#' therefore estimates low-risk-equivalent initial exposed people by county and age.
#'
#' Default target:
#'   - simulation start: 2025-08-09
#'   - observed weekly incident hospitalizations: Delaware_AgeIncHospFlu_2025-26.csv
#'   - calibration signal: first LOOKAHEAD_WEEKS from simulation start
#'
#' Outputs:
#'   - data/Delaware/derived_initial_exposed_Delaware_2025-08-09.csv
#'   - data/Delaware/derived_initial_exposed_Delaware_2025-08-09.json
#'   - data/Delaware/derived_initial_exposed_Delaware_2025-08-09_method.csv
#'   - data/Delaware_TEST/INPUT_SEIHRD-STOCH_Delaware_TEST_R0-2.2_BASELINE.json
#//////////////////////////////////////////////////////////////////////////////////////

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(lubridate)
  library(jsonlite)
})

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || is.na(x)) y else x
}

#//////////////////////
#### USER SETTINGS ####

STATE_NAME <- "Delaware"
TEST_STATE_DIR <- "Delaware_TEST"
SIM_START_DATE <- as.Date("2025-08-09")
LOOKAHEAD_WEEKS <- 8

# County allocation weights:
#   low_risk_population^POPULATION_POWER *
#   normalized_mobility_outflow^MOBILITY_POWER
#
# MOBILITY_POWER = 0 uses only county-age low-risk population. A small nonzero
# value gives mild preference to counties with greater outbound connectivity.
POPULATION_POWER <- 1.0
MOBILITY_POWER <- 0.25

# PES SEIHRD baseline parameters from INPUT_SEIHRD-STOCH_Delaware_R0-2.2_BASELINE.json.
PROP_E_TO_IA <- c("0-4" = 0.25, "5-17" = 0.25, "18-49" = 0.30, "50-64" = 0.30, "65+" = 0.30)
PROP_IS_TO_H_LOWRISK <- c("0-4" = 0.0132, "5-17" = 0.0099, "18-49" = 0.0295, "50-64" = 0.0594, "65+" = 0.0802)

# Floor options prevent zero exposures when the first few weeks are all zero.
# Set MIN_STATE_EXPOSED_PER_ACTIVE_AGE <- 0 for a strict observation-only estimate.
MIN_STATE_EXPOSED_PER_ACTIVE_AGE <- 1

#////////////////////
#### PATH SETUP ####

cmd_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd_args, value = TRUE)
script_path <- if (length(file_arg) > 0) sub("^--file=", "", file_arg[[1]]) else ""
script_dir <- if (nzchar(script_path)) dirname(normalizePath(script_path, mustWork = FALSE)) else getwd()
if (dir.exists(file.path(script_dir, "data"))) {
  repo_root <- normalizePath(script_dir, mustWork = TRUE)
} else if (dir.exists(file.path(script_dir, "..", "data"))) {
  repo_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
} else {
  stop("Could not find repository root from working directory or script location.")
}

input_hosp_file <- file.path(repo_root, "data", "Flu-Hub-Data", "Delaware_AgeIncHospFlu_2025-26.csv")
population_file <- file.path(repo_root, "data", STATE_NAME, "county_pop_by_age_Delaware_2019-2023ACS.csv")
risk_file <- file.path(repo_root, "data", STATE_NAME, "county_Delaware_high-risk-ratios-flu-only.csv")
mobility_rank_file <- file.path(repo_root, "data", STATE_NAME, "Delaware_quarterly-2019_county-connection-ranking.csv")
baseline_template_file <- file.path(repo_root, "data", STATE_NAME, "INPUT_SEIHRD-STOCH_Delaware_R0-2.2_BASELINE.json")
test_output_dir <- file.path(repo_root, "data", TEST_STATE_DIR)
test_input_file <- file.path(test_output_dir, "INPUT_SEIHRD-STOCH_Delaware_TEST_R0-2.2_BASELINE.json")

output_stub <- file.path(
  repo_root,
  "data",
  STATE_NAME,
  paste0("derived_initial_exposed_Delaware_", SIM_START_DATE)
)

age_order <- c("0-4", "5-17", "18-49", "50-64", "65+")
age_index <- setNames(seq_along(age_order) - 1L, age_order)

largest_remainder_round <- function(values, target_total) {
  if (target_total <= 0 || sum(values) <= 0) {
    return(rep(0L, length(values)))
  }
  scaled <- values / sum(values) * target_total
  floored <- floor(scaled)
  remainder <- target_total - sum(floored)
  if (remainder > 0) {
    bump_idx <- order(scaled - floored, decreasing = TRUE)[seq_len(remainder)]
    floored[bump_idx] <- floored[bump_idx] + 1
  }
  as.integer(floored)
}

read_age_wide_csv <- function(path) {
  read_csv(path, show_col_types = FALSE, col_types = cols(.default = col_character())) |>
    dplyr::rename(fips = 1) |>
    dplyr::mutate(fips = str_pad(as.character(fips), width = 5, pad = "0")) |>
    tidyr::pivot_longer(
      cols = all_of(age_order),
      names_to = "age_label",
      values_to = "value"
    ) |>
    dplyr::mutate(value = as.numeric(value))
}

#///////////////////
#### READ INPUT ####

hosp <- read_csv(input_hosp_file, show_col_types = FALSE) |>
  dplyr::mutate(
    date = as.Date(.data$date),
    age_label = dplyr::recode(.data$age_group, "65-130" = "65+"),
    observation = as.numeric(.data$observation)
  ) |>
  dplyr::filter(
    as.character(.data$location) == "10",
    .data$target == "inc hosp",
    .data$age_label %in% age_order,
    .data$date >= SIM_START_DATE,
    .data$date < SIM_START_DATE + weeks(LOOKAHEAD_WEEKS)
  ) |>
  dplyr::group_by(.data$age_label) |>
  dplyr::summarize(
    calibration_inc_hosp = sum(.data$observation, na.rm = TRUE),
    first_nonzero_hosp_week = {
      nonzero_dates <- .data$date[.data$observation > 0]
      if (length(nonzero_dates) > 0) as.character(min(nonzero_dates)) else NA_character_
    },
    .groups = "drop"
  ) |>
  dplyr::right_join(tibble(age_label = age_order), by = "age_label") |>
  dplyr::mutate(
    calibration_inc_hosp = tidyr::replace_na(.data$calibration_inc_hosp, 0),
    first_nonzero_hosp_week = if_else(is.na(.data$first_nonzero_hosp_week), NA_character_, .data$first_nonzero_hosp_week)
  )

population <- read_age_wide_csv(population_file) |>
  dplyr::rename(population = value)

risk <- read_age_wide_csv(risk_file) |>
  dplyr::rename(high_risk_ratio = value)

start_quarter <- quarter(SIM_START_DATE)
mobility <- read_csv(mobility_rank_file, show_col_types = FALSE) |>
  dplyr::filter(.data$quarter == start_quarter) |>
  dplyr::transmute(
    fips = str_pad(as.character(.data$geoid_o), width = 5, pad = "0"),
    prop_county_outflow = as.numeric(.data$prop_county_outflow),
    total_pop_outflow = as.numeric(.data$total_pop_outflow)
  ) |>
  dplyr::mutate(
    mobility_multiplier = if_else(
      is.finite(.data$total_pop_outflow) & mean(.data$total_pop_outflow, na.rm = TRUE) > 0,
      .data$total_pop_outflow / mean(.data$total_pop_outflow, na.rm = TRUE),
      1
    )
  )

county_age <- population |>
  dplyr::left_join(risk, by = c("fips", "age_label")) |>
  dplyr::left_join(mobility, by = "fips") |>
  dplyr::mutate(
    high_risk_ratio = tidyr::replace_na(.data$high_risk_ratio, 0),
    mobility_multiplier = tidyr::replace_na(.data$mobility_multiplier, 1),
    low_risk_population = .data$population * (1 - .data$high_risk_ratio),
    allocation_weight = (.data$low_risk_population ^ POPULATION_POWER) *
      (.data$mobility_multiplier ^ MOBILITY_POWER)
  )

#//////////////////////////////////////////
#### STATE HOSPITALIZATIONS -> STATE E ####

state_age_estimate <- hosp |>
  dplyr::mutate(
    prop_E_to_IA = unname(PROP_E_TO_IA[.data$age_label]),
    prop_IS_to_H_lowrisk = unname(PROP_IS_TO_H_LOWRISK[.data$age_label]),
    lowrisk_exposed_to_hosp_probability = (1 - .data$prop_E_to_IA) * .data$prop_IS_to_H_lowrisk,
    raw_state_initial_exposed = .data$calibration_inc_hosp / .data$lowrisk_exposed_to_hosp_probability,
    state_initial_exposed = pmax(
      round(.data$raw_state_initial_exposed),
      if_else(.data$calibration_inc_hosp > 0, MIN_STATE_EXPOSED_PER_ACTIVE_AGE, 0)
    )
  )

#///////////////////////////////////
#### STATE E -> COUNTY-AGE SEEDS ####

initial_rows <- county_age |>
  dplyr::left_join(state_age_estimate, by = "age_label") |>
  dplyr::group_by(.data$age_label) |>
  dplyr::mutate(
    infected = largest_remainder_round(.data$allocation_weight, unique(.data$state_initial_exposed)),
    age_group = unname(age_index[.data$age_label])
  ) |>
  dplyr::ungroup() |>
  dplyr::filter(.data$infected > 0) |>
  dplyr::arrange(.data$age_group, .data$fips) |>
  dplyr::transmute(
    county = .data$fips,
    infected = as.integer(.data$infected),
    age_group = as.integer(.data$age_group),
    age_label = .data$age_label,
    calibration_inc_hosp = .data$calibration_inc_hosp,
    raw_state_initial_exposed = .data$raw_state_initial_exposed,
    state_initial_exposed = .data$state_initial_exposed,
    low_risk_population = .data$low_risk_population,
    prop_county_outflow = .data$prop_county_outflow,
    total_pop_outflow = .data$total_pop_outflow,
    allocation_weight = .data$allocation_weight
  )

json_rows <- initial_rows |>
  dplyr::transmute(
    county = as.character(.data$county),
    infected = as.character(.data$infected),
    age_group = as.character(.data$age_group)
  )

method_rows <- state_age_estimate |>
  dplyr::mutate(
    sim_start_date = as.character(SIM_START_DATE),
    lookahead_weeks = LOOKAHEAD_WEEKS,
    population_power = POPULATION_POWER,
    mobility_power = MOBILITY_POWER,
    min_state_exposed_per_active_age = MIN_STATE_EXPOSED_PER_ACTIVE_AGE,
    age_label = factor(.data$age_label, levels = age_order)
  ) |>
  dplyr::arrange(.data$age_label) |>
  dplyr::mutate(age_label = as.character(.data$age_label)) |>
  dplyr::select(
    "sim_start_date",
    "lookahead_weeks",
    "age_label",
    "calibration_inc_hosp",
    "first_nonzero_hosp_week",
    "prop_E_to_IA",
    "prop_IS_to_H_lowrisk",
    "lowrisk_exposed_to_hosp_probability",
    "raw_state_initial_exposed",
    "state_initial_exposed",
    "population_power",
    "mobility_power",
    "min_state_exposed_per_active_age"
  )

write_csv(initial_rows, paste0(output_stub, ".csv"))
write_json(json_rows, paste0(output_stub, ".json"), pretty = TRUE, auto_unbox = TRUE)
write_csv(method_rows, paste0(output_stub, "_method.csv"))

#/////////////////////////////////////////////
#### WRITE DELAWARE_TEST INPUT DIRECTORY ####

dir.create(test_output_dir, showWarnings = FALSE, recursive = TRUE)

test_file_map <- c(
  population = "county_pop_by_age_Delaware_TEST_2019-2023ACS.csv",
  contact = "contact_matrix_Delaware_TEST_Mistry2021_all.csv",
  flow = "Delaware_TEST_Q3-2019_mobility-matrix.csv",
  high_risk_ratios = "county_Delaware_TEST_high-risk-ratios-flu-only.csv"
)

invisible(file.copy(
  from = c(
    population_file,
    file.path(repo_root, "data", STATE_NAME, "contact_matrix_Delaware_Mistry2021_all.csv"),
    file.path(repo_root, "data", STATE_NAME, "Delaware_Q3-2019_mobility-matrix.csv"),
    risk_file
  ),
  to = file.path(test_output_dir, unname(test_file_map)),
  overwrite = TRUE
))

test_template <- jsonlite::fromJSON(baseline_template_file, simplifyVector = FALSE)
test_template$output_dir_path <- "Delaware_TEST_BASELINE"
test_template$batch_num <- "0"
test_template$metadata_tags <- list(
  creator = "PES",
  disease = list("influenza"),
  sim_day_0 = as.character(SIM_START_DATE),
  notes = list(
    "Delaware manuscript test input using age-stratified incident influenza hospitalization-derived low-risk exposures."
  )
)
test_template$data$population <- file.path("..", "data", TEST_STATE_DIR, test_file_map[["population"]])
test_template$data$contact <- file.path("..", "data", TEST_STATE_DIR, test_file_map[["contact"]])
test_template$data$flow <- file.path("..", "data", TEST_STATE_DIR, test_file_map[["flow"]])
test_template$data$high_risk_ratios <- file.path("..", "data", TEST_STATE_DIR, test_file_map[["high_risk_ratios"]])
test_template$initial_exposed <- json_rows

jsonlite::write_json(test_template, test_input_file, auto_unbox = TRUE, pretty = TRUE, null = "null")

message("Wrote: ", paste0(output_stub, ".csv"))
message("Wrote: ", paste0(output_stub, ".json"))
message("Wrote: ", paste0(output_stub, "_method.csv"))
message("Wrote: ", test_input_file)
message("Total initial low-risk exposures: ", sum(initial_rows$infected))
