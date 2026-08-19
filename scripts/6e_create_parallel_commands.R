#////////
#### Script Overview ####
#////////
#' Create parallel simulator commands for manuscript input JSONs.
#'
#' Input JSONs are generated upstream into dated directories under:
#'   STATE_INIT_TEST/TACC_FILES
#'
#' This script does not write simulator input JSONs. It writes launcher files
#' next to those dated input directories:
#'   STATE_INIT_TEST/TACC_FILES/state_commands.txt
#'   STATE_INIT_TEST/TACC_FILES/state_launcher.sh
#////////
library(tidyverse)
library(jsonlite)

simulation_days <- as.integer(get0("SIMULATION_DAYS", ifnotfound = 300L))
pipeline_output_dir <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_INIT_TEST")
selected_run_states <- get0("SELECTED_RUN_STATES", ifnotfound = character())
intervention_template_files <- get0("INTERVENTION_TEMPLATE_FILES", ifnotfound = character())
selected_run_scenarios <- get0(
  "SELECTED_RUN_SCENARIOS",
  ifnotfound = c("NONE", names(intervention_template_files))
)
sim_day_0_values <- as.character(get0("SIM_DAY_0_VALUES", ifnotfound = character()))
input_dir <- file.path("..", pipeline_output_dir, "TACC_FILES")
commands_file <- file.path(input_dir, "state_commands.txt")
launcher_file <- file.path(input_dir, "state_launcher.sh")
launcher_template_file <- file.path("..", "data", "INPUT_FILE_TEMPLATES", "state_launcher.sh")
simulator_file_rel <- file.path("..", "..", "src", "simulator.py")

dir.create(input_dir, showWarnings = FALSE, recursive = TRUE)

input_files <- list.files(
  input_dir,
  pattern = "^INPUT_.*\\.json$",
  full.names = TRUE,
  recursive = TRUE
)

if (length(input_files) == 0) {
  stop("No TACC JSONs found in ", input_dir, ". Run 6d first.")
}

input_metadata <- tibble(INPUT_FILE = input_files) %>%
  mutate(
    config = purrr::map(.data$INPUT_FILE, jsonlite::fromJSON, simplifyVector = FALSE),
    sim_day_0 = purrr::map_chr(
      .data$config,
      ~ {
        value <- tryCatch(.x$metadata_tags$sim_day_0, error = function(e) NA_character_)
        if (is.null(value)) NA_character_ else as.character(value)
      }
    ),
    state = purrr::map_chr(
      .data$config,
      ~ {
        value <- tryCatch(.x$metadata_tags$state_dir, error = function(e) NA_character_)
        if (is.null(value)) NA_character_ else as.character(value)
      }
    ),
    scenario = purrr::map_chr(
      .data$config,
      ~ {
        value <- tryCatch(.x$metadata_tags$scenario_label, error = function(e) NA_character_)
        if (is.null(value)) NA_character_ else as.character(value)
      }
    )
  )

if (length(selected_run_states) > 0) {
  input_metadata <- input_metadata %>%
    filter(.data$state %in% selected_run_states)
}
if (length(sim_day_0_values) > 0) {
  input_metadata <- input_metadata %>%
    filter(.data$sim_day_0 %in% sim_day_0_values)
}

all_commands_script <- input_metadata %>%
  mutate(
    state_order = match(.data$state, selected_run_states),
    state_order = if_else(is.na(.data$state_order), row_number(), .data$state_order),
    date_order = match(.data$sim_day_0, sim_day_0_values),
    date_order = if_else(is.na(.data$date_order), row_number(), .data$date_order),
    scenario_order = match(.data$scenario, selected_run_scenarios),
    scenario_order = if_else(is.na(.data$scenario_order), row_number(), .data$scenario_order)
  ) %>%
  arrange(.data$state_order, .data$date_order, .data$scenario_order) %>%
  mutate(
    final_poetry_command = paste(
      paste0("echo 'START sim_day_0=", .data$sim_day_0, " state=", .data$state, " scenario=", .data$scenario, "';"),
      "mkdir -p GENERATE;",
      "poetry run python3",
      shQuote(simulator_file_rel),
      "-l INFO -d",
      simulation_days,
      "-i",
      shQuote(file.path(.data$sim_day_0, basename(.data$INPUT_FILE))),
      "; status=$?;",
      "rmdir GENERATE 2>/dev/null || true;",
      "exit $status"
    )
  ) %>%
  dplyr::select(final_poetry_command)

write.table(
  all_commands_script,
  commands_file,
  sep = "",
  col.names = FALSE,
  row.names = FALSE,
  quote = FALSE
)

if (!file.exists(launcher_file)) {
  if (!file.exists(launcher_template_file)) {
    stop("No TACC launcher template found at ", launcher_template_file)
  }
  file.copy(launcher_template_file, launcher_file, overwrite = FALSE)
  Sys.chmod(launcher_file, mode = "0755")
  message("Copied TACC launcher template to ", launcher_file)
} else {
  message("TACC launcher already exists, leaving unchanged: ", launcher_file)
}

message("Wrote ", nrow(all_commands_script), " simulator commands to ", commands_file)
