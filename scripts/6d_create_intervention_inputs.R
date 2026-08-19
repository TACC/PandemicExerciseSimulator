#////////
#### Script Overview ####
#////////
#' Generate date/state/scenario input JSONs from named templates.
#'
#' NONE_TEMPLATE_FILE defines the no-intervention scenario. INTERVENTION_TEMPLATE_FILES
#' is a named character vector of intervention templates to layer onto each
#' date/state. SELECTED_RUN_SCENARIOS controls which scenarios are written.
#'
#' Templates define the shape of the scenario. Values supplied by 0 can override
#' effectiveness fields when those fields exist in the template.
#////////
library(jsonlite)
library(tidyverse)

source("6c_weekend_npi_schedule.R")

SIM_DAY_0 <- as.Date(get0("SIM_DAY_0", ifnotfound = "2025-10-01"))
SIMULATION_DAYS <- as.integer(get0("SIMULATION_DAYS", ifnotfound = 300L))
PIPELINE_OUTPUT_DIR <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_INIT_TEST")
NONE_TEMPLATE_FILE <- get0("NONE_TEMPLATE_FILE", ifnotfound = "")
INTERVENTION_TEMPLATE_FILES <- get0("INTERVENTION_TEMPLATE_FILES", ifnotfound = character())
SELECTED_RUN_SCENARIOS <- get0(
  "SELECTED_RUN_SCENARIOS",
  ifnotfound = c("NONE", names(INTERVENTION_TEMPLATE_FILES))
)
INPUT_CREATOR <- get0("INPUT_CREATOR", ifnotfound = "Emily M Javan")
NPI_EFFECTIVENESS_BY_AGE <- get0("NPI_EFFECTIVENESS_BY_AGE", ifnotfound = c(0.5, 0.5, 0.5, 0.5, 0.5))
ANTIVIRAL_EFFECTIVENESS_HOSP <- get0("ANTIVIRAL_EFFECTIVENESS_HOSP", ifnotfound = 0.25)
PEDIATRIC_VACCINE_EFFECTIVENESS <- get0("PEDIATRIC_VACCINE_EFFECTIVENESS", ifnotfound = 0.38)
ADULT_VACCINE_EFFECTIVENESS <- get0("ADULT_VACCINE_EFFECTIVENESS", ifnotfound = 0.30)

seed_input_dir <- file.path("..", PIPELINE_OUTPUT_DIR, "SEED_INPUT_JSONS", as.character(SIM_DAY_0))
epydemix_fit_dir <- file.path("..", PIPELINE_OUTPUT_DIR, "epydemix_fit", as.character(SIM_DAY_0))
generated_input_root <- file.path("..", PIPELINE_OUTPUT_DIR, "TACC_FILES")
generated_input_dir <- file.path("..", PIPELINE_OUTPUT_DIR, "TACC_FILES", as.character(SIM_DAY_0))
dir.create(generated_input_dir, showWarnings = FALSE, recursive = TRUE)

intervention_template_files <- INTERVENTION_TEMPLATE_FILES[nzchar(INTERVENTION_TEMPLATE_FILES)]
intervention_template_files <- intervention_template_files[file.exists(intervention_template_files)]

state_weekly_vax_given <- readr::read_csv(
  "../data/VACCINATION/all_US_weekly_vax_distribution.csv",
  show_col_types = FALSE
)
state_antiviral_stockpile <- readr::read_csv(
  "../data/RISK_RATIOS/state_insured-high-risk-antiviral-counts.csv",
  show_col_types = FALSE,
  col_types = readr::cols(STATE_FIPS = readr::col_character())
)

replace_STATE_tokens <- function(x, state_dir) {
  pat <- "(?<![A-Za-z0-9])STATE(?![A-Za-z0-9])"
  if (is.character(x)) {
    stringr::str_replace_all(x, pat, state_dir)
  } else if (is.list(x)) {
    lapply(x, replace_STATE_tokens, state_dir = state_dir)
  } else {
    x
  }
}

repo_relative_from_tacc_files_6d <- function(path) {
  if (is.null(path) || !nzchar(path)) return(path)
  repo_root <- normalizePath("..", mustWork = TRUE)
  path_abs <- if (grepl("^/", path)) {
    normalizePath(path, mustWork = FALSE)
  } else {
    normalizePath(file.path(getwd(), path), mustWork = FALSE)
  }
  repo_prefix <- paste0(repo_root, .Platform$file.sep)
  if (startsWith(path_abs, repo_prefix)) {
    return(file.path("..", "..", sub(repo_prefix, "", path_abs, fixed = TRUE)))
  }
  path
}

relativize_data_paths_6d <- function(config) {
  if (is.null(config$data)) return(config)
  for (data_name in intersect(names(config$data), c("population", "contact", "flow", "high_risk_ratios"))) {
    config$data[[data_name]] <- repo_relative_from_tacc_files_6d(config$data[[data_name]])
  }
  config
}

state_from_seed_path <- function(path) {
  basename(path) %>%
    stringr::str_remove("^INPUT_SEIHRD-STOCH_") %>%
    stringr::str_remove("_SEED_NONE\\.json$")
}

find_calibrated_json <- function(seed_path) {
  stem <- tools::file_path_sans_ext(basename(seed_path))
  fit_subdir <- file.path(epydemix_fit_dir, stem)
  candidates <- list.files(
    fit_subdir,
    pattern = "_EPYDEMIX_R0_ONLY\\.json$",
    full.names = TRUE
  )
  if (length(candidates) == 0) return(NA_character_)
  candidates[[1]]
}

copy_if_present <- function(target, source, path) {
  source_value <- purrr::pluck(source, !!!path, .default = NULL)
  target_value <- purrr::pluck(target, !!!path, .default = NULL)
  if (!is.null(source_value) && !is.null(target_value)) {
    target <- purrr::modify_in(target, path, ~ source_value)
  }
  target
}

copy_calibrated_fields <- function(target, calibrated) {
  if (is.null(calibrated)) return(target)

  target <- copy_if_present(target, calibrated, list("initial_exposed"))
  if (!is.null(purrr::pluck(calibrated, "metadata_tags", "validation", .default = NULL))) {
    if (is.null(target$metadata_tags)) target$metadata_tags <- list()
    target$metadata_tags$validation <- calibrated$metadata_tags$validation
  }
  if (!is.null(purrr::pluck(target, "disease_model", "parameters", .default = NULL)) &&
      !is.null(purrr::pluck(calibrated, "disease_model", "parameters", .default = NULL))) {
    target_params <- names(target$disease_model$parameters)
    calibrated_params <- names(calibrated$disease_model$parameters)
    common_params <- setdiff(intersect(target_params, calibrated_params), "compartments")
    for (param_name in common_params) {
      target$disease_model$parameters[[param_name]] <- calibrated$disease_model$parameters[[param_name]]
    }
  }

  target
}

format_effectiveness <- function(values) {
  as.character(values)
}

match_effectiveness_by_age <- function(values, target_len) {
  values <- as.numeric(values)
  if (length(values) == target_len) {
    return(values)
  }
  stop(
    "NPI_EFFECTIVENESS_BY_AGE length must match the template NPI effectiveness age-group length (",
    target_len,
    ")."
  )
}

vaccine_effectiveness_by_age <- function(target_len) {
  if (target_len == 1) {
    return(ADULT_VACCINE_EFFECTIVENESS)
  }
  if (target_len == 2) {
    return(c(PEDIATRIC_VACCINE_EFFECTIVENESS, ADULT_VACCINE_EFFECTIVENESS))
  }
  c(
    rep(PEDIATRIC_VACCINE_EFFECTIVENESS, min(2, target_len)),
    rep(ADULT_VACCINE_EFFECTIVENESS, max(target_len - 2, 0))
  )
}

state_name_from_dir <- function(state_dir) {
  stringr::str_replace_all(state_dir, "-", " ")
}

make_vaccine_stockpile_json <- function(state_df) {
  state_df %>%
    arrange(.data$ReleaseDay) %>%
    transmute(
      day = as.character(.data$ReleaseDay),
      amount = as.character(round(.data$TotalWeeklyNewFullProtect))
    ) %>%
    purrr::transpose()
}

make_antiviral_stockpile_json <- function(amount) {
  list(list(day = "0", amount = as.character(round(amount))))
}

apply_state_stockpiles <- function(config, state_dir, scenario_label) {
  state_name <- state_name_from_dir(state_dir)

  if (!is.null(purrr::pluck(config, "vaccine_model", "parameters", "vaccine_stockpile", .default = NULL))) {
    state_vax_ts <- state_weekly_vax_given %>%
      dplyr::filter(.data$State == state_name)
    if (nrow(state_vax_ts) == 0) {
      stop("No vaccine stockpile rows found for ", state_name, " while writing ", scenario_label, ".")
    }
    config$vaccine_model$parameters$vaccine_stockpile <- make_vaccine_stockpile_json(state_vax_ts)
  }

  if (!is.null(purrr::pluck(config, "antiviral_model", "parameters", "antiviral_stockpile", .default = NULL))) {
    state_antiviral <- state_antiviral_stockpile %>%
      dplyr::filter(.data$STATE_NAME == state_name)
    if (nrow(state_antiviral) == 0) {
      stop("No antiviral stockpile row found for ", state_name, " while writing ", scenario_label, ".")
    }
    amount <- state_antiviral$insured_high_risk_pop[[1]]
    if (is.na(amount)) {
      stop("Antiviral stockpile amount is NA for ", state_name, " while writing ", scenario_label, ".")
    }
    config$antiviral_model$parameters$antiviral_stockpile <- make_antiviral_stockpile_json(amount)
  }

  config
}

apply_experiment_overrides <- function(config) {
  npis <- purrr::pluck(config, "non_pharma_interventions", .default = NULL)
  if (length(npis) > 0) {
    npis <- purrr::map(npis, function(npi_row) {
      if (!is.null(npi_row$effectiveness)) {
        target_len <- length(npi_row$effectiveness)
        npi_row$effectiveness <- format_effectiveness(
          match_effectiveness_by_age(NPI_EFFECTIVENESS_BY_AGE, target_len)
        )
      }
      npi_row
    })
    weekend_rows <- purrr::map_lgl(
      npis,
      ~ identical(as.character(.x$identity), "weekend-mobility-decrease")
    )
    if (any(weekend_rows)) {
      weekend_schedule <- make_weekend_mobility_npis(
        npis[[which(weekend_rows)[[1]]]],
        sim_day_0 = SIM_DAY_0,
        simulation_days = SIMULATION_DAYS
      )
      npis <- c(npis[!weekend_rows], weekend_schedule)
    }
    config$non_pharma_interventions <- npis
  }

  antiviral_hosp <- purrr::pluck(
    config,
    "antiviral_model", "parameters", "antiviral_effectiveness_hosp",
    .default = NULL
  )
  if (!is.null(antiviral_hosp)) {
    config$antiviral_model$parameters$antiviral_effectiveness_hosp <-
      as.character(ANTIVIRAL_EFFECTIVENESS_HOSP)
  }

  vaccine_effectiveness <- purrr::pluck(
    config,
    "vaccine_model", "parameters", "vaccine_effectiveness",
    .default = NULL
  )
  if (!is.null(vaccine_effectiveness)) {
    target_len <- length(vaccine_effectiveness)
    config$vaccine_model$parameters$vaccine_effectiveness <- format_effectiveness(
      vaccine_effectiveness_by_age(target_len)
    )
  }

  config
}

set_generic_metadata <- function(config, state_dir, scenario_label) {
  if (is.null(config$metadata_tags)) config$metadata_tags <- list()
  if (is.null(config$metadata_tags$creator)) {
    config$metadata_tags$creator <- INPUT_CREATOR
  }
  config$metadata_tags$sim_day_0 <- as.character(SIM_DAY_0)
  config$metadata_tags$state_dir <- state_dir
  config$metadata_tags$scenario_label <- scenario_label
  config$metadata_tags$experiment_controls <- list(
    npi_effectiveness_by_age = as.numeric(NPI_EFFECTIVENESS_BY_AGE),
    antiviral_effectiveness_hosp = as.numeric(ANTIVIRAL_EFFECTIVENESS_HOSP),
    pediatric_vaccine_effectiveness = as.numeric(PEDIATRIC_VACCINE_EFFECTIVENESS),
    adult_vaccine_effectiveness = as.numeric(ADULT_VACCINE_EFFECTIVENESS)
  )
  config$output_dir_path <- "GENERATE"
  config$batch_num <- "GENERATE"
  config
}

write_scenario <- function(config, state_dir, scenario_label) {
  config <- relativize_data_paths_6d(config)
  output_file <- file.path(
    generated_input_dir,
    paste0("INPUT_", state_dir, "_", scenario_label, ".json")
  )
  jsonlite::write_json(config, output_file, auto_unbox = TRUE, pretty = TRUE, null = "null")
  output_file
}

seed_files <- list.files(
  seed_input_dir,
  pattern = "^INPUT_SEIHRD-STOCH_.*_SEED_NONE\\.json$",
  full.names = TRUE
)
if (length(seed_files) == 0) {
  stop("No seed input JSONs found in ", seed_input_dir, ". Run 5a first.")
}

intervention_templates <- purrr::map(
  intervention_template_files,
  jsonlite::fromJSON,
  simplifyVector = FALSE
)
none_template <- if (nzchar(NONE_TEMPLATE_FILE) && file.exists(NONE_TEMPLATE_FILE)) {
  jsonlite::fromJSON(NONE_TEMPLATE_FILE, simplifyVector = FALSE)
} else {
  NULL
}

json_files <- character()
for (seed_file in seed_files) {
  state_dir <- state_from_seed_path(seed_file)
  calibrated_file <- find_calibrated_json(seed_file)
  calibrated <- if (!is.na(calibrated_file)) {
    jsonlite::fromJSON(calibrated_file, simplifyVector = FALSE)
  } else {
    jsonlite::fromJSON(seed_file, simplifyVector = FALSE)
  }

  if (!is.null(none_template)) {
    none <- replace_STATE_tokens(none_template, state_dir = state_dir)
    none <- copy_calibrated_fields(none, calibrated)
  } else {
    none <- calibrated
    none$antiviral_model <- structure(list(), names = character())
    none$vaccine_model <- structure(list(), names = character())
    none$non_pharma_interventions <- list()
  }
  if ("NONE" %in% SELECTED_RUN_SCENARIOS) {
    none <- apply_experiment_overrides(none)
    none <- set_generic_metadata(none, state_dir, "NONE")
    json_files <- c(json_files, write_scenario(none, state_dir, "NONE"))
  }

  for (scenario_label in intersect(names(intervention_templates), SELECTED_RUN_SCENARIOS)) {
    intervention_config <- replace_STATE_tokens(intervention_templates[[scenario_label]], state_dir = state_dir)
    intervention_config <- copy_calibrated_fields(intervention_config, calibrated)
    intervention_config <- apply_state_stockpiles(intervention_config, state_dir, scenario_label)
    intervention_config <- apply_experiment_overrides(intervention_config)
    intervention_config <- set_generic_metadata(intervention_config, state_dir, scenario_label)
    json_files <- c(json_files, write_scenario(intervention_config, state_dir, scenario_label))
  }
}

message("Wrote ", length(json_files), " generated input JSONs to ", generated_input_dir)
