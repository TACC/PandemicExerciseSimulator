#////////
#### Script Overview ####
#////////
#' Derive state/DC initial low-risk exposures from age-stratified incident influenza
#' hospitalization data, then write simulator-ready input JSONs.
#'
#' Flu Scenario Modeling Hub timing:
#'   - https://github.com/midas-network/flu-scenario-modeling-hub
#'   - projection starts are configurable with --sim-start-date=YYYY-MM-DD;
#'   - weekly incident hospitalization targets are Sun-Sat epi-weeks dated by
#'     the Saturday week end;
#'   - hospitalization points before the simulation start are excluded when
#'     deriving initial exposures.
#'
#' Default target:
#'   - simulation start: 2025-10-01
#'   - hospitalization source: data/Flu-Hub-Data/time-series_2026-07-13.csv
#'   - disease/template source: data/INPUT_FILE_TEMPLATES/INPUT_SEIHRD-STOCH_STATE_BASELINE_H3N2.json
#'
#' Outputs:
#'   - STATE_INIT_TEST/DERIVED_INITIAL_EXPOSED/derived_initial_exposed_state_age_2025-10-01.csv
#'   - STATE_INIT_TEST/DERIVED_INITIAL_EXPOSED/derived_initial_exposed_county_age_2025-10-01.csv
#'   - STATE_INIT_TEST/SEED_INPUT_JSONS/2025-10-01/*.json
#////////
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(lubridate)
  library(jsonlite)
  library(tigris)
})

#////////
#### USER SETTINGS ####
#////////

SIM_START_DATE <- as.Date(get0("SIM_DAY_0", ifnotfound = "2025-10-01"))
HOSPITALIZATION_FILE <- file.path("data", "FLU_HUB", "time-series_2026-07-13.csv")
TEMPLATE_FILE <- file.path("data", "INPUT_FILE_TEMPLATES", "INPUT_SEIHRD-STOCH_STATE_BASELINE_H3N2.json")
LOWRISK_HOSP_RATE_FILE <- NA_character_
OUTPUT_DIR <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_INIT_TEST")
INPUT_JSON_DIR <- file.path(OUTPUT_DIR, "SEED_INPUT_JSONS")
VALIDATION_FIT_DATA_DIR <- file.path(OUTPUT_DIR, "validation_fit_data")
POPULATION_ACS_RANGE <- get0("ACS_YEAR_RANGE", ifnotfound = "2020-2024")

# County allocation weights:
#   low_risk_population^POPULATION_POWER *
#   normalized_mobility_outflow^MOBILITY_POWER
#
# MOBILITY_POWER = 0 uses only county-age low-risk population. A small nonzero
# value gives mild preference to counties with greater outbound connectivity.
POPULATION_POWER <- 1.0
MOBILITY_POWER <- 0.25
MIN_TIMING_WEIGHT <- 0.25
MIN_STATE_EXPOSED_PER_ACTIVE_AGE <- 1L

age_order <- c("0-4", "5-17", "18-49", "50-64", "65+")
age_index <- setNames(seq_along(age_order) - 1L, age_order)

#////////
#### ARGUMENT/PATH SETUP ####
#////////

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

trailing_args <- commandArgs(trailingOnly = TRUE)
get_arg_value <- function(prefix, default) {
  match <- trailing_args[startsWith(trailing_args, prefix)]
  if (length(match) == 0) {
    return(default)
  }
  sub(prefix, "", match[[1]], fixed = TRUE)
}

sim_start_date <- as.Date(get_arg_value("--sim-start-date=", as.character(SIM_START_DATE)))
template_file <- get_arg_value("--template=", TEMPLATE_FILE)
hospitalization_file <- get_arg_value("--hosp-file=", HOSPITALIZATION_FILE)
lowrisk_hosp_rate_file <- get_arg_value("--lowrisk-hosp-rate-file=", LOWRISK_HOSP_RATE_FILE)
output_dir <- get_arg_value("--output-dir=", OUTPUT_DIR)

abs_path <- function(path) {
  if (grepl("^/", path)) {
    normalizePath(path, mustWork = FALSE)
  } else {
    normalizePath(file.path(repo_root, path), mustWork = FALSE)
  }
}

template_file <- abs_path(template_file)
hospitalization_file <- abs_path(hospitalization_file)
lowrisk_hosp_rate_file <- if (!is.na(lowrisk_hosp_rate_file) && nzchar(lowrisk_hosp_rate_file)) {
  abs_path(lowrisk_hosp_rate_file)
} else {
  NA_character_
}
output_dir <- abs_path(output_dir)
input_json_dir <- file.path(output_dir, "SEED_INPUT_JSONS", as.character(sim_start_date))
derived_initial_exposed_dir <- file.path(output_dir, "DERIVED_INITIAL_EXPOSED")
validation_fit_data_dir <- file.path(output_dir, "validation_fit_data")
SIM_START_DATE <- sim_start_date

dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(input_json_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(derived_initial_exposed_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(validation_fit_data_dir, showWarnings = FALSE, recursive = TRUE)

#////////
#### HELPER FUNCTIONS ####
#////////

replace_state_tokens <- function(x, state_dir) {
  pat <- "(?<![A-Za-z0-9])STATE(?![A-Za-z0-9])"
  if (is.character(x)) {
    stringr::str_replace_all(x, pat, state_dir)
  } else if (is.list(x)) {
    lapply(x, replace_state_tokens, state_dir = state_dir)
  } else {
    x
  }
}

largest_remainder_round <- function(values, target_total) {
  if (length(values) == 0 || target_total <= 0 || sum(values, na.rm = TRUE) <= 0) {
    return(rep(0L, length(values)))
  }

  scaled <- values / sum(values, na.rm = TRUE) * target_total
  floored <- floor(scaled)
  remainder <- target_total - sum(floored)

  if (remainder > 0) {
    bump_idx <- order(scaled - floored, decreasing = TRUE)[seq_len(remainder)]
    floored[bump_idx] <- floored[bump_idx] + 1
  }

  as.integer(floored)
}

read_age_wide_csv <- function(path, value_name) {
  readr::read_csv(path, show_col_types = FALSE, col_types = cols(.default = col_character())) |>
    dplyr::rename(fips = 1) |>
    dplyr::mutate(fips = stringr::str_pad(as.character(.data$fips), width = 5, pad = "0")) |>
    tidyr::pivot_longer(
      cols = all_of(age_order),
      names_to = "age_group",
      values_to = value_name
    ) |>
    dplyr::mutate(dplyr::across(all_of(value_name), as.numeric))
}

json_numeric_vector <- function(x, expected_length = length(age_order), label = deparse(substitute(x))) {
  out <- as.numeric(unlist(x, use.names = FALSE))
  if (length(out) != expected_length || anyNA(out)) {
    stop("Template parameter ", label, " must contain ", expected_length, " numeric values.")
  }
  out
}

json_numeric_scalar <- function(x, label = deparse(substitute(x))) {
  out <- as.numeric(unlist(x, use.names = FALSE)[[1]])
  if (length(out) != 1 || is.na(out)) {
    stop("Template parameter ", label, " must be numeric.")
  }
  out
}

read_labeled_age_rate_csv <- function(path, value_col, expected_ages = age_order) {
  rates <- readr::read_csv(path, show_col_types = FALSE) |>
    dplyr::mutate(
      age_group = as.character(.data$age_group),
      age_group_index = as.integer(.data$age_group_index),
      value = as.numeric(.data[[value_col]])
    ) |>
    dplyr::arrange(.data$age_group_index)

  if (!identical(rates$age_group, expected_ages)) {
    stop(
      "Age groups in ", path, " must match model age order: ",
      paste(expected_ages, collapse = ", ")
    )
  }
  if (anyNA(rates$value) || any(rates$value < 0 | rates$value > 1)) {
    stop(value_col, " in ", path, " must be numeric probabilities in [0, 1].")
  }

  stats::setNames(rates$value, rates$age_group)
}

template_age_rate <- function(values, expected_ages = age_order, label = deparse(substitute(values))) {
  rates <- json_numeric_vector(values, expected_length = length(expected_ages), label = label)
  if (any(rates < 0 | rates > 1)) {
    stop(label, " values must be probabilities in [0, 1].")
  }
  stats::setNames(rates, expected_ages)
}

make_json_rows <- function(rows) {
  rows |>
    dplyr::transmute(
      county = as.character(.data$fips),
      infected = as.character(.data$infected),
      age_group = as.character(.data$age_group_index)
    )
}

first_complete_mmwr_week_end <- function(start_date) {
  start_date <- as.Date(start_date)
  days_until_saturday <- (6L - as.POSIXlt(start_date)$wday) %% 7L
  week_end <- start_date + days_until_saturday
  week_start <- week_end - 6L
  if (week_start < start_date) {
    week_end <- week_end + 7L
  }
  week_end
}

#////////
#### READ INPUT ####
#////////

template <- jsonlite::fromJSON(template_file, simplifyVector = FALSE)
disease_parameters <- template$disease_model$parameters

prop_E_to_IA <- setNames(json_numeric_vector(disease_parameters$prop_E_to_IA, label = "prop_E_to_IA"), age_order)
prop_IS_to_H_lowrisk <- if (!is.na(lowrisk_hosp_rate_file) && nzchar(lowrisk_hosp_rate_file)) {
  read_labeled_age_rate_csv(
    lowrisk_hosp_rate_file,
    value_col = "prop_IS_to_H_lowrisk"
  )
} else {
  template_age_rate(disease_parameters$prop_IS_to_H_lowrisk, label = "prop_IS_to_H_lowrisk")
}
lowrisk_hosp_rate_source <- if (!is.na(lowrisk_hosp_rate_file) && nzchar(lowrisk_hosp_rate_file)) {
  lowrisk_hosp_rate_file
} else {
  paste0("template:", template_file, "#disease_model.parameters.prop_IS_to_H_lowrisk")
}
disease_parameters$prop_IS_to_H_lowrisk <- as.character(unname(prop_IS_to_H_lowrisk))

exposed_to_hosp_days <- json_numeric_scalar(disease_parameters$E_to_IPandIA_days, "E_to_IPandIA_days") +
  json_numeric_scalar(disease_parameters$IP_to_IS_days, "IP_to_IS_days") +
  json_numeric_scalar(disease_parameters$IS_to_H_days, "IS_to_H_days")
timing_lambda <- 1 / (exposed_to_hosp_days / 7)

state_lookup <- tigris::fips_codes |>
  dplyr::distinct(
    state_abbr = .data$state,
    state_name = .data$state_name,
    location = stringr::str_pad(as.character(.data$state_code), width = 2, pad = "0")
  ) |>
  dplyr::filter(as.integer(.data$location) < 60) |>
  dplyr::mutate(state_dir = stringr::str_replace_all(.data$state_name, " ", "-")) |>
  dplyr::arrange(.data$state_name)

flu_ts <- readr::read_csv(hospitalization_file, show_col_types = FALSE) |>
  dplyr::mutate(
    date = as.Date(.data$date),
    location = stringr::str_pad(as.character(.data$location), width = 2, pad = "0"),
    observation = as.numeric(.data$observation)
  ) |>
  dplyr::filter(.data$target == "inc hosp") |>
  dplyr::filter(.data$location != "US") |>
  dplyr::left_join(state_lookup, by = "location") |>
  dplyr::filter(!is.na(.data$state_abbr)) |>
  dplyr::filter(.data$age_group != "0-130") |>
  dplyr::filter(.data$date >= SIM_START_DATE) |>
  dplyr::mutate(
    age_group = dplyr::recode(.data$age_group, "65-130" = "65+"),
    age_group = factor(.data$age_group, levels = age_order),
    weeks_from_start = as.numeric(.data$date - SIM_START_DATE) / 7,
    data_points_from_start = as.integer(.data$weeks_from_start) + 1L
  ) |>
  dplyr::filter(.data$age_group %in% age_order) |>
  dplyr::arrange(.data$state_name, .data$age_group, .data$date)

first_hosp_by_age <- flu_ts |>
  dplyr::filter(.data$observation > 0) |>
  dplyr::group_by(.data$state_abbr, .data$state_name, .data$state_dir, .data$location, .data$age_group) |>
  dplyr::slice_min(.data$date, n = 1, with_ties = FALSE) |>
  dplyr::ungroup()

state_age_estimate <- first_hosp_by_age |>
  dplyr::mutate(
    age_group_chr = as.character(.data$age_group),
    prop_E_to_IA = unname(prop_E_to_IA[.data$age_group_chr]),
    prop_IS_to_H_lowrisk = unname(prop_IS_to_H_lowrisk[.data$age_group_chr]),
    exposed_to_hosp_probability = (1 - .data$prop_E_to_IA) * .data$prop_IS_to_H_lowrisk,
    timing_weight = MIN_TIMING_WEIGHT +
      (1 - MIN_TIMING_WEIGHT) * exp(-timing_lambda * .data$weeks_from_start),
    effective_hosps = .data$observation * .data$timing_weight,
    raw_initial_exposed = .data$effective_hosps / .data$exposed_to_hosp_probability,
    state_initial_exposed = pmax(
      round(.data$raw_initial_exposed),
      if_else(.data$observation > 0, MIN_STATE_EXPOSED_PER_ACTIVE_AGE, 0L)
    )
  ) |>
  dplyr::arrange(.data$state_name, .data$age_group) |>
  dplyr::select(-"age_group_chr")

all_state_age <- state_lookup |>
  tidyr::crossing(age_group = factor(age_order, levels = age_order)) |>
  dplyr::left_join(
    state_age_estimate,
    by = c("state_abbr", "state_name", "state_dir", "location", "age_group")
  ) |>
  dplyr::mutate(
    age_group_chr = as.character(.data$age_group),
    observation = tidyr::replace_na(.data$observation, 0),
    weeks_from_start = tidyr::replace_na(.data$weeks_from_start, 0),
    data_points_from_start = tidyr::replace_na(.data$data_points_from_start, 1L),
    prop_E_to_IA = dplyr::if_else(
      is.na(.data$prop_E_to_IA),
      unname(prop_E_to_IA[.data$age_group_chr]),
      .data$prop_E_to_IA
    ),
    prop_IS_to_H_lowrisk = dplyr::if_else(
      is.na(.data$prop_IS_to_H_lowrisk),
      unname(prop_IS_to_H_lowrisk[.data$age_group_chr]),
      .data$prop_IS_to_H_lowrisk
    ),
    exposed_to_hosp_probability = dplyr::if_else(
      is.na(.data$exposed_to_hosp_probability),
      (1 - .data$prop_E_to_IA) * .data$prop_IS_to_H_lowrisk,
      .data$exposed_to_hosp_probability
    ),
    timing_weight = tidyr::replace_na(.data$timing_weight, 0),
    effective_hosps = tidyr::replace_na(.data$effective_hosps, 0),
    raw_initial_exposed = tidyr::replace_na(.data$raw_initial_exposed, 0),
    state_initial_exposed = tidyr::replace_na(.data$state_initial_exposed, 0)
  ) |>
  dplyr::select(-"age_group_chr")

#////////
#### STATE E -> COUNTY-AGE SEEDS ####
#////////

county_age_for_state <- function(state_dir) {
  population_file <- file.path(
    repo_root,
    "data",
    state_dir,
    paste0("county_pop_by_age_", state_dir, "_", POPULATION_ACS_RANGE, "ACS.csv")
  )
  risk_file <- file.path(repo_root, "data", state_dir, paste0("county_", state_dir, "_high-risk-ratios-flu-only.csv"))
  mobility_rank_file <- file.path(repo_root, "data", state_dir, paste0(state_dir, "_quarterly-2019_county-connection-ranking.csv"))

  population <- read_age_wide_csv(population_file, "population")
  risk <- read_age_wide_csv(risk_file, "high_risk_ratio")

  mobility <- readr::read_csv(mobility_rank_file, show_col_types = FALSE) |>
    dplyr::filter(.data$quarter == lubridate::quarter(SIM_START_DATE)) |>
    dplyr::transmute(
      fips = stringr::str_pad(as.character(.data$geoid_o), width = 5, pad = "0"),
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

  population |>
    dplyr::left_join(risk, by = c("fips", "age_group")) |>
    dplyr::left_join(mobility, by = "fips") |>
    dplyr::mutate(
      state_dir = state_dir,
      high_risk_ratio = tidyr::replace_na(.data$high_risk_ratio, 0),
      mobility_multiplier = tidyr::replace_na(.data$mobility_multiplier, 1),
      low_risk_population = .data$population * (1 - .data$high_risk_ratio),
      allocation_weight = (.data$low_risk_population ^ POPULATION_POWER) *
        (.data$mobility_multiplier ^ MOBILITY_POWER)
    )
}

county_age <- purrr::map_dfr(state_lookup$state_dir, county_age_for_state)

initial_rows <- county_age |>
  dplyr::left_join(
    all_state_age |>
      dplyr::select(
        "state_dir",
        "state_abbr",
        "state_name",
        "age_group",
        "date",
        first_hosp_count = "observation",
        "timing_weight",
        "effective_hosps",
        "raw_initial_exposed",
        "state_initial_exposed"
      ),
    by = c("state_dir", "age_group")
  ) |>
  dplyr::group_by(.data$state_dir, .data$age_group) |>
  dplyr::mutate(
    infected = largest_remainder_round(.data$allocation_weight, unique(.data$state_initial_exposed)),
    age_group_index = unname(age_index[as.character(.data$age_group)])
  ) |>
  dplyr::ungroup() |>
  dplyr::filter(.data$infected > 0) |>
  dplyr::arrange(.data$state_name, .data$age_group_index, .data$fips)

#////////
#### WRITE OUTPUT ####
#////////

state_summary_file <- file.path(derived_initial_exposed_dir, paste0("derived_initial_exposed_state_age_", SIM_START_DATE, ".csv"))
county_summary_file <- file.path(derived_initial_exposed_dir, paste0("derived_initial_exposed_county_age_", SIM_START_DATE, ".csv"))

state_summary <- all_state_age |>
  dplyr::mutate(
    sim_start_date = as.character(SIM_START_DATE),
    template_file = template_file,
    lowrisk_hosp_rate_file = lowrisk_hosp_rate_source,
    exposed_to_hosp_days = exposed_to_hosp_days,
    timing_lambda = timing_lambda,
    min_timing_weight = MIN_TIMING_WEIGHT,
    population_power = POPULATION_POWER,
    mobility_power = MOBILITY_POWER
  ) |>
  dplyr::select(
    "sim_start_date",
    "template_file",
    "lowrisk_hosp_rate_file",
    "state_abbr",
    "state_name",
    "location",
    "age_group",
    first_hosp_date = "date",
    first_hosp_count = "observation",
    "weeks_from_start",
    "prop_E_to_IA",
    "prop_IS_to_H_lowrisk",
    "exposed_to_hosp_probability",
    "exposed_to_hosp_days",
    "timing_lambda",
    "timing_weight",
    "effective_hosps",
    "raw_initial_exposed",
    "state_initial_exposed",
    "min_timing_weight",
    "population_power",
    "mobility_power"
  )

county_summary <- initial_rows |>
  dplyr::select(
    "state_abbr",
    "state_name",
    "state_dir",
    "fips",
    "age_group",
    "age_group_index",
    "infected",
    "state_initial_exposed",
    "first_hosp_count",
    "timing_weight",
    "effective_hosps",
    "low_risk_population",
    "prop_county_outflow",
    "total_pop_outflow",
    "allocation_weight"
  )

readr::write_csv(state_summary, state_summary_file)
readr::write_csv(county_summary, county_summary_file)

validation_records <- flu_ts |>
  dplyr::filter(.data$date >= first_complete_mmwr_week_end(SIM_START_DATE)) |>
  dplyr::mutate(
    date = as.character(.data$date),
    age_group = as.character(.data$age_group),
    observation = as.numeric(.data$observation)
  ) |>
  dplyr::select(
    "state_dir",
    "date",
    "location",
    "age_group",
    incident_hospitalizations = "observation",
    "weeks_from_start",
    "data_points_from_start"
  )

json_files <- character()
for (state_dir in state_lookup$state_dir) {
  state_meta <- state_lookup |>
    dplyr::filter(.data$state_dir == !!state_dir) |>
    dplyr::slice(1)

  state_json_rows <- initial_rows |>
    dplyr::filter(.data$state_dir == !!state_dir) |>
    make_json_rows()
  
  validation_fit_data_file <- file.path(
    validation_fit_data_dir,
    paste0("validation_fit_inc_hosp_", state_dir, "_", SIM_START_DATE, ".csv")
  )
  validation_fit_data_relpath <- file.path(
    "validation_fit_data",
    basename(validation_fit_data_file)
  )
  
  validation_records |>
    dplyr::filter(.data$state_dir == !!state_dir) |>
    dplyr::select(-"state_dir") |>
    dplyr::arrange(.data$date, .data$age_group) |>
    readr::write_csv(validation_fit_data_file)

  state_template <- replace_state_tokens(template, state_dir = state_dir)
  state_template$disease_model$parameters$prop_IS_to_H_lowrisk <- as.character(unname(prop_IS_to_H_lowrisk))
  state_template$output_dir_path <- "GENERATE"
  state_template$metadata_tags$creator <- "Emily M Javan"
  state_template$metadata_tags$disease <- list("influenza", "flu", "H3N2")
  state_template$metadata_tags$sim_day_0 <- as.character(SIM_START_DATE)
  state_template$metadata_tags$notes <- c(
    "Baseline seed input for Epydemix calibration; manuscript inputs are generated separately.",
    paste0(
      "Initial exposures derived from first age-stratified incident influenza hospitalizations in ",
      state_meta$state_name,
      " with week-ending dates on/after ",
      SIM_START_DATE,
      "; earlier week-ending points are excluded",
      "."
    )
  )
  state_template$metadata_tags$validation <- list(
    kind = "incident_hospitalizations",
    source = "Flu Scenario Modeling Hub time-series",
    source_file = hospitalization_file,
    lowrisk_hosp_rate_file = lowrisk_hosp_rate_source,
    target = "inc hosp",
    sim_start_date = as.character(SIM_START_DATE),
    fit_start_date = as.character(first_complete_mmwr_week_end(SIM_START_DATE)),
    observed_date_type = "week ending date",
    fit_data_file = validation_fit_data_relpath,
    generated_series = list(
      source_transition = "IS_to_H",
      method = "daily new IS-to-H admissions summed over complete Sun-Sat MMWR weeks"
    )
  )
  state_template$antiviral_model <- structure(list(), names = character())
  state_template$vaccine_model <- structure(list(), names = character())
  state_template$non_pharma_interventions <- list()
  state_template$initial_exposed <- state_json_rows

  output_file <- file.path(input_json_dir, paste0("INPUT_SEIHRD-STOCH_", state_dir, "_SEED_BASELINE.json"))
  jsonlite::write_json(state_template, output_file, auto_unbox = TRUE, pretty = TRUE, null = "null")
  json_files <- c(json_files, output_file)
}

message("Wrote: ", state_summary_file)
message("Wrote: ", county_summary_file)
message("Wrote validation fit CSVs to: ", validation_fit_data_dir)
message("Wrote ", length(json_files), " input JSONs to: ", input_json_dir)
message("Total initial low-risk exposures: ", sum(initial_rows$infected))
