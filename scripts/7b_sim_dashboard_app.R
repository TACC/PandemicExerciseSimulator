#////////
#### Script Overview ####
#////////
# Browser dashboard for exploring simulation metadata, checking run completion,
# and exporting finished scenarios to CSV.
#
# Run with:  shiny::runApp("scripts/sim_dashboard")
# Or open app.R in RStudio and click "Run App"
#
# Dependencies: shiny, bslib, DT, dplyr, readr, duckdb, arrow, bsicons
#////////
#### Load packages #############################################################
library(shiny)
library(plotly)
library(bslib)
library(DT)
library(tidyverse)
library(duckdb)
library(bsicons)

# ── Paths (relative to repo root) ────────────────────────────────────────────
DASHBOARD_DATA_DIR <- "LS6_RmSweep_TEST"
PROJECT_ROOT <- if (basename(getwd()) == "scripts") {
  normalizePath("..", mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}
DATA_ROOT    <- normalizePath(file.path(PROJECT_ROOT, DASHBOARD_DATA_DIR), mustWork = FALSE)
MASTER_CSV   <- file.path(DATA_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(DATA_ROOT, "sim_data")
FEATURES_PARQUET <- file.path(DATA_ROOT, "scenario_features.parquet")
# Source previews reuse the prepared bundle; simulator data/ has no map dependency.
MAP_ASSET_ROOT <- if (identical(DASHBOARD_DATA_DIR, "data")) {
  file.path(DATA_ROOT, "dashboard_map_assets")
} else {
  file.path(PROJECT_ROOT, "deploy", "shinyapps", "PandemicSimExplorer", "data", "dashboard_map_assets")
}
if (dir.exists(file.path(MAP_ASSET_ROOT, "map_boundaries"))) {
  shiny::addResourcePath("county-boundaries", file.path(MAP_ASSET_ROOT, "map_boundaries"))
}
message("Dashboard data root: ", DATA_ROOT)
message("Dashboard master rows: ", if (file.exists(MASTER_CSV)) nrow(readr::read_csv(MASTER_CSV, show_col_types = FALSE)) else 0)
AGE_LABELS   <- c("0-4", "5-17", "18-49", "50-64", "65+")
AGE_CHOICES  <- c("All ages" = "all", stats::setNames(as.character(seq_along(AGE_LABELS) - 1L), AGE_LABELS))
COMPARTMENT_ORDER <- c("S", "E", "A", "IA", "IP", "IS", "I", "T", "H", "R", "D")

# ── Helpers ───────────────────────────────────────────────────────────────────

load_metadata <- function() {
  if (!file.exists(MASTER_CSV)) {
    return(tibble(
      scenario_hash = character(), batch_num = character(),
      metadata_creator = character(), metadata_disease = character(),
      metadata_sim_day_0 = character(), metadata_notes = character(),
      metadata_tags_json = character(), validation_used = logical(),
      validation_json = character(), validation_fit_data_file = character(),
      geo_region = character(), disease_identity = character(),
      vaccine_used = logical(), antiviral_used = logical(),
      npi_used = logical(), attempt_realization_count = integer(),
      complete_realization_count = integer(), mean_run_time_seconds = double(),
      created_at_utc = character()
    ))
  }
  metadata <- read_csv(
    MASTER_CSV,
    col_types = readr::cols(
      validation_json = readr::col_character(),
      validation_fit_data_file = readr::col_character(),
      .default = readr::col_guess()
    ),
    show_col_types = FALSE
  )
  optional_tag_columns <- c(
    "metadata_creator",
    "metadata_disease",
    "metadata_sim_day_0",
    "metadata_notes",
    "metadata_tags_json",
    "validation_json",
    "validation_fit_data_file"
  )
  for (column in optional_tag_columns) {
    if (!column %in% names(metadata)) metadata[[column]] <- NA_character_
  }
  if (!"validation_used" %in% names(metadata)) metadata[["validation_used"]] <- FALSE

  metadata %>%
    mutate(
      created_at_utc = as.POSIXct(created_at_utc, tz = "UTC"),
      validation_used = tidyr::replace_na(.data$validation_used, FALSE),
      validation_fit_data_file = dplyr::if_else(
        is.na(.data$validation_fit_data_file) | !nzchar(.data$validation_fit_data_file),
        infer_validation_fit_data_file(.data$geo_region, .data$metadata_sim_day_0),
        .data$validation_fit_data_file
      ),
      validation_used = .data$validation_used |
        (!is.na(.data$validation_fit_data_file) & nzchar(.data$validation_fit_data_file)),
      complete_pct   = round(100 * complete_realization_count /
                               pmax(attempt_realization_count, 1)),
      has_parquet    = file.exists(file.path(PARQUET_ROOT, scenario_hash,
                                             batch_num, "network.parquet"))
    )
}

load_scenario_features <- function() {
  if (!file.exists(FEATURES_PARQUET) || !requireNamespace("arrow", quietly = TRUE)) {
    return(tibble(
      scenario_hash = character(),
      geo_region = character(),
      feature_path = character(),
      feature_group = character(),
      feature_value = character(),
      feature_type = character()
    ))
  }

  arrow::read_parquet(FEATURES_PARQUET) %>%
    dplyr::mutate(
      scenario_hash = as.character(.data$scenario_hash),
      geo_region = as.character(.data$geo_region),
      feature_path = as.character(.data$feature_path),
      feature_group = as.character(.data$feature_group),
      feature_value = as.character(.data$feature_value),
      feature_type = as.character(.data$feature_type)
    )
}

parse_validation_json <- function(validation_json) {
  if (length(validation_json) == 0 || is.na(validation_json) || !nzchar(validation_json)) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(validation_json, simplifyVector = TRUE),
    error = function(e) NULL
  )
}

infer_validation_fit_data_file <- function(geo_region, sim_day_0) {
  candidate <- file.path(
    DATA_ROOT,
    "validation_fit_data",
    paste0("validation_fit_inc_hosp_", geo_region, "_", as.character(sim_day_0), ".csv")
  )
  dplyr::if_else(file.exists(candidate), candidate, NA_character_)
}

mmwr_week_end_date <- function(date) {
  date <- as.Date(date)
  date + ((6L - as.POSIXlt(date)$wday) %% 7L)
}

first_complete_mmwr_week_end <- function(sim_start_date) {
  sim_start_date <- as.Date(sim_start_date)
  first_sunday <- sim_start_date + ((7L - as.POSIXlt(sim_start_date)$wday) %% 7L)
  first_sunday + 6L
}

age_group_label <- function(age_group) {
  if (is.null(age_group) || length(age_group) == 0 || identical(age_group, "all")) {
    return("all")
  }
  age_group <- as.character(age_group[[1]])
  if (age_group %in% AGE_LABELS) {
    return(age_group)
  }
  age_index <- suppressWarnings(as.integer(age_group))
  if (!is.na(age_index) && age_index >= 0 && age_index < length(AGE_LABELS)) {
    return(AGE_LABELS[age_index + 1L])
  }
  NA_character_
}

age_group_index <- function(age_group) {
  label <- age_group_label(age_group)
  if (identical(label, "all") || is.na(label)) return(label)
  as.character(match(label, AGE_LABELS) - 1L)
}

split_metadata_tags <- function(x) {
  tags <- unlist(strsplit(paste(na.omit(x), collapse = "|"), "\\|"))
  tags <- trimws(tags)
  sort(unique(tags[nzchar(tags)]))
}

has_any_metadata_tag <- function(x, selected_tags) {
  vapply(
    x,
    function(value) length(intersect(split_metadata_tags(value), selected_tags)) > 0,
    logical(1)
  )
}

intervention_label <- function(vaccine_used, antiviral_used, npi_used) {
  dplyr::case_when(
    vaccine_used & antiviral_used & npi_used ~ "Vaccine + Antiviral + NPI",
    vaccine_used & antiviral_used            ~ "Vaccine + Antiviral",
    vaccine_used & npi_used                  ~ "Vaccine + NPI",
    antiviral_used & npi_used                ~ "Antiviral + NPI",
    vaccine_used                             ~ "Vaccine",
    antiviral_used                           ~ "Antiviral",
    npi_used                                 ~ "NPI",
    TRUE                                     ~ "None"
  )
}

scenario_selector_choices <- function(metadata, region) {
  if (length(region) != 1L || is.na(region)) return(stats::setNames(character(), character()))
  scenarios <- metadata %>%
    dplyr::filter(.data$has_parquet, .data$geo_region == .env$region) %>%
    dplyr::arrange(dplyr::desc(.data$created_at_utc)) %>%
    dplyr::distinct(.data$scenario_hash, .keep_all = TRUE)
  if (!nrow(scenarios)) return(stats::setNames(character(), character()))
  labels <- paste(intervention_label(scenarios$vaccine_used, scenarios$antiviral_used, scenarios$npi_used),
    paste0("R0=", round(scenarios$disease_R0, 2)), scenarios$disease_identity,
    substr(scenarios$scenario_hash, nchar(scenarios$scenario_hash) - 3, nchar(scenarios$scenario_hash)), sep = " | ")
  stats::setNames(scenarios$scenario_hash, labels)
}

INTERVENTION_LEVELS <- c(
  "None",
  "Antiviral",
  "NPI",
  "Vaccine",
  "Vaccine + Antiviral + NPI",
  "Antiviral + NPI",
  "Vaccine + NPI",
  "Vaccine + Antiviral"
)

INTERVENTION_COLORS <- c(
  "None" = "#4D4D4D",
  "Antiviral" = "#F28E2B",
  "NPI" = "#59A14F",
  "Vaccine" = "#4E79A7",
  "Vaccine + Antiviral + NPI" = "#B07AA1",
  "Antiviral + NPI" = "#9C755F",
  "Vaccine + NPI" = "#76B7B2",
  "Vaccine + Antiviral" = "#EDC948"
)

intervention_order <- function(interventions) {
  order_index <- match(interventions, INTERVENTION_LEVELS)
  ifelse(is.na(order_index), length(INTERVENTION_LEVELS) + 1L, order_index)
}

hash_suffix <- function(scenario_hash) {
  substr(scenario_hash, pmax(nchar(scenario_hash) - 3, 1), nchar(scenario_hash))
}

short_feature_name <- function(feature_path) {
  leaf <- stringr::str_replace(feature_path, "^.*\\.", "")
  label <- stringr::str_replace_all(leaf, "_", " ")
  prefix <- dplyr::case_when(
    stringr::str_starts(feature_path, "antiviral_model.") ~ "antiviral ",
    stringr::str_starts(feature_path, "vaccine_model.") ~ "vaccine ",
    stringr::str_starts(feature_path, "disease_model.") ~ "disease ",
    stringr::str_starts(feature_path, "travel_model.") ~ "travel ",
    stringr::str_starts(feature_path, "metadata_tags.experiment_controls.") ~ "experiment ",
    TRUE ~ ""
  )
  paste0(prefix, label)
}

short_feature_value <- function(value, max_chars = 42) {
  value <- as.character(value)
  value <- stringr::str_squish(value)
  dplyr::if_else(
    nchar(value) > max_chars,
    paste0(substr(value, 1, max_chars - 1), "…"),
    value
  )
}

NOISY_COMPARISON_PATHS <- c(
  "^cli_args\\.input_filename$",
  "^cli_args\\.loglevel$",
  "^data\\.",
  "^git_",
  "^metadata_tags\\.notes$",
  "^metadata_tags\\.validation\\.",
  "^random_seed\\.",
  "^random_",
  "^sim_loglevel$"
)

is_noisy_comparison_path <- function(feature_path) {
  purrr::map_lgl(
    feature_path,
    function(path) any(stringr::str_detect(path, NOISY_COMPARISON_PATHS))
  )
}

comparison_diff_paths <- function(feature_df, scenario_hashes) {
  if (nrow(feature_df) == 0 || length(scenario_hashes) <= 1) return(character(0))

  feature_df %>%
    dplyr::filter(
      .data$scenario_hash %in% scenario_hashes,
      !is_noisy_comparison_path(.data$feature_path)
    ) %>%
    dplyr::group_by(.data$feature_path) %>%
    dplyr::summarise(
      n_values = dplyr::n_distinct(.data$feature_value, na.rm = FALSE),
      n_hashes = dplyr::n_distinct(.data$scenario_hash),
      .groups = "drop"
    ) %>%
    dplyr::filter(.data$n_values > 1, .data$n_hashes > 1) %>%
    dplyr::arrange(.data$n_values, nchar(.data$feature_path), .data$feature_path) %>%
    dplyr::pull(.data$feature_path)
}

feature_path_priority <- function(feature_path) {
  dplyr::case_when(
    stringr::str_detect(feature_path, "age_risk_priority_groups") ~ 1L,
    stringr::str_detect(feature_path, "antiviral_adherence") ~ 2L,
    stringr::str_detect(feature_path, "^antiviral_model\\.parameters\\.") ~ 3L,
    stringr::str_detect(feature_path, "^antiviral_model\\.runtime_attributes\\.") ~ 4L,
    stringr::str_detect(feature_path, "^vaccine_model\\.parameters\\.") ~ 5L,
    stringr::str_detect(feature_path, "^vaccine_model\\.runtime_attributes\\.") ~ 6L,
    stringr::str_detect(feature_path, "metadata_tags\\.experiment") ~ 7L,
    stringr::str_detect(feature_path, "^disease_model\\.parameters\\.") ~ 8L,
    stringr::str_detect(feature_path, "^disease_model\\.runtime_attributes\\.") ~ 9L,
    stringr::str_detect(feature_path, "\\.identity$") ~ 10L,
    TRUE ~ 99L
  )
}

scenario_difference_summary <- function(feature_df, primary_hash, target_hash, max_features = 4) {
  if (primary_hash == target_hash || nrow(feature_df) == 0) return("Reference")

  primary_features <- feature_df %>%
    dplyr::filter(.data$scenario_hash == primary_hash, !is_noisy_comparison_path(.data$feature_path)) %>%
    dplyr::select("feature_path", primary_value = "feature_value")

  target_features <- feature_df %>%
    dplyr::filter(.data$scenario_hash == target_hash, !is_noisy_comparison_path(.data$feature_path)) %>%
    dplyr::select("feature_path", target_value = "feature_value")

  differences <- dplyr::full_join(primary_features, target_features, by = "feature_path") %>%
    dplyr::mutate(
      primary_value = dplyr::coalesce(.data$primary_value, "[missing]"),
      target_value = dplyr::coalesce(.data$target_value, "[missing]")
    ) %>%
    dplyr::filter(.data$primary_value != .data$target_value) %>%
    dplyr::mutate(priority = feature_path_priority(.data$feature_path)) %>%
    dplyr::arrange(.data$priority, nchar(.data$feature_path), .data$feature_path)

  if (nrow(differences) == 0) return("No indexed input differences")

  shown <- differences %>%
    dplyr::slice_head(n = max_features) %>%
    dplyr::mutate(
      label_piece = paste0(
        short_feature_name(.data$feature_path),
        ": ",
        short_feature_value(.data$target_value)
      )
    ) %>%
    dplyr::pull(.data$label_piece)

  extra_count <- nrow(differences) - length(shown)
  if (extra_count > 0) {
    shown <- c(shown, paste0("+", extra_count, " more"))
  }

  paste(shown, collapse = " | ")
}

scenario_difference_table <- function(feature_df, primary_hash, target_hash) {
  if (primary_hash == target_hash || nrow(feature_df) == 0) {
    return(tibble(
      Feature = "Reference scenario",
      Primary = "",
      Selected = ""
    ))
  }

  primary_features <- feature_df %>%
    dplyr::filter(.data$scenario_hash == primary_hash, !is_noisy_comparison_path(.data$feature_path)) %>%
    dplyr::select(feature_path = "feature_path", primary_value = "feature_value")

  target_features <- feature_df %>%
    dplyr::filter(.data$scenario_hash == target_hash, !is_noisy_comparison_path(.data$feature_path)) %>%
    dplyr::select(feature_path = "feature_path", target_value = "feature_value")

  differences <- dplyr::full_join(primary_features, target_features, by = "feature_path") %>%
    dplyr::mutate(
      primary_value = dplyr::coalesce(.data$primary_value, "[missing]"),
      target_value = dplyr::coalesce(.data$target_value, "[missing]")
    ) %>%
    dplyr::filter(.data$primary_value != .data$target_value) %>%
    dplyr::mutate(priority = feature_path_priority(.data$feature_path)) %>%
    dplyr::arrange(.data$priority, nchar(.data$feature_path), .data$feature_path)

  if (nrow(differences) == 0) {
    return(tibble(
      Feature = "No indexed input differences",
      Primary = "",
      Selected = ""
    ))
  }

  differences %>%
    dplyr::transmute(
      Feature = .data$feature_path,
      Primary = .data$primary_value,
      Selected = .data$target_value
    )
}

comparison_details <- function(rows, feature_df, max_features = 4) {
  hashes <- rows$scenario_hash
  hash_labels <- paste0("hash ", hash_suffix(hashes))
  names(hash_labels) <- hashes
  primary_hash <- hashes[[1]]
  summaries <- purrr::map_chr(
    hashes,
    ~ scenario_difference_summary(feature_df, primary_hash, .x, max_features)
  )

  tibble(
    scenario_hash = hashes,
    hash_label = unname(hash_labels),
    difference_summary = summaries
  )
}

resolve_validation_fit_data_file <- function(scenario_row, validation) {
  metadata_path <- scenario_row$validation_fit_data_file[[1]] %||% NA_character_
  if (!is.na(metadata_path) && nzchar(metadata_path) && file.exists(metadata_path)) {
    return(metadata_path)
  }
  if (!is.na(metadata_path) && nzchar(metadata_path)) {
    candidate <- if (grepl("^/", metadata_path)) metadata_path else file.path(DATA_ROOT, metadata_path)
    if (file.exists(candidate)) return(candidate)
  }

  tag_path <- validation$fit_data_file %||% NA_character_
  if (!is.na(tag_path) && nzchar(tag_path)) {
    candidate <- if (grepl("^/", tag_path)) tag_path else file.path(DATA_ROOT, tag_path)
    if (file.exists(candidate)) return(candidate)
  }

  NA_character_
}

validation_target <- function(validation) {
  target <- validation$target %||% NULL
  if (is.list(target)) {
    return(list(
      compartment = as.character(target$compartment %||% "H"),
      measure = as.character(target$measure %||% "incident"),
      label = as.character(target$label %||% "Incident hospitalizations"),
      observed_column = as.character(target$observed_column %||% "incident_hospitalizations")
    ))
  }

  list(
    compartment = "H",
    measure = "incident",
    label = if (!is.null(target) && nzchar(as.character(target))) as.character(target) else "Incident hospitalizations",
    observed_column = "incident_hospitalizations"
  )
}

validation_observed <- function(fit_data_file, age_group = "all", observed_column = "incident_hospitalizations") {
  if (is.na(fit_data_file) || !nzchar(fit_data_file) || !file.exists(fit_data_file)) return(NULL)
  
  selected_age_label <- age_group_label(age_group)
  if (is.na(selected_age_label)) return(NULL)

  observed_raw <- readr::read_csv(fit_data_file, show_col_types = FALSE)
  if (!observed_column %in% names(observed_raw)) return(NULL)

  observed <- observed_raw %>%
    dplyr::mutate(
      date = as.Date(.data$date),
      age_group = as.character(.data$age_group),
      observed_value = as.numeric(.data[[observed_column]])
    )

  if (nrow(observed) == 0) return(NULL)
  
  if (!identical(selected_age_label, "all")) {
    observed <- observed %>%
      dplyr::filter(.data$age_group == selected_age_label)
    if (nrow(observed) == 0) return(NULL)
  }

  observed %>%
    dplyr::group_by(.data$date) %>%
    dplyr::summarise(
      observed = sum(.data$observed_value, na.rm = TRUE),
      .groups = "drop"
    )
}

age_compartment_columns <- function(df, compartment, age_group) {
  column_names <- if (is.character(df)) df else names(df)
  if (identical(age_group, "all")) {
    if (compartment %in% column_names) return(compartment)
    pattern <- paste0("^", compartment, "_[HL]_[UV]_age[0-9]+$")
    return(grep(pattern, column_names, value = TRUE))
  }
  selected_age_index <- age_group_index(age_group)
  if (is.na(selected_age_index)) return(character(0))
  pattern <- paste0("^", compartment, "_[HL]_[UV]_age", selected_age_index, "$")
  grep(pattern, column_names, value = TRUE)
}

compartment_choices_from_columns <- function(column_names, include_s = TRUE) {
  compartments <- if (isTRUE(include_s)) COMPARTMENT_ORDER else setdiff(COMPARTMENT_ORDER, "S")
  has_compartment <- purrr::map_lgl(
    compartments,
    ~ .x %in% column_names || any(grepl(paste0("^", .x, "_[HL]_[UV]_age[0-9]+$"), column_names))
  )
  compartments[has_compartment]
}

validation_generated <- function(scenario_hash, sim_start_date, age_group = "all", compartment = "H") {
  column_names <- parquet_schema_names(scenario_hash, "nodes")
  if (is.null(column_names)) return(NULL)

  comp_columns <- age_compartment_columns(column_names, compartment, age_group)
  if (length(comp_columns) == 0) return(NULL)

  parquet_files <- scenario_parquet_files(scenario_hash, "nodes")
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  comp_expr <- paste0(
    "COALESCE(",
    as.character(DBI::dbQuoteIdentifier(con, comp_columns)),
    ", 0)"
  ) %>%
    paste(collapse = " + ")

  query <- paste0(
    "SELECT batch_num, sim_id, day, SUM(", comp_expr, ") AS comp_value ",
    "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
    "GROUP BY batch_num, sim_id, day ",
    "ORDER BY batch_num, sim_id, day"
  )

  df <- DBI::dbGetQuery(con, query)
  if (nrow(df) == 0) return(NULL)

  df %>%
    dplyr::arrange(.data$batch_num, .data$sim_id, .data$day) %>%
    dplyr::group_by(.data$batch_num, .data$sim_id) %>%
    dplyr::mutate(
      incident_value = pmax(.data$comp_value - dplyr::lag(.data$comp_value, default = dplyr::first(.data$comp_value)), 0),
      calendar_date = as.Date(sim_start_date) + .data$day,
      date = mmwr_week_end_date(.data$calendar_date)
    ) %>%
    dplyr::group_by(.data$date, .data$batch_num, .data$sim_id) %>%
    dplyr::summarise(
      incident_value = sum(.data$incident_value, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::group_by(.data$date) %>%
    dplyr::summarise(
      generated_median = stats::median(.data$incident_value, na.rm = TRUE),
      generated_lo = stats::quantile(.data$incident_value, 0.05, na.rm = TRUE),
      generated_hi = stats::quantile(.data$incident_value, 0.95, na.rm = TRUE),
      .groups = "drop"
    )
}

parquet_query <- function(batch_num, type = c("network", "nodes")) {
  type      <- match.arg(type)
  parquet   <- Sys.glob(file.path(PARQUET_ROOT, "*", batch_num,
                                  paste0(type, ".parquet")))
  if (length(parquet) == 0) return(NULL)
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", parquet[[1]]))
}

scenario_parquet_files <- function(scenario_hash, type = c("network", "nodes")) {
  type <- match.arg(type)
  Sys.glob(
    file.path(PARQUET_ROOT, scenario_hash, "*", paste0(type, ".parquet"))
  )
}

parquet_file_array_sql <- function(con, parquet_files) {
  paste0(
    "[",
    paste(DBI::dbQuoteString(con, parquet_files), collapse = ", "),
    "]"
  )
}

parquet_schema_names <- function(scenario_hash, type = c("network", "nodes")) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  names(DBI::dbGetQuery(
    con,
    paste0(
      "SELECT * FROM read_parquet(",
      parquet_file_array_sql(con, parquet_files),
      ") LIMIT 0"
    )
  ))
}

parquet_query_scenario <- function(scenario_hash, type = c("network", "nodes"), columns = NULL) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  select_sql <- if (is.null(columns)) {
    "*"
  } else {
    paste(as.character(DBI::dbQuoteIdentifier(con, unique(columns))), collapse = ", ")
  }

  query <- paste0(
    "SELECT ", select_sql, " FROM read_parquet(",
    parquet_file_array_sql(con, parquet_files),
    ")"
  )

  DBI::dbGetQuery(con, query)
}

scenario_compartment_timeseries <- function(scenario_hash, type = c("network", "nodes"), comp_columns) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0 || length(comp_columns) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  value_expr <- paste0(
    "COALESCE(",
    as.character(DBI::dbQuoteIdentifier(con, comp_columns)),
    ", 0)"
  ) %>%
    paste(collapse = " + ")

  if (identical(type, "nodes")) {
    query <- paste0(
      "SELECT batch_num, sim_id, day, SUM(", value_expr, ") AS value ",
      "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
      "GROUP BY batch_num, sim_id, day ",
      "ORDER BY batch_num, sim_id, day"
    )
  } else {
    query <- paste0(
      "SELECT batch_num, sim_id, day, (", value_expr, ") AS value ",
      "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
      "ORDER BY batch_num, sim_id, day"
    )
  }

  DBI::dbGetQuery(con, query)
}

# County maps use the same boundaries, YlOrRd palette and log1p scale as
# TACC/PandemicExerciseTool/frontend. Population comes from this project's
# existing county-by-age CSV, never from the frontend's population assets.
county_map_geometry <- function(region, geojson_url = NULL) {
  path <- file.path(MAP_ASSET_ROOT, "map_boundaries", paste0(region, "_counties_2023.geojson"))
  if (!file.exists(path)) stop("County boundaries were not included in this deployment for ", region,
    ". Republish the app with data/dashboard_map_assets included in Project Files.")
  geo <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  counties <- tibble::tibble(
    fips = vapply(geo$features, function(f) f$properties$GEOID, character(1)),
    county = vapply(geo$features, function(f) f$properties$NAMELSAD %||% f$properties$NAME, character(1))
  )
  # Center across the antimeridian for Alaska rather than over the Atlantic.
  xy <- matrix(unlist(lapply(geo$features, function(f) f$geometry$coordinates)), ncol = 2, byrow = TRUE)
  lon <- xy[, 1]
  if (diff(range(lon)) > 180) lon[lon > 0] <- lon[lon > 0] - 360
  center <- list(lon = mean(range(lon)), lat = mean(range(xy[, 2])))
  span <- max(diff(range(lon)), diff(range(xy[, 2])) / cos(center$lat * pi / 180), 0.05)
  list(geojson = if (is.null(geojson_url)) geo else geojson_url,
       counties = counties, center = center, zoom = log2(360 / span) - 0.3,
       bounds = list(c(min(lon), min(xy[, 2])), c(max(lon), max(xy[, 2]))))
}

county_map_population <- function(metadata_row, age_group) {
  region <- metadata_row$geo_region[[1]]
  recorded <- as.character(metadata_row$data_population[[1]])
  if (is.na(recorded) || !nzchar(recorded)) stop("This scenario has no population input recorded.")
  candidates <- c(
    file.path(DATA_ROOT, recorded), file.path(PROJECT_ROOT, recorded), recorded,
    file.path(DATA_ROOT, "map_population", basename(recorded)),
    file.path(PROJECT_ROOT, "data", region, basename(recorded))
  )
  path <- candidates[file.exists(candidates)][1]
  if (is.na(path)) stop("County population input is unavailable: ", basename(recorded))
  pop <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_double(), fips = readr::col_character()),
                         show_col_types = FALSE)
  age_columns <- if (identical(age_group, "all")) AGE_LABELS else age_group_label(age_group)
  if (!all(c("fips", age_columns) %in% names(pop))) stop("Population input lacks the selected age group.")
  tibble::tibble(fips = sprintf("%05d", as.integer(pop$fips)),
                 population = rowSums(as.data.frame(pop[age_columns])))
}

county_map_runs <- function(scenario_hash) {
  paths <- scenario_parquet_files(scenario_hash, "nodes")
  if (!length(paths)) return(tibble::tibble(batch_num = character(), sim_id = character()))
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, paste0("SELECT DISTINCT batch_num, CAST(sim_id AS VARCHAR) AS sim_id FROM read_parquet(",
    parquet_file_array_sql(con, paths), ") ORDER BY batch_num, CAST(sim_id AS BIGINT)"))
}

county_map_query <- function(path, sim_id, value_columns) {
  if (!file.exists(path)) stop("County simulation file is unavailable.")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "SET threads = 1")
  DBI::dbExecute(con, "SET memory_limit = '128MB'")
  expression <- paste0("COALESCE(", DBI::dbQuoteIdentifier(con, value_columns), ", 0)", collapse = " + ")
  # Keep one realization in memory; day changes only slice this small result.
  df <- DBI::dbGetQuery(con, paste0(
    "SELECT CAST(fips_id AS VARCHAR) AS fips, day, SUM(", expression, ") AS count ",
    "FROM read_parquet(", DBI::dbQuoteString(con, path), ") WHERE sim_id = CAST(",
    DBI::dbQuoteString(con, as.character(sim_id)), " AS BIGINT) GROUP BY fips_id, day ORDER BY day, fips_id"))
  df$fips <- sprintf("%05d", as.integer(df$fips))
  df
}
environment(county_map_query) <- baseenv()

county_map_timeseries <- function(scenario_hash, batch_num, sim_id, compartment, age_group) {
  columns <- parquet_schema_names(scenario_hash, "nodes")
  value_columns <- age_compartment_columns(columns, compartment, age_group)
  if (!length(value_columns)) stop("No county data for this compartment and age group.")
  county_map_query(file.path(PARQUET_ROOT, scenario_hash, batch_num, "nodes.parquet"), sim_id, value_columns)
}

# One separate R worker per app process, shared across visitors. I(1) prevents
# future from falling back to synchronous execution on a single-core host.
start_county_map_worker <- local({
  started <- FALSE
  function() {
    if (!started) {
      future::plan(future::multisession, workers = I(1))
      started <<- TRUE
    }
  }
})

county_map_background_loader <- function(map_request, map_cache, query_fn = county_map_query) {
  cache_key <- function(key) digest::digest(key, algo = "xxhash64")
  map_request_debounced <- debounce(map_request, 200)
  map_pending <- reactiveVal(NULL)
  map_value <- reactiveVal(NULL)
  map_invoked_key <- reactiveVal(NULL)
  map_task <- ExtendedTask$new(function(request) {
    start_county_map_worker()
    promises::future_promise({
      list(key = request$key, data = query(request$path, request$sim_id, request$columns))
    }, globals = list(request = request, query = query_fn), packages = c("DBI", "duckdb"))
  })
  launch_pending_map <- function() {
    request <- isolate(map_pending())
    if (is.null(request)) return()
    cached <- map_cache$get(cache_key(request$key))
    if (!cachem::is.key_missing(cached)) {
      map_value(list(key = request$key, data = cached, error = NULL))
    } else if (!identical(isolate(map_task$status()), "running")) {
      map_invoked_key(request$key)
      map_task$invoke(request)
    }
  }
  observeEvent(map_request_debounced(), {
    map_pending(map_request_debounced())
    launch_pending_map()
  })
  observeEvent(map_task$status(), {
    status <- map_task$status()
    if (status == "success") {
      value <- map_task$result()
      map_cache$set(cache_key(value$key), value$data)
      launch_pending_map()
    } else if (status == "error") {
      error <- tryCatch(map_task$result(), error = identity)
      pending <- isolate(map_pending())
      if (!is.null(pending) && identical(pending$key, isolate(map_invoked_key()))) {
        map_value(list(key = pending$key, error = conditionMessage(error)))
      } else launch_pending_map()
    }
  })
  list(value = map_value, task = map_task)
}

county_map_frame <- function(series, counties, population, day, measure, format_hover = TRUE) {
  frame <- counties %>%
    dplyr::left_join(dplyr::filter(series, .data$day == .env$day), by = "fips") %>%
    dplyr::left_join(population, by = "fips") %>%
    dplyr::mutate(percent = dplyr::if_else(.data$population > 0, 100 * .data$count / .data$population, NA_real_))
  values <- if (identical(measure, "percent")) frame$percent else frame$count
  frame$z <- log1p(pmax(values, 0))
  if (!format_hover) return(frame)
  number <- function(x) ifelse(is.finite(x), format(round(x, 1), big.mark = ",", trim = TRUE), "unavailable")
  frame$text <- paste0("<b>", htmltools::htmlEscape(frame$county), "</b><br>FIPS: ", frame$fips,
    "<br>Count: ", number(frame$count), "<br>Percent of selected population: ", number(frame$percent),
    "%<br>Selected population: ", number(frame$population))
  frame$text[is.na(frame$count)] <- paste0("<b>", htmltools::htmlEscape(frame$county[is.na(frame$count)]),
                                         "</b><br>No simulation data")
  frame
}

county_map_figure <- function(geometry, frame, population, measure, title, revision) {
  raw_max <- if (identical(measure, "percent")) 100 else max(c(1, population$population), na.rm = TRUE)
  ticks <- c(0, 10 ^ seq.int(0, floor(log10(raw_max))))
  # Grey base distinguishes counties with missing simulation records from zeros.
  plotly::plot_ly() %>%
    plotly::add_trace(type = "choroplethmapbox", geojson = geometry$geojson,
      locations = geometry$counties$fips, featureidkey = "properties.GEOID",
      z = rep(0, nrow(geometry$counties)), colorscale = list(c(0, "#eeeeee"), c(1, "#eeeeee")),
      showscale = FALSE, hoverinfo = "skip", marker = list(line = list(width = 0.5, color = "darkgray"))) %>%
    plotly::add_trace(type = "choroplethmapbox", geojson = geometry$geojson,
      locations = frame$fips, featureidkey = "properties.GEOID", z = frame$z,
      zmin = 0, zmax = log1p(raw_max), autocolorscale = FALSE, reversescale = FALSE,
      colorscale = list(c(0, "#ffffcc"), c(0.25, "#fed976"), c(0.5, "#fd8d3c"),
                        c(0.75, "#e31a1c"), c(1, "#800026")),
      customdata = as.matrix(frame[c("count", "percent", "population")]),
      hovertemplate = paste0("<b>%{properties.NAMELSAD}</b><br>FIPS: %{location}",
        "<br>Count: %{customdata[0]:,.1f}<br>Percent of selected population: %{customdata[1]:.2f}%",
        "<br>Selected population: %{customdata[2]:,.0f}<extra></extra>"),
      marker = list(opacity = 0.8, line = list(width = 0.5, color = "darkgray")),
      colorbar = list(title = list(text = if (measure == "percent") "Percent of population" else "Count"),
        tickvals = log1p(ticks), ticktext = format(ticks, big.mark = ",", trim = TRUE, scientific = FALSE), thickness = 15)) %>%
    plotly::layout(title = list(text = title), showlegend = FALSE,
      # The R Plotly binding calls fitBounds on map creation; supply valid bounds
      # explicitly (4.10.x otherwise attempts to fit an undefined bounding box).
      mapbox = list(style = "white-bg", center = geometry$center, zoom = geometry$zoom,
        `_fitBounds` = list(bounds = geometry$bounds, options = list(padding = 35))),
      uirevision = revision, margin = list(l = 0, r = 0, t = 55, b = 10), paper_bgcolor = "white")
}

export_batch <- function(batch_num, tmp_dir) {
  source(file.path(PROJECT_ROOT, "scripts", "7_process_output_to_db.R"),
         local = new.env())
  # Call the export function defined in the ETL script
  env <- new.env()
  env$PARQUET_ROOT <- PARQUET_ROOT
  source(file.path(PROJECT_ROOT, "scripts", "7_process_output_to_db.R"),
         local = env)
  env$export_batch_csv(batch_num, tmp_dir)
}

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- page_navbar(
  id = "dashboard_tab",
  title = "Pandemic Sim Explorer",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  header = tags$head(
    tags$style(HTML("
      .county-map-stage { position: relative; min-height: 550px; }
      .county-map-loading {
        position: absolute;
        inset: 0;
        z-index: 5;
        display: none;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 0.75rem;
        padding: 2rem;
        text-align: center;
        background: rgba(255, 255, 255, 0.95);
        color: #2c3e50;
      }
      .county-map-stage:has(#county_map:empty) .county-map-loading,
      .county-map-stage:has(#county_map.recalculating) .county-map-loading,
      .county-map-loading.map-async-loading { display: flex; }

      .map-timeline {
        padding: 0 2.75rem 0.5rem 0;
      }

      .map-timeline .shiny-input-container {
        display: grid;
        grid-template-columns: 7.5rem minmax(0, 1fr);
        column-gap: 1rem;
        width: 100%;
        margin-bottom: 0;
      }

      .map-timeline .control-label {
        grid-column: 2;
        grid-row: 1;
      }

      .map-timeline .irs {
        grid-column: 2;
        grid-row: 2;
        min-width: 0;
      }

      .map-timeline .slider-animate-container {
        grid-column: 1;
        grid-row: 2;
        align-self: center;
        margin: 0;
        text-align: left;
      }

      .map-timeline .slider-animate-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 7.5rem;
        min-height: 3.25rem;
        padding: 0.6rem 0.75rem;
        border: 2px solid #0f5132;
        border-radius: 0.5rem;
        background: #146c43;
        color: #ffffff;
        opacity: 1;
        font-size: 1rem;
        font-weight: 800;
        text-decoration: none;
      }

      .map-timeline .slider-animate-button:hover {
        background: #0f5132;
      }

      .map-timeline .slider-animate-button.playing {
        background: #e0a800;
        border-color: #997300;
        color: #202a35;
      }

      .map-timeline .slider-animate-button.playing:hover {
        background: #c99700;
      }

      .map-timeline .slider-animate-button:focus-visible {
        outline: 3px solid #202a35;
        outline-offset: 3px;
      }

      .map-timeline .slider-animate-button svg {
        margin-right: 0.35rem;
        vertical-align: -0.1em;
      }

      .scenario-table-card .card-body {
        padding-top: 0.5rem;
      }

      .scenario-table-toolbar {
        align-items: center;
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem 0.75rem;
        justify-content: space-between;
        margin-bottom: 0.35rem;
      }

      .scenario-table-toolbar .dt-buttons,
      .scenario-table-toolbar .dataTables_filter {
        float: none;
        margin: 0;
      }

      .scenario-table-toolbar .dataTables_filter label {
        align-items: center;
        display: flex;
        gap: 0.45rem;
        margin: 0;
      }

      .scenario-table-toolbar .dataTables_filter input {
        margin-left: 0;
        min-width: 18rem;
      }

      .scenario-table-info {
        font-size: 0.8rem;
        padding-top: 0.3rem;
      }

      .scenario-table-card table.dataTable {
        margin-top: 0 !important;
      }

      .validation-card-header {
        align-items: center;
        display: flex;
        gap: 0.5rem;
        justify-content: space-between;
      }

      .validation-card-header .btn {
        font-size: 0.8rem;
        padding: 0.2rem 0.55rem;
      }

      @media (max-width: 768px) {
        .scenario-table-toolbar {
          align-items: stretch;
        }

        .scenario-table-toolbar .dataTables_filter,
        .scenario-table-toolbar .dataTables_filter label,
        .scenario-table-toolbar .dataTables_filter input {
          width: 100%;
        }

        .scenario-table-toolbar .dataTables_filter input {
          min-width: 0;
        }
      }
    "))
  ),

  # ── Scenarios tab ──────────────────────────────────────────────────────────
  nav_panel(
    "Scenarios",
    icon = bs_icon("table"),

    page_sidebar(
      sidebar = sidebar(
        width = 280,
        accordion(
          open = TRUE,

          accordion_panel(
            "Geography & Model",
            icon = bs_icon("geo-alt"),
            selectizeInput("filter_region", "Region",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All regions")),
            selectizeInput("filter_disease", "Disease model",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All models")),
            selectizeInput("filter_metadata_disease", "Disease tag",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All disease tags")),
            selectizeInput("filter_metadata_creator", "Creator",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All creators"))
          ),

          accordion_panel(
            "Interventions",
            icon = bs_icon("capsule"),
            input_switch("filter_vaccine",    "Vaccination",        FALSE),
            input_switch("filter_antiviral",  "Antivirals",         FALSE),
            input_switch("filter_npi",        "Non-pharmaceutical", FALSE),
            input_switch("filter_complete",   "All simulations complete", FALSE)
          ),

          accordion_panel(
            "File Creation Date range",
            icon = bs_icon("calendar3"),
            dateRangeInput("filter_dates", NULL,
                           start = Sys.Date() - 90, end = Sys.Date() + 1)
          )
        ),

        hr(),
        actionButton("refresh_btn", "Refresh data",
                     icon = icon("rotate"), class = "btn-outline-secondary w-100"),
        hr(),

        # Export panel — appears when rows are selected
        conditionalPanel(
          condition = "output.has_selection",
          div(
            class = "d-grid gap-2",
            downloadButton("export_meta_btn",  "Export metadata CSV",
                           class = "btn-outline-primary"),
            downloadButton("export_sims_btn",  "Export simulation CSVs",
                           class = "btn-outline-primary"),
            helpText("Simulation export requires Parquet files to exist.",
                     style = "font-size:0.75rem; color:#6c757d")
          )
        )
      ),

      # ── Summary row ─────────────────────────────────────────────────────────
      layout_column_wrap(
        width = "200px", fill = FALSE,
        value_box("Batches shown",       textOutput("n_batches_shown"),
                  theme = "primary",     showcase = bs_icon("stack")),
        value_box("Regions",             textOutput("n_regions_shown"),
                  theme = "info",        showcase = bs_icon("geo-alt")),
        value_box("Total realizations",  textOutput("n_real_shown"),
                  theme = "success",     showcase = bs_icon("activity")),
        value_box("With Parquet",        textOutput("n_parquet_shown"),
                  theme = "secondary",   showcase = bs_icon("database"))
      ),

      # ── Batch table ──────────────────────────────────────────────────────────
      card(
        class = "scenario-table-card",
        full_screen = TRUE,
        card_header(
          "Simulation batches",
          tooltip(bs_icon("info-circle", title = "Table info"),
                  "Click rows to select and enable data export. Filter to limit network time series previews in \"Network preview\" tab.")
        ),
        DTOutput("batch_table"),
        card_footer(
          "Completion = complete / attempted realizations.  ",
          "🟢 Parquet available   🔴 Parquet missing"
        )
      )
    )
  ),

  # ── Preview tab ─────────────────────────────────────────────────────────────
  nav_panel(
    "Network preview",
    icon = bs_icon("graph-up"),
    page_sidebar(
      sidebar = sidebar(
        width = 250,
        selectInput("preview_region", "State", choices = NULL),
        selectInput("preview_age_group", "Age group", choices = AGE_CHOICES, selected = "all"),
        selectizeInput(
          "preview_scenario",
          "Scenario",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one scenario")
        ),
        selectInput("preview_compartment", "Compartment",
                    choices = NULL),
        helpText("Shows network-level time series across all realizations.")
      ),
      card(
        full_screen = TRUE,
        card_header("Network time series"),
        plotly::plotlyOutput("network_plot", height = "450px")
        #plotOutput("network_plot", height = "450px")
      )
    )
  ),

  nav_panel(
    "County map",
    value = "county-map",
    icon = bs_icon("map"),
    page_sidebar(
      sidebar = sidebar(
        width = 250,
        selectInput("map_region", "State", choices = NULL),
        selectInput("map_age_group", "Age group", choices = AGE_CHOICES, selected = "all"),
        selectizeInput("map_scenario", "Scenario", choices = NULL),
        selectInput("map_compartment", "Compartment", choices = NULL),
        selectInput("map_run", "Simulation", choices = NULL),
        radioButtons("map_measure", "Display", choices = c("Count" = "count", "Percentage" = "percent"),
                     selected = "count", inline = TRUE),
        helpText("Percentages use the selected age group's county population. Each map shows one simulation."),
        helpText("Colors use a logarithmic scale fixed across days. Gray counties have no simulation data.")
      ),
      card(
        full_screen = TRUE,
        card_header("County epidemic map"),
        div(class = "county-map-stage",
          uiOutput("map_load_status"),
          div(id = "county_map_loading", class = "county-map-loading", role = "status", `aria-live` = "polite",
            div(class = "spinner-border text-success", `aria-hidden` = "true"),
            tags$strong("Loading county map"),
            tags$p("County boundaries and simulation data may take time to load, especially for larger states.")
          ),
          plotly::plotlyOutput("county_map", height = "550px"),
          textOutput("map_totals")
        ),
        helpText("County boundaries and simulation data may take time to load, especially for larger states."),
        tags$script(HTML("Shiny.addCustomMessageHandler('prefetch-county-boundaries', function(message) {
          var prefetch = function() {
            var link = document.createElement('link');
            link.rel = 'prefetch'; link.as = 'fetch'; link.href = message.url;
            link.setAttribute('fetchpriority', 'low'); document.head.appendChild(link);
          };
          if (window.requestIdleCallback) requestIdleCallback(prefetch); else setTimeout(prefetch, 1500);
        });
        $(document).on('shiny:inputchanged.pauseCountyMap', function(event) {
          if (event.name === 'dashboard_tab' && event.value !== 'county-map') {
            var playing = document.querySelector('.map-timeline .slider-animate-button.playing');
            if (playing) playing.click();
          }
        });")),
        div(class = "map-timeline",
          sliderInput("map_day", "Simulation day", min = 0, max = 1, value = 0, step = 1,
            animate = animationOptions(interval = 600, loop = FALSE,
              playButton = tagList(bs_icon("play-fill"), "PLAY"),
              pauseButton = tagList(bs_icon("pause-fill"), "PAUSE")), width = "100%")
        )
      )
    )
  ),

  # ── Validation tab ─────────────────────────────────────────────────────────
  nav_panel(
    "Validation",
    icon = bs_icon("clipboard2-pulse"),
    page_sidebar(
      sidebar = sidebar(
        width = 280,
        selectizeInput(
          "validation_region",
          "Region",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one region")
        ),
        selectizeInput(
          "validation_primary_scenario",
          "Primary scenario",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one scenario")
        ),
        selectizeInput(
          "validation_compare_scenarios",
          "Compare scenarios",
          choices = NULL,
          multiple = TRUE,
          options = list(
            maxItems = 9,
            placeholder = "Optional, up to 9 more"
          )
        ),
        selectInput("validation_compartment", "Compartment",
                    choices = "H",
                    selected = "H"),
        selectInput("validation_age_group", "Age group",
                    choices = AGE_CHOICES,
                    selected = "all"),
        helpText("Table filters constrain available comparison scenarios. The primary scenario supplies the observed validation dots.")
      ),
      card(
        full_screen = TRUE,
        card_header("Validation comparison"),
        plotly::plotlyOutput("validation_plot", height = "500px")
      ),
      card(
        full_screen = TRUE,
        card_header(
          div(
            class = "validation-card-header",
            span("Comparison summary"),
            downloadButton("download_validation_summary", "CSV", class = "btn-sm btn-outline-secondary")
          )
        ),
        DTOutput("validation_summary_table")
      ),
      card(
        full_screen = TRUE,
        card_header(
          div(
            class = "validation-card-header",
            span("Validation data"),
            downloadButton("download_validation_data", "CSV", class = "btn-sm btn-outline-secondary")
          )
        ),
        DTOutput("validation_table")
      )
    )
  ),

  # ── About tab ────────────────────────────────────────────────────────────────
  nav_panel(
    "About",
    icon = bs_icon("info-circle"),
    card(
      card_header("Data paths"),
      verbatimTextOutput("paths_info")
    ),
    card(
      card_header("Export instructions"),
      markdown("
**To ingest new simulation output:**
```r
source('scripts/7_process_output_to_db.R')
```

**To export a specific batch to CSV from R:**
```r
source('scripts/7_process_output_to_db.R')
export_batch_csv('<batch_num>', 'path/to/output/')
```

**Dashboard sub-population column naming convention:**

Node files contain stratified compartments in the form `{compartment}_{risk}_{vax}_{age}`:
- **risk**: H = high-risk, L = low-risk
- **vax**:  U = unvaccinated, V = vaccinated
- **age**:  age0 = 0–4, age1 = 5–17, age2 = 18–49, age3 = 50–64, age4 = 65+

Example: `IS_H_U_age4` = symptomatic infectious, high-risk, unvaccinated, 65+
      ")
    )
  )
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  # Reactive metadata (re-loads on refresh)
  meta <- reactiveVal(load_metadata())
  scenario_features <- reactiveVal(load_scenario_features())
  selected_diff_hash <- reactiveVal(NULL)
  map_active <- reactive(identical(input$dashboard_tab, "county-map"))
  map_revision <- reactiveVal(0L)
  map_cache <- cachem::cache_mem(max_size = 32 * 1024^2, max_n = 12)
  session$onFlushed(function() {
    regions <- sort(unique(isolate(meta())$geo_region))
    region <- if ("Texas" %in% regions) "Texas" else head(regions, 1)
    if (length(region)) session$sendCustomMessage("prefetch-county-boundaries",
      list(url = paste0("county-boundaries/", region, "_counties_2023.geojson")))
  }, once = TRUE)

  map_metadata <- reactive({
    req(map_active())
    filtered() %>% dplyr::filter(.data$has_parquet) %>%
      dplyr::arrange(dplyr::desc(.data$created_at_utc))
  })
  observe({
    regions <- sort(unique(map_metadata()$geo_region))
    selected <- intersect(isolate(input$map_region), regions)
    if (!length(selected)) selected <- if ("Texas" %in% regions) "Texas" else head(regions, 1)
    updateSelectInput(session, "map_region", choices = regions, selected = selected)
  })
  observe({
    req(input$map_region)
    choices <- scenario_selector_choices(map_metadata(), input$map_region)
    selected <- intersect(isolate(input$map_scenario), unname(choices))
    if (!length(selected)) selected <- head(unname(choices), 1)
    updateSelectizeInput(session, "map_scenario", choices = choices, selected = selected, server = TRUE)
  })
  map_runs <- reactive({
    req(map_active())
    req(input$map_scenario)
    county_map_runs(input$map_scenario)
  }) %>% bindCache({ req(map_active(), input$map_scenario); list(input$map_scenario, map_revision()) }, cache = map_cache)
  observe({
    runs <- map_runs()
    keys <- paste(runs$batch_num, runs$sim_id, sep = "::")
    labels <- paste0("Sim ", runs$sim_id, " | batch ", substr(runs$batch_num, nchar(runs$batch_num) - 3,
                                                                            nchar(runs$batch_num)))
    selected <- intersect(isolate(input$map_run), keys)
    if (!length(selected)) selected <- head(keys, 1)
    updateSelectInput(session, "map_run", choices = stats::setNames(keys, labels), selected = selected)
  })
  observe({
    req(map_active(), input$map_scenario)
    columns <- parquet_schema_names(input$map_scenario, "nodes")
    choices <- compartment_choices_from_columns(columns)
    selected <- intersect(isolate(input$map_compartment), choices)
    if (!length(selected)) selected <- if ("IS" %in% choices) "IS" else head(choices, 1)
    updateSelectInput(session, "map_compartment", choices = choices, selected = selected)
  })
  map_selection <- reactive({
    req(map_active())
    req(input$map_region, input$map_scenario, input$map_run)
    runs <- map_runs()
    run <- runs[paste(runs$batch_num, runs$sim_id, sep = "::") == input$map_run, , drop = FALSE]
    req(nrow(run) == 1)
    metadata <- map_metadata() %>% dplyr::filter(.data$scenario_hash == input$map_scenario,
      .data$batch_num == run$batch_num[[1]], .data$geo_region == input$map_region)
    req(nrow(metadata) > 0)
    list(run = run, metadata = metadata[1, , drop = FALSE])
  })
  map_geometry <- reactive({
    req(map_active(), input$map_region)
    withProgress(message = "Loading county boundaries", detail = "Map data may take time to load.", {
      tryCatch(county_map_geometry(input$map_region,
        paste0("county-boundaries/", input$map_region, "_counties_2023.geojson")),
        error = function(e) validate(need(FALSE, conditionMessage(e))))
    })
  }) %>% bindCache({ req(map_active(), input$map_region); list(input$map_region, MAP_ASSET_ROOT, map_revision()) }, cache = map_cache)
  map_population <- reactive({
    req(input$map_age_group)
    tryCatch(county_map_population(map_selection()$metadata, input$map_age_group),
             error = function(e) validate(need(FALSE, conditionMessage(e))))
  })
  map_request <- reactive({
    req(map_active(), input$map_compartment, input$map_age_group)
    selected <- map_selection()
    columns <- age_compartment_columns(parquet_schema_names(input$map_scenario, "nodes"),
                                       input$map_compartment, input$map_age_group)
    validate(need(length(columns), "No county data for this compartment and age group."))
    list(key = paste("series", input$map_scenario, input$map_run, input$map_compartment,
                     input$map_age_group, map_revision(), sep = ":"),
         path = file.path(PARQUET_ROOT, input$map_scenario, selected$run$batch_num[[1]], "nodes.parquet"),
         sim_id = selected$run$sim_id[[1]], columns = columns)
  })
  map_loader <- county_map_background_loader(map_request, map_cache)
  map_series <- reactive({
    req(map_active())
    request <- map_request()
    value <- map_loader$value()
    req(!is.null(value), identical(value$key, request$key))
    validate(need(is.null(value$error), value$error))
    value$data
  })
  output$map_load_status <- renderUI({
    req(map_active())
    request <- map_request()
    value <- map_loader$value()
    if (is.null(value) || !identical(value$key, request$key)) {
      div(class = "county-map-loading map-async-loading", role = "status", `aria-live` = "polite",
        div(class = "spinner-border text-success", `aria-hidden` = "true"),
        tags$strong("Loading county data in the background"),
        tags$p("You can use the other tabs while this loads."))
    }
  })
  observeEvent(map_series(), {
    days <- sort(unique(map_series()$day))
    req(length(days) > 0)
    selected <- isolate(input$map_day)
    if (is.null(selected) || !selected %in% days) selected <- days[[1]]
    updateSliderInput(session, "map_day", min = min(days), max = max(days), value = selected, step = 1)
  })
  map_frame <- reactive({
    req(map_active(), input$map_day, input$map_measure)
    county_map_frame(map_series(), map_geometry()$counties, map_population(), input$map_day,
                     input$map_measure, format_hover = FALSE)
  })
  output$county_map <- plotly::renderPlotly({
    req(map_active())
    geometry <- map_geometry()
    frame <- geometry$counties
    frame$z <- 0
    frame$count <- frame$percent <- frame$population <- 0
    county_map_figure(geometry, frame, data.frame(population = 1), "count", input$map_region,
      input$map_region) %>% plotly::config(displaylogo = FALSE) %>%
      htmlwidgets::onRender("function(el, x) {
        var region = x.layout.uirevision;
        var ready = function() { Shiny.setInputValue('map_ready', region, {priority: 'event'}); };
        Promise.all(el._promises || []).then(ready);
      }")
  })
  # Keep a single map per state. Recreating Mapbox during a restyle races with
  # its WebGL cleanup in older Plotly versions; every other control uses proxies.
  observe({
    req(map_active(), identical(input$map_ready, input$map_region))
    frame <- map_frame()
    population <- map_population()
    raw_max <- if (input$map_measure == "percent") 100 else max(c(1, population$population), na.rm = TRUE)
    ticks <- c(0, 10 ^ seq.int(0, floor(log10(raw_max))))
    plotly::plotlyProxy("county_map", session) %>%
      plotly::plotlyProxyInvoke("update", list(locations = list(frame$fips),
        z = list(frame$z), customdata = list(as.matrix(frame[c("count", "percent", "population")])),
        zmax = log1p(raw_max),
        "colorbar.title.text" = if (input$map_measure == "percent") "Percent of population" else "Count",
        "colorbar.tickvals" = list(log1p(ticks)),
        "colorbar.ticktext" = list(format(ticks, big.mark = ",", trim = TRUE, scientific = FALSE))),
        list("title.text" = paste(input$map_region,
          if (input$map_age_group == "all") "All ages" else age_group_label(input$map_age_group),
          input$map_compartment, sep = " | ")), 1L)
  })
  output$map_totals <- renderText({
    frame <- map_frame()
    present <- !is.na(frame$count)
    validate(need(any(present), "No county records for this day."))
    count <- sum(frame$count[present])
    population <- frame$population[present]
    percentage <- if (all(is.finite(population)) && sum(population) > 0) {
      sprintf("%.2f%%", 100 * count / sum(population))
    } else "percentage unavailable"
    sprintf("Day %s | %s: %s | %s of selected population | %s counties with data",
      input$map_day, input$map_compartment, format(round(count, 1), big.mark = ",", trim = TRUE),
      percentage, sum(present))
  })

  observeEvent(input$refresh_btn, {
    map_revision(isolate(map_revision()) + 1L)
    meta(load_metadata())
    scenario_features(load_scenario_features())
    showNotification("Data refreshed.", type = "message", duration = 2)
  })

  # Populate filter dropdowns from data
  observe({
    df_all <- meta()
    
    updateSelectizeInput(
      session, "filter_region",
      choices = sort(unique(df_all$geo_region)),
      selected = isolate(input$filter_region),
      server = TRUE
    )
    
    updateSelectizeInput(
      session, "filter_disease",
      choices = sort(unique(df_all$disease_identity)),
      selected = isolate(input$filter_disease),
      server = TRUE
    )

    updateSelectizeInput(
      session, "filter_metadata_disease",
      choices = split_metadata_tags(df_all$metadata_disease),
      selected = isolate(input$filter_metadata_disease),
      server = TRUE
    )

    updateSelectizeInput(
      session, "filter_metadata_creator",
      choices = sort(unique(na.omit(df_all$metadata_creator))),
      selected = isolate(input$filter_metadata_creator),
      server = TRUE
    )
  })
  
  observe({
    regions <- filtered() %>% dplyr::filter(.data$has_parquet) %>%
      dplyr::pull(.data$geo_region) %>% unique() %>% sort()
    selected <- intersect(isolate(input$preview_region), regions)
    if (!length(selected)) selected <- if ("Texas" %in% regions) "Texas" else head(regions, 1)
    updateSelectInput(session, "preview_region", choices = regions, selected = selected)
  })
  observe({
    req(input$preview_region)
    choices <- scenario_selector_choices(filtered(), input$preview_region)
    selected <- intersect(isolate(input$preview_scenario), unname(choices))
    if (!length(selected)) selected <- head(unname(choices), 1)
    updateSelectizeInput(session, "preview_scenario", choices = choices, selected = selected, server = TRUE)
  })

  observe({
    validation_regions <- filtered() %>%
      dplyr::filter(.data$has_parquet, .data$validation_used) %>%
      dplyr::pull(.data$geo_region) %>%
      unique() %>%
      sort()

    selected_now <- intersect(isolate(input$validation_region), validation_regions)
    if (length(selected_now) == 0 && length(validation_regions) > 0) {
      selected_now <- validation_regions[[1]]
    }

    updateSelectizeInput(
      session,
      "validation_region",
      choices = validation_regions,
      selected = selected_now,
      server = TRUE
    )
  })

  validation_primary_candidates <- reactive({
    req(input$validation_region)

    filtered() %>%
      dplyr::filter(
        .data$has_parquet,
        .data$validation_used,
        .data$geo_region == input$validation_region
      ) %>%
      dplyr::arrange(dplyr::desc(.data$created_at_utc)) %>%
      dplyr::group_by(.data$scenario_hash) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(
        interventions = intervention_label(.data$vaccine_used, .data$antiviral_used, .data$npi_used),
        intervention_order = intervention_order(.data$interventions),
        scenario_label = paste(
          .data$interventions,
          paste0("start ", as.character(.data$metadata_sim_day_0)),
          paste0("hash ", substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash))),
          sep = " | "
        )
      ) %>%
      dplyr::arrange(.data$intervention_order, .data$scenario_label)
  })

  validation_candidates <- reactive({
    req(input$validation_region)

    filtered() %>%
      dplyr::filter(
        .data$has_parquet,
        .data$geo_region == input$validation_region
      ) %>%
      dplyr::arrange(dplyr::desc(.data$created_at_utc)) %>%
      dplyr::group_by(.data$scenario_hash) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(
        interventions = intervention_label(.data$vaccine_used, .data$antiviral_used, .data$npi_used),
        intervention_order = intervention_order(.data$interventions),
        scenario_label = paste(
          .data$interventions,
          paste0("start ", as.character(.data$metadata_sim_day_0)),
          paste0("hash ", substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash))),
          sep = " | "
        )
      ) %>%
      dplyr::arrange(.data$intervention_order, .data$scenario_label)
  })

  observe({
    validation_df <- validation_primary_candidates()

    if (nrow(validation_df) == 0) {
      updateSelectizeInput(
        session,
        "validation_primary_scenario",
        choices = character(0),
        selected = character(0),
        server = TRUE
      )
      return()
    }

    choices <- stats::setNames(validation_df$scenario_hash, validation_df$scenario_label)
    selected_now <- intersect(isolate(input$validation_primary_scenario), validation_df$scenario_hash)

    if (length(selected_now) == 0) {
      none_hashes <- validation_df %>%
        dplyr::filter(.data$interventions == "None") %>%
        dplyr::pull(.data$scenario_hash)
      selected_now <- c(
        none_hashes,
        setdiff(validation_df$scenario_hash, none_hashes)
      )[[1]]
    } else {
      selected_now <- selected_now[[1]]
    }

    updateSelectizeInput(
      session,
      "validation_primary_scenario",
      choices = choices,
      selected = selected_now,
      server = TRUE
    )
  })

  observe({
    validation_df <- validation_candidates()
    primary_hash <- input$validation_primary_scenario
    if (length(primary_hash) == 0 || is.null(primary_hash)) primary_hash <- character(0)

    compare_df <- validation_df %>%
      dplyr::filter(!.data$scenario_hash %in% primary_hash)
    choices <- stats::setNames(compare_df$scenario_hash, compare_df$scenario_label)
    selected_now <- intersect(isolate(input$validation_compare_scenarios), compare_df$scenario_hash)
    if (length(selected_now) > 9) selected_now <- selected_now[seq_len(9)]

    updateSelectizeInput(
      session,
      "validation_compare_scenarios",
      choices = choices,
      selected = selected_now,
      server = TRUE
    )
  })
  
  # Update compartment choices when batch changes
  observeEvent(input$preview_scenario, {
    if (length(input$preview_scenario) == 0 || is.null(input$preview_scenario)) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    column_names <- parquet_schema_names(input$preview_scenario, "network")
    
    if (is.null(column_names)) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    ordered_choices <- compartment_choices_from_columns(column_names, include_s = TRUE)
    
    if (length(ordered_choices) == 0) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    default_choice <- if ("IS" %in% ordered_choices) {
      "IS"
    } else if ("I" %in% ordered_choices) {
      "I"
    } else {
      ordered_choices[[1]]
    }
    
    updateSelectInput(
      session,
      "preview_compartment",
      choices = ordered_choices,
      selected = default_choice
    )
  })

  observeEvent(input$validation_primary_scenario, {
    if (length(input$validation_primary_scenario) == 0 || is.null(input$validation_primary_scenario)) {
      updateSelectInput(session, "validation_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }

    column_names <- parquet_schema_names(input$validation_primary_scenario, "nodes")

    if (is.null(column_names)) {
      updateSelectInput(session, "validation_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }

    ordered_choices <- compartment_choices_from_columns(column_names, include_s = FALSE)

    if (length(ordered_choices) == 0) {
      updateSelectInput(session, "validation_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }

    selected_now <- isolate(input$validation_compartment)
    if (length(selected_now) == 0 || !selected_now %in% ordered_choices) {
      selected_now <- if ("H" %in% ordered_choices) "H" else ordered_choices[[1]]
    }

    updateSelectInput(
      session,
      "validation_compartment",
      choices = ordered_choices,
      selected = selected_now
    )
  })

  # Filtered data
  filtered <- reactive({
    df <- meta()
    if (length(input$filter_region)  > 0) df <- dplyr::filter(df, geo_region       %in% input$filter_region)
    if (length(input$filter_disease) > 0) df <- dplyr::filter(df, disease_identity  %in% input$filter_disease)
    if (length(input$filter_metadata_disease) > 0) {
      df <- dplyr::filter(df, has_any_metadata_tag(.data$metadata_disease, input$filter_metadata_disease))
    }
    if (length(input$filter_metadata_creator) > 0) {
      df <- dplyr::filter(df, metadata_creator %in% input$filter_metadata_creator)
    }
    if (isTRUE(input$filter_vaccine))    df <- dplyr::filter(df, vaccine_used)
    if (isTRUE(input$filter_antiviral))  df <- dplyr::filter(df, antiviral_used)
    if (isTRUE(input$filter_npi))        df <- dplyr::filter(df, npi_used)
    if (isTRUE(input$filter_complete))   df <- dplyr::filter(df, complete_pct == 100)
    df <- dplyr::filter(df,
                 created_at_utc >= as.POSIXct(input$filter_dates[[1]]),
                 created_at_utc <= as.POSIXct(input$filter_dates[[2]]) + 86400)
    df
  })
  
  # Link selected table row to network preview
  observeEvent(input$batch_table_rows_selected, {
    idx <- input$batch_table_rows_selected
    
    # Only sync preview when exactly one row is selected
    if (length(idx) != 1) return()
    
    selected_hash <- filtered()$scenario_hash[idx]
    selected_region <- filtered()$geo_region[idx]
    updateSelectInput(session, "preview_region", selected = selected_region)
    updateSelectizeInput(session, "preview_scenario",
      choices = scenario_selector_choices(filtered(), selected_region),
      selected = selected_hash, server = TRUE)
    updateSelectizeInput(
      session,
      "validation_region",
      selected = filtered()$geo_region[idx]
    )
    updateSelectizeInput(
      session,
      "validation_primary_scenario",
      selected = selected_hash
    )
  })

  # Summary value boxes
  output$n_batches_shown  <- renderText(nrow(filtered()))
  output$n_regions_shown  <- renderText(n_distinct(filtered()$geo_region))
  output$n_real_shown     <- renderText(
    format(sum(filtered()$complete_realization_count, na.rm = TRUE), big.mark = ","))
  output$n_parquet_shown  <- renderText(sum(filtered()$has_parquet, na.rm = TRUE))

  # Batch table
  output$batch_table <- renderDT({
    df <- filtered() %>%
      mutate(
        scenario_hash_4 = substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash)),
        parquet = if_else(has_parquet, "🟢", "🔴"),
        completion = sprintf("%d%%  (%d / %d)",
                             replace_na(complete_pct, 0),
                             replace_na(complete_realization_count, 0L),
                             replace_na(attempt_realization_count, 0L)),
        interventions = intervention_label(vaccine_used, antiviral_used, npi_used),
        created = format(created_at_utc, "%Y-%m-%d %H:%M")
      ) %>%
      mutate(metadata_disease = stringr::str_replace_all(.data$metadata_disease, "\\|", ", ")) %>%
      select(scenario_hash_4, parquet, geo_region, metadata_creator, metadata_disease,
             metadata_sim_day_0, metadata_notes,
             disease_identity, disease_R0, sim_days,
             interventions, completion, mean_run_time_seconds, created, 
             batch_num, scenario_hash, total_parquet_file_size)

    datatable(
      df,
      rownames   = FALSE,
      selection  = "multiple",
      filter     = "top",
      extensions = "Buttons",
      options    = list(
        paging = FALSE,
        scrollY = "calc(100vh - 365px)",
        scrollCollapse = FALSE,
        scrollX = TRUE,
        deferRender = TRUE,
        dom = "<'scenario-table-toolbar'Bf>t",
        buttons = list(
          list(extend = "colvis", text = "Columns")
        ),
        columnDefs = list(
          list(visible = FALSE, targets = c(1, 3, 4, 6, 14, 15)),
          list(className = "dt-center", targets = c(0, 1))
        )
      ),
      colnames = c("Hash", "File Exists", "Region", "Creator", "Disease Tags",
                   "Simulation Day 0", "Notes", "Model", "R0", "Run Day Max",
                   "Interventions",
                   "Sim Completion", "Mean Run Time (sec)", "Created",
                   "batch_num", "scenario_hash", "Total Parquet Size")
    ) %>%
      formatRound("mean_run_time_seconds", digits = 2)
  })

  # Tell the UI whether any rows are selected (for conditional export panel)
  output$has_selection <- reactive({
    length(input$batch_table_rows_selected) > 0
  })
  outputOptions(output, "has_selection", suspendWhenHidden = FALSE)

  # Selected batch_nums
  selected_rows <- reactive({
    idx <- input$batch_table_rows_selected
    if (length(idx) == 0) return(character(0))
    filtered()$batch_num[idx]
  })

  # ── Export metadata CSV ────────────────────────────────────────────────────
  output$export_meta_btn <- downloadHandler(
    filename = function() {
      sprintf("metadata_export_%s.csv", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      filtered() %>%
        dplyr::filter(batch_num %in% selected_rows()) %>%
        select(-has_parquet, -complete_pct) %>%
        write_csv(file)
    }
  )

  # ── Export simulation CSVs (zipped) ──────────────────────────────────────
  output$export_sims_btn <- downloadHandler(
    filename = function() {
      sprintf("sim_export_%s.zip", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      message("START export_sims_btn")
      tmp <- tempfile()
      dir.create(tmp)
      on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
      
      bns <- selected_rows()
      message("Selected batch nums: ", paste(bns, collapse = ", "))
      if (length(bns) == 0) {
        stop("No rows selected for export.")
      }

      withProgress(message = "Exporting simulations…", {
        for (i in seq_along(bns)) {
          bn      <- bns[[i]]
          out_dir <- file.path(tmp, bn)
          dir.create(out_dir)
          
          message("Exporting batch: ", bn)

          # Write network CSV
          net_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "network.parquet"))
          if (length(net_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con,
              sprintf("SELECT * 
                       FROM read_parquet('%s') 
                       ORDER BY sim_id, day",
                      net_pq[[1]])
            )
            write_csv(res, file.path(out_dir, paste0("network_batch-", bn, ".csv")))
          }

          # Write nodes CSV
          node_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "nodes.parquet"))
          if (length(node_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con, # EXCLUDE (scenario_hash, batch_num) 
              sprintf("SELECT * 
                       FROM read_parquet('%s') 
                       ORDER BY fips_id, sim_id, day",
                      node_pq[[1]])
            )
            write_csv(res, file.path(out_dir, paste0("nodes_batch-", bn, ".csv")))
          }
          
          # Write simulation times CSV
          times_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "simulation_times.parquet"))
          if (length(times_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con,
              sprintf(
                "SELECT * 
                 FROM read_parquet('%s')
                 ORDER BY sim_id",
                times_pq[[1]]
              )
            )
            write_csv(res, file.path(out_dir, paste0("simulation_times_batch-", bn, ".csv")))
          }

          incProgress(1 / length(bns), detail = bn)
        } # end for i
      })

      # Zip everything
      files_to_zip <- list.files(tmp, full.names = TRUE, recursive = TRUE)
      if (length(files_to_zip) == 0) {
        stop("No CSV files were created for export.")
      }
      utils::zip(file, files = files_to_zip,
          flags = "-j")
    }
  )

  selected_validation <- reactive({
    validate(need(length(input$validation_region) > 0,
                  "Choose a region for validation comparison."))
    validate(need(length(input$validation_primary_scenario) > 0,
                  "Choose a primary scenario for validation comparison."))

    selected_hashes <- unique(c(input$validation_primary_scenario, input$validation_compare_scenarios))
    selected_hashes <- selected_hashes[!is.na(selected_hashes) & nzchar(selected_hashes)]
    if (length(selected_hashes) > 10) selected_hashes <- selected_hashes[seq_len(10)]

    scenario_rows <- validation_candidates() %>%
      dplyr::filter(
        .data$scenario_hash %in% selected_hashes
      ) %>%
      dplyr::mutate(selected_order = match(.data$scenario_hash, selected_hashes)) %>%
      dplyr::arrange(.data$selected_order) %>%
      dplyr::mutate(
        validation_sim_start_date = as.Date(purrr::map2_chr(
          .data$validation_json,
          .data$metadata_sim_day_0,
          function(validation_json, metadata_sim_day_0) {
            validation_i <- parse_validation_json(validation_json)
            if (is.null(validation_i)) {
              return(as.character(metadata_sim_day_0))
            }
            as.character(validation_i$sim_start_date %||% metadata_sim_day_0)
          }
        )),
        comparison_start_date = first_complete_mmwr_week_end(.data$validation_sim_start_date)
      )

    validate(need(nrow(scenario_rows) > 0, "No validation metadata found for the selected scenarios."))
    validate(need(input$validation_primary_scenario %in% scenario_rows$scenario_hash,
                  "The primary scenario is not available under the current table filters."))

    generated_labels <- comparison_details(scenario_rows, scenario_features())
    scenario_palette <- c(
      "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
      "#76B7B2", "#EDC948", "#9C755F", "#BAB0AC", "#499894"
    )
    scenario_rows <- scenario_rows %>%
      dplyr::left_join(generated_labels, by = "scenario_hash") %>%
      dplyr::mutate(
        hash_label = dplyr::coalesce(.data$hash_label, paste0("hash ", hash_suffix(.data$scenario_hash))),
        difference_summary = dplyr::coalesce(.data$difference_summary, "No indexed input differences"),
        line_color = scenario_palette[((dplyr::row_number() - 1L) %% length(scenario_palette)) + 1L]
      )

    primary_row <- scenario_rows %>%
      dplyr::filter(.data$scenario_hash == input$validation_primary_scenario) %>%
      dplyr::slice(1)

    validation <- parse_validation_json(primary_row$validation_json[[1]])
    if (is.null(validation)) {
      validation <- list(sim_start_date = as.character(primary_row$metadata_sim_day_0[[1]]))
    }
    target <- validation_target(validation)
    
    fit_data_file <- resolve_validation_fit_data_file(primary_row, validation)
    validate(need(!is.na(fit_data_file),
                  "No validation fit data file is available for the primary scenario."))

    age_group <- input$validation_age_group %||% "all"
    compartment <- input$validation_compartment %||% "H"
    show_observed <- identical(compartment, target$compartment)
    observed <- if (show_observed) {
      validation_observed(fit_data_file, age_group, target$observed_column)
    } else {
      tibble(date = as.Date(character()), observed = numeric())
    }
    validate(need(!show_observed || !is.null(observed), "No observed validation records are available."))
    comparison_start_date <- primary_row$comparison_start_date[[1]]
    observed <- observed %>%
      dplyr::filter(.data$date >= comparison_start_date)
    validate(need(!show_observed || nrow(observed) > 0,
                  "No observed validation records remain after dropping partial leading model weeks."))

    generated <- purrr::map_dfr(
      seq_len(nrow(scenario_rows)),
      function(row_index) {
        row <- scenario_rows[row_index, ]
        sim_start_date <- row$validation_sim_start_date[[1]]
        generated_i <- validation_generated(row$scenario_hash[[1]], sim_start_date, age_group, compartment)
        if (is.null(generated_i)) return(tibble::tibble())
        generated_i %>%
          dplyr::mutate(
            scenario_hash = row$scenario_hash[[1]],
            scenario_label = row$hash_label[[1]],
            difference_summary = row$difference_summary[[1]],
            line_color = row$line_color[[1]],
            interventions = row$interventions[[1]],
            intervention_order = row$intervention_order[[1]]
          )
      }
    )
    generated <- generated %>%
      dplyr::filter(.data$date >= comparison_start_date)
    validate(need(nrow(generated) > 0,
                  "No generated weekly incident series is available for the selected scenarios."))

    list(
      rows = scenario_rows,
      validation = validation,
      fit_data_file = fit_data_file,
      age_group = age_group,
      age_group_label = age_group_label(age_group),
      compartment = compartment,
      validation_target = target,
      show_observed = show_observed,
      comparison_start_date = comparison_start_date,
      observed = observed,
      generated = generated
    )
  })

  output$validation_plot <- plotly::renderPlotly({
    v <- selected_validation()

    observed_plot_df <- v$observed %>%
      dplyr::filter(!is.na(.data$observed))

    generated_plot_df <- v$generated %>%
      dplyr::filter(
        !is.na(.data$generated_lo),
        !is.na(.data$generated_hi),
        !is.na(.data$generated_median)
      )

    title_text <- as.character(paste0(
      input$validation_region,
      " | ",
      if (identical(v$age_group_label, "all")) "all ages" else v$age_group_label,
      " | ",
      v$compartment,
      " | weekly incident generated trajectories"
    ))

    scenario_levels <- v$rows %>%
      dplyr::filter(.data$hash_label %in% unique(generated_plot_df$scenario_label)) %>%
      dplyr::arrange(.data$selected_order) %>%
      dplyr::pull(.data$hash_label) %>%
      as.character()
    scenario_colors <- v$rows$line_color[match(scenario_levels, v$rows$hash_label)]
    names(scenario_colors) <- scenario_levels

    hover_summary_df <- generated_plot_df %>%
      dplyr::mutate(scenario_label = factor(.data$scenario_label, levels = scenario_levels)) %>%
      dplyr::arrange(.data$date, .data$scenario_label) %>%
      dplyr::group_by(.data$date) %>%
      dplyr::summarise(
        generated_hover = paste0(
          as.character(.data$scenario_label),
          ": ",
          round(.data$generated_median, 2),
          " (",
          round(.data$generated_lo, 2),
          "-",
          round(.data$generated_hi, 2),
          ")",
          collapse = "<br>"
        ),
        .groups = "drop"
      )

    if (isTRUE(v$show_observed)) {
      hover_summary_df <- hover_summary_df %>%
        dplyr::left_join(
          observed_plot_df %>%
            dplyr::transmute(
              date = .data$date,
              observed_hover = paste0(v$validation_target$label, ": ", round(.data$observed, 2))
            ),
          by = "date"
        )
    } else {
      hover_summary_df$observed_hover <- NA_character_
    }

    hover_summary_df <- hover_summary_df %>%
      dplyr::mutate(
        hover_date = format(.data$date, "%b %d, %Y"),
        hover_text = dplyr::if_else(
          is.na(.data$observed_hover) | !nzchar(.data$observed_hover),
          paste(.data$hover_date, .data$generated_hover, sep = "<br>"),
          paste(.data$hover_date, .data$generated_hover, .data$observed_hover, sep = "<br>")
        )
      )

    hover_points_df <- generated_plot_df %>%
      dplyr::transmute(date = .data$date, hover_y = .data$generated_median) %>%
      dplyr::bind_rows(
        if (isTRUE(v$show_observed)) {
          observed_plot_df %>%
            dplyr::transmute(date = .data$date, hover_y = .data$observed)
        } else {
          tibble(date = as.Date(character()), hover_y = numeric())
        }
      ) %>%
      dplyr::left_join(
        hover_summary_df %>% dplyr::select("date", "hover_text"),
        by = "date"
      ) %>%
      dplyr::filter(!is.na(.data$hover_y), !is.na(.data$hover_text)) %>%
      dplyr::distinct()

    validation_plot <- plotly::plot_ly()
    for (scenario in scenario_levels) {
      ribbon_df <- generated_plot_df %>%
        dplyr::filter(.data$scenario_label == scenario)
      validation_plot <- validation_plot %>%
        plotly::add_ribbons(
          data = ribbon_df,
          x = ~date,
          ymin = ~generated_lo,
          ymax = ~generated_hi,
          name = as.character(scenario),
          legendgroup = as.character(scenario),
          showlegend = FALSE,
          fillcolor = grDevices::adjustcolor(scenario_colors[[scenario]], alpha.f = 0.16),
          line = list(color = "rgba(0,0,0,0)"),
          hoverinfo = "skip"
        )
    }

    for (scenario in scenario_levels) {
      line_df <- generated_plot_df %>%
        dplyr::filter(.data$scenario_label == scenario)
      validation_plot <- validation_plot %>%
        plotly::add_lines(
          data = line_df,
          x = ~date,
          y = ~generated_median,
          name = as.character(scenario),
          legendgroup = as.character(scenario),
          hoverinfo = "skip",
          line = list(color = scenario_colors[[scenario]], width = 2.5)
        )
    }

    if (isTRUE(v$show_observed)) {
      validation_plot <- validation_plot %>%
        plotly::add_markers(
        data = observed_plot_df,
        x = ~date,
        y = ~observed,
        name = v$validation_target$label,
        marker = list(color = "rgb(225,87,89)", size = 8),
        hoverinfo = "skip"
      )
    }

    if (nrow(hover_points_df) > 0) {
      validation_plot <- validation_plot %>%
        plotly::add_markers(
          data = hover_points_df,
          x = ~date,
          y = ~hover_y,
          text = ~hover_text,
          name = "",
          showlegend = FALSE,
          hovertemplate = "%{text}<extra></extra>",
          marker = list(color = "rgba(0,0,0,0)", size = 18)
        )
    }

    validation_plot %>%
      plotly::layout(
        title = list(text = title_text),
        xaxis = list(title = list(text = "Week ending date")),
        yaxis = list(title = list(text = paste("Weekly incident", v$compartment, "(median; parentheses = 5th-95th quantiles)"))),
        hovermode = "closest",
        hoverlabel = list(
          bgcolor = "white",
          bordercolor = "rgba(0,0,0,0.35)",
          font = list(color = "black")
        ),
        legend = list(traceorder = "normal")
      )
  })

  output$validation_summary_table <- renderDT({
    validation_summary_df() %>%
      DT::datatable(
        rownames = FALSE,
        escape = FALSE,
        callback = DT::JS(
          "table.on('click', 'button.validation-diff-details', function() {",
          "  Shiny.setInputValue('validation_diff_details', this.dataset.hash, {priority: 'event'});",
          "});"
        ),
        options = list(
          paging = FALSE,
          ordering = FALSE,
          searching = FALSE,
          info = FALSE,
          dom = "t",
          columnDefs = list(
            list(width = "48px", targets = 0),
            list(width = "90px", targets = 1),
            list(width = "90px", targets = 2),
            list(width = "160px", targets = 3),
            list(width = "110px", targets = 4),
            list(width = "100px", targets = 6)
          )
        )
      )
  })

  observeEvent(input$validation_diff_details, {
    selected_diff_hash(input$validation_diff_details)
    row <- selected_validation()$rows %>%
      dplyr::filter(.data$scenario_hash == input$validation_diff_details) %>%
      dplyr::slice(1)

    title <- if (nrow(row) == 0) {
      "Scenario differences"
    } else {
      paste("Differences for", row$hash_label[[1]])
    }

    showModal(modalDialog(
      title = title,
      DTOutput("validation_diff_modal_table"),
      easyClose = TRUE,
      size = "l",
      footer = tagList(
        downloadButton("download_validation_diff", "CSV", class = "btn-outline-secondary"),
        modalButton("Close")
      )
    ))
  })

  output$validation_diff_modal_table <- renderDT({
    hash <- selected_diff_hash()
    validate(need(length(hash) == 1 && nzchar(hash), "Choose a scenario to inspect."))

    v <- selected_validation()
    primary_hash <- input$validation_primary_scenario

    scenario_difference_table(scenario_features(), primary_hash, hash) %>%
      DT::datatable(
        rownames = FALSE,
        extensions = "FixedHeader",
        options = list(
          paging = FALSE,
          scrollY = "60vh",
          scrollCollapse = TRUE,
          scrollX = TRUE,
          fixedHeader = TRUE,
          dom = "ftp"
        )
      )
  })

  validation_summary_df <- reactive({
    v <- selected_validation()

    v$rows %>%
      dplyr::transmute(
        Line = paste0(
          '<span style="display:inline-block;width:1.1rem;height:0.7rem;',
          'border-radius:2px;background:',
          .data$line_color,
          ';"></span>'
        ),
        Role = dplyr::if_else(
          .data$scenario_hash == input$validation_primary_scenario,
          "Primary",
          "Compare"
        ),
        Hash = .data$hash_label,
        Scenario = .data$interventions,
        Start = as.character(.data$metadata_sim_day_0),
        Differences = short_feature_value(.data$difference_summary, 96),
        Details = paste0(
          '<button type="button" class="btn btn-sm btn-outline-secondary validation-diff-details" data-hash="',
          htmltools::htmlEscape(.data$scenario_hash),
          '">Details</button>'
        )
      )
  })

  validation_data_df <- reactive({
    v <- selected_validation()

    if (!isTRUE(v$show_observed)) {
      return(tibble(
        message = paste0(
          "Observed validation dots are only available for ",
          v$validation_target$compartment,
          "; generated lines show weekly incident ",
          v$compartment,
          "."
        )
      ))
    }

    dplyr::full_join(v$observed, v$generated, by = "date") %>%
      dplyr::arrange(.data$date) %>%
      dplyr::select(
        "date",
        "scenario_label",
        "observed",
        "generated_median",
        "generated_lo",
        "generated_hi"
      ) %>%
      dplyr::mutate(dplyr::across(where(is.numeric), ~ round(.x, 2))) %>%
      dplyr::rename(
        Date = "date",
        Scenario = "scenario_label",
        Observed = "observed",
        `Generated median` = "generated_median",
        `Generated 5th percentile` = "generated_lo",
        `Generated 95th percentile` = "generated_hi"
      )
  })

  output$download_validation_summary <- downloadHandler(
    filename = function() {
      sprintf("validation_comparison_summary_%s.csv", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      selected_validation()$rows %>%
        dplyr::transmute(
          line_color = .data$line_color,
          role = dplyr::if_else(
            .data$scenario_hash == input$validation_primary_scenario,
            "Primary",
            "Compare"
          ),
          hash = .data$hash_label,
          scenario_hash = .data$scenario_hash,
          scenario = .data$interventions,
          start = as.character(.data$metadata_sim_day_0),
          differences = .data$difference_summary
        ) %>%
        readr::write_csv(file)
    }
  )

  output$download_validation_diff <- downloadHandler(
    filename = function() {
      hash <- selected_diff_hash() %||% "scenario"
      sprintf("validation_diff_%s.csv", hash_suffix(hash))
    },
    content = function(file) {
      hash <- selected_diff_hash()
      validate(need(length(hash) == 1 && nzchar(hash), "Choose a scenario to inspect."))
      scenario_difference_table(
        scenario_features(),
        input$validation_primary_scenario,
        hash
      ) %>%
        readr::write_csv(file)
    }
  )

  output$download_validation_data <- downloadHandler(
    filename = function() {
      sprintf("validation_data_%s.csv", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      validation_data_df() %>%
        readr::write_csv(file)
    }
  )

  output$validation_table <- renderDT({
    validation_df <- validation_data_df()

    if ("message" %in% names(validation_df)) {
      return(DT::datatable(
        validation_df,
        rownames = FALSE,
        options = list(
          paging = FALSE,
          ordering = FALSE,
          searching = FALSE,
          info = FALSE,
          dom = "t"
        )
      ))
    }

    validation_df %>%
      DT::datatable(
        rownames = FALSE,
        extensions = c("FixedHeader"),
        options = list(
          paging = FALSE,
          scrollY = "420px",
          scrollCollapse = TRUE,
          scrollX = TRUE,
          fixedHeader = TRUE,
          order = list(list(0, "asc")),
          dom = "t"
        )
      )
  })

  # ── Network preview plot ───────────────────────────────────────────────────
  output$network_plot <- plotly::renderPlotly({
    validate(need(length(input$preview_scenario) > 0,
                  "No scenario available for the current table filter."))
    validate(need(length(input$preview_compartment) > 0,
                  "No compartment available for the selected scenario."))
    
    preview_age_group <- input$preview_age_group %||% "all"
    preview_data_type <- if (identical(preview_age_group, "all")) "network" else "nodes"

    comp <- input$preview_compartment
    column_names <- parquet_schema_names(input$preview_scenario, preview_data_type)
    validate(need(!is.null(column_names), paste("No", preview_data_type, "parquet found for this scenario.")))

    comp_columns <- age_compartment_columns(column_names, comp, preview_age_group)
    validate(need(length(comp_columns) > 0 && all(comp_columns %in% column_names),
                  paste("Column not found in", preview_data_type, "data for:", comp)))

    df <- scenario_compartment_timeseries(input$preview_scenario, preview_data_type, comp_columns)
    validate(need(!is.null(df), paste("No", preview_data_type, "parquet found for this scenario.")))
    
    meta_df <- meta() %>%
      dplyr::filter(scenario_hash == input$preview_scenario) %>%
      dplyr::mutate(
        interventions = intervention_label(vaccine_used, antiviral_used, npi_used)
      ) %>%
      dplyr::select(
        batch_num,
        sim_days,
        geo_region,
        disease_R0,
        interventions
      )
    
    # get last 4 digits of hash for labeling
    df_plot <- df %>%
      dplyr::left_join(meta_df, by = "batch_num") %>%
      dplyr::mutate(
        batch_label = paste0(
          "batch ",
          substr(batch_num, nchar(batch_num) - 3, nchar(batch_num)),
          " | ",
          sim_days,
          " days"
        ),
        line_id = as.character(paste(batch_num, sim_id, sep = "_")),
        hover_text = paste0(
          "Batch: ", batch_label,
          "<br>Sim: ", sim_id,
          "<br>Day: ", day,
          "<br>Value: ", value
        )
      ) %>%
      dplyr::arrange(batch_num, sim_id, day)
    
    # Plot with one line per simulation, with descriptive title
    total_sims <- dplyr::n_distinct(df_plot$line_id)
    
    geo_region <- unique(meta_df$geo_region)[1]
    r0_value   <- unique(meta_df$disease_R0)[1]
    
    intervention_text <- meta_df %>%
      dplyr::pull(interventions) %>%
      unique() %>%
      sort() %>%
      paste(collapse = ", ")
    
    age_text <- if (identical(preview_age_group, "all")) {
      "all ages"
    } else {
      age_group_label(preview_age_group)
    }
    
    title_text <- as.character(paste0(
      geo_region, " | ",
      age_text, " | ",
      intervention_text, " | ",
      "R0=", round(r0_value, 2), " | ",
      total_sims, " sims"
    ))
    
    plotly::plot_ly(
      data = df_plot,
      x = ~day,
      y = ~value,
      type = "scatter",
      mode = "lines",
      split = ~line_id,
      line = list(color = "rgba(78,121,167,0.6)", width = 1.5),
      text = ~hover_text,
      hovertemplate = "%{text}<extra></extra>"
    ) %>%
      plotly::layout(
        title = list(text = paste0(title_text, "<br>")),
        xaxis = list(title = list(text = "Day")),
        yaxis = list(title = list(text = as.character(comp))),
        showlegend = FALSE
      )
  })

  # ── About tab ──────────────────────────────────────────────────────────────
  output$paths_info <- renderText({
    sprintf(
      "MASTER_CSV       : %s\nPARQUET_ROOT     : %s\nFEATURES_PARQUET : %s\n\nMaster CSV exists      : %s\nParquet root exists    : %s\nFeature parquet exists : %s",
      MASTER_CSV, PARQUET_ROOT, FEATURES_PARQUET,
      file.exists(MASTER_CSV),
      dir.exists(PARQUET_ROOT),
      file.exists(FEATURES_PARQUET)
    )
  })
}

shinyApp(ui, server, onStart = start_county_map_worker)
