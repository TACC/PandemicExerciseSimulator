# Refresh the small shinyapps.io deployment bundle for the dashboard.

library(readr)
library(dplyr)

cmd_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd_args, value = TRUE)
script_path <- if (length(file_arg) > 0) sub("^--file=", "", file_arg[[1]]) else ""
script_dir <- if (nzchar(script_path)) dirname(normalizePath(script_path, mustWork = FALSE)) else getwd()

if (dir.exists(file.path(script_dir, "scripts"))) {
  repo_root <- normalizePath(script_dir, mustWork = TRUE)
} else if (dir.exists(file.path(script_dir, "..", "scripts"))) {
  repo_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
} else {
  repo_root <- normalizePath(getwd(), mustWork = TRUE)
}

pipeline_output_dir <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_INIT_TEST")
preview_states <- get0(
  "DASHBOARD_PREVIEW_STATES",
  ifnotfound = get0(
    "WEB_PREVIEW_STATES",
    ifnotfound = c("District-of-Columbia", "Connecticut", "Massachusetts")
  )
)
preview_scenarios <- get0(
  "DASHBOARD_PREVIEW_SCENARIOS",
  ifnotfound = get0(
    "SELECTED_RUN_SCENARIOS",
    ifnotfound = c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS")
  )
)
preview_output_subdir <- get0("DASHBOARD_PREVIEW_OUTPUT_SUBDIR", ifnotfound = "WEB_OUTPUTS")

source_app <- file.path(repo_root, "scripts", "7b_sim_dashboard_app.R")
source_data <- file.path(repo_root, pipeline_output_dir)
bundle_dir <- file.path(repo_root, "deploy", "shinyapps", "PandemicSimExplorer")
bundle_data <- file.path(bundle_dir, "data")
source_master <- file.path(source_data, "metadata_master.csv")
bundle_master <- file.path(bundle_data, "metadata_master.csv")

dir.create(bundle_data, recursive = TRUE, showWarnings = FALSE)
file.copy(source_app, file.path(bundle_dir, "app.R"), overwrite = TRUE)

if (!file.exists(source_master)) {
  stop("No metadata master found at ", source_master, ". Run 7a first.")
}

metadata <- readr::read_csv(
  source_master,
  col_types = readr::cols(
    validation_json = readr::col_character(),
    validation_fit_data_file = readr::col_character(),
    .default = readr::col_guess()
  ),
  show_col_types = FALSE
)
metadata_preview <- metadata %>%
  dplyr::filter(.data$geo_region %in% preview_states)

if (nzchar(preview_output_subdir) && "file_path" %in% names(metadata_preview)) {
  metadata_preview <- metadata_preview %>%
    dplyr::filter(grepl(preview_output_subdir, .data$file_path, fixed = TRUE))
}

if (nrow(metadata_preview) == 0) {
  stop(
    "No metadata rows found for preview states: ",
    paste(preview_states, collapse = ", ")
  )
}

scenario_lookup <- tibble::tribble(
  ~scenario_label,       ~vaccine_used, ~antiviral_used, ~npi_used,
  "NONE",            FALSE,         FALSE,           FALSE,
  "VACCINE",             TRUE,          FALSE,           FALSE,
  "ANTIVIRAL",           FALSE,         TRUE,            FALSE,
  "NPI",                 FALSE,         FALSE,           TRUE,
  "ALL_INTERVENTIONS",   TRUE,          TRUE,            TRUE
)
unknown_preview_scenarios <- setdiff(preview_scenarios, scenario_lookup$scenario_label)
if (length(unknown_preview_scenarios) > 0) {
  stop("Unknown dashboard preview scenario label(s): ", paste(unknown_preview_scenarios, collapse = ", "))
}
expected_scenarios <- scenario_lookup %>%
  dplyr::filter(.data$scenario_label %in% preview_scenarios) %>%
  dplyr::select(-.data$scenario_label)

metadata_preview <- metadata_preview %>%
  dplyr::mutate(created_at_utc = as.POSIXct(.data$created_at_utc, tz = "UTC")) %>%
  dplyr::semi_join(expected_scenarios, by = c("vaccine_used", "antiviral_used", "npi_used")) %>%
  dplyr::arrange(.data$geo_region, .data$vaccine_used, .data$antiviral_used, .data$npi_used, dplyr::desc(.data$created_at_utc)) %>%
  dplyr::group_by(.data$geo_region, .data$vaccine_used, .data$antiviral_used, .data$npi_used) %>%
  dplyr::slice(1) %>%
  dplyr::ungroup()

if ("validation_fit_data_file" %in% names(metadata_preview)) {
  metadata_preview <- metadata_preview %>%
    dplyr::mutate(
      validation_fit_data_file = as.character(.data$validation_fit_data_file),
      validation_fit_data_file = dplyr::if_else(
        is.na(.data$validation_fit_data_file) | !nzchar(.data$validation_fit_data_file),
        .data$validation_fit_data_file,
        file.path("validation_fit_data", basename(.data$validation_fit_data_file))
      )
    )
}

expected_preview_rows <- tidyr::crossing(
  geo_region = preview_states,
  expected_scenarios
)
missing_preview_rows <- expected_preview_rows %>%
  dplyr::anti_join(
    metadata_preview,
    by = c("geo_region", "vaccine_used", "antiviral_used", "npi_used")
  )
if (nrow(missing_preview_rows) > 0) {
  stop("Missing one or more preview dashboard rows. Run the local web preview simulator commands and 7a first.")
}

readr::write_csv(metadata_preview, bundle_master)

dir.create(file.path(bundle_data, "sim_data"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(bundle_data, "validation_fit_data"), recursive = TRUE, showWarnings = FALSE)
missing_parquet <- character()
for (i in seq_len(nrow(metadata_preview))) {
  source_batch_dir <- file.path(
    source_data,
    "sim_data",
    metadata_preview$scenario_hash[[i]],
    metadata_preview$batch_num[[i]]
  )
  if (!dir.exists(source_batch_dir)) {
    missing_parquet <- c(missing_parquet, source_batch_dir)
    next
  }
  
  bundle_hash_dir <- file.path(
    bundle_data,
    "sim_data",
    metadata_preview$scenario_hash[[i]]
  )
  dir.create(bundle_hash_dir, recursive = TRUE, showWarnings = FALSE)
  bundle_batch_dir <- file.path(bundle_hash_dir, metadata_preview$batch_num[[i]])
  if (!dir.exists(bundle_batch_dir)) {
    file.copy(source_batch_dir, bundle_hash_dir, recursive = TRUE)
  } else {
    file.copy(
      list.files(source_batch_dir, full.names = TRUE),
      bundle_batch_dir,
      recursive = TRUE,
      overwrite = TRUE
    )
  }
}
if (length(missing_parquet) > 0) {
  stop("Missing preview Parquet directories: ", paste(missing_parquet, collapse = ", "))
}
file.copy(
  list.files(file.path(source_data, "validation_fit_data"), full.names = TRUE),
  file.path(bundle_data, "validation_fit_data"),
  recursive = TRUE,
  overwrite = TRUE
)

message(
  "Refreshed shinyapps.io bundle for ",
  paste(preview_states, collapse = ", "),
  " and scenarios ",
  paste(preview_scenarios, collapse = ", "),
  ": ",
  bundle_dir
)
