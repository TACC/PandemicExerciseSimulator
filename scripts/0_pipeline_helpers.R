# Internal setup and support for 0_run_full_pipeline_US.R.
# Experiment choices belong in data/INPUT_FILE_TEMPLATES/RUN_FULL_PIPELINE_INPUTS.R.

#' Resolve an input path relative to the repository
#'
#' Searches the repository root and then its scripts directory for relative
#' paths. Nonexistent paths are normalized without requiring them to exist.
#'
#' @param path A single absolute or repository-relative file path.
#' @param repo_root Absolute path to the repository root.
#' @return A normalized absolute path.
pipeline_input_path <- function(path, repo_root) {
  if (grepl("^/", path)) return(normalizePath(path, mustWork = FALSE))
  candidates <- c(file.path(repo_root, path), file.path(repo_root, "scripts", path))
  existing <- candidates[file.exists(candidates)]
  normalizePath(if (length(existing)) existing[[1]] else candidates[[1]], mustWork = FALSE)
}

#' Read pipeline settings and apply command-line overrides
#'
#' Loads the default input template, merges an experiment's named
#' `pipeline_inputs` list, and applies supported command-line overrides.
#' A config may define pipeline_shared_inputs to inherit another R input file;
#' shared paths are resolved relative to the config containing the reference.
#' Unknown settings and malformed arguments cause an error.
#'
#' @param config_file Input R file, or NULL to use the default template.
#' @param args Character vector of command-line arguments in --name=value form.
#' @param repo_root Absolute path to the repository root.
#' @param invocation_dir Directory from which relative config paths are resolved.
#' @return A list containing the resolved config `file` and merged `values`.
read_pipeline_inputs <- function(config_file = NULL, args = character(), repo_root, invocation_dir = getwd()) {
  default_file <- file.path(repo_root, "data", "INPUT_FILE_TEMPLATES", "RUN_FULL_PIPELINE_INPUTS.R")
  #' Read a named pipeline input list from an R file
  #'
  #' @param path Path to an R file defining a named `pipeline_inputs` list.
  #' @param parents Paths already read while resolving shared settings.
  #' @return The input list, merged over any pipeline_shared_inputs file.
  #'   Invalid names or circular shared-file references cause an error.
  read_inputs <- function(path, parents = character()) {
    path <- normalizePath(path, mustWork = TRUE)
    if (path %in% parents) stop("Circular pipeline_shared_inputs reference: ", path)
    env <- new.env(parent = baseenv())
    sys.source(path, envir = env)
    if (!exists("pipeline_inputs", env, inherits = FALSE) ||
      !is.list(env$pipeline_inputs) || is.null(names(env$pipeline_inputs)) ||
      any(!nzchar(names(env$pipeline_inputs))) || anyDuplicated(names(env$pipeline_inputs))) {
      stop("Config must define a named list called pipeline_inputs: ", path)
    }
    values <- env$pipeline_inputs
    if (exists("pipeline_shared_inputs", env, inherits = FALSE)) {
      shared <- env$pipeline_shared_inputs
      if (!is.character(shared) || length(shared) != 1L || !nzchar(shared)) {
        stop("pipeline_shared_inputs must name one shared input R file: ", path)
      }
      shared <- if (grepl("^/", shared)) shared else file.path(dirname(path), shared)
      values <- utils::modifyList(read_inputs(shared, c(parents, path)), values, keep.null = TRUE)
    }
    values
  }
  defaults <- read_inputs(default_file)
  hit <- args[startsWith(args, "--config=")]
  if (length(hit)) config_file <- sub("--config=", "", hit[[1]], fixed = TRUE)
  if (is.null(config_file)) config_file <- default_file
  candidates <- if (grepl("^/", config_file)) config_file else c(
    file.path(invocation_dir, config_file), file.path(repo_root, config_file),
    file.path(repo_root, "scripts", config_file))
  found <- candidates[file.exists(candidates)]
  if (!length(found)) stop("Pipeline config does not exist: ", config_file)
  config_file <- normalizePath(found[[1]], mustWork = TRUE)
  supplied <- read_inputs(config_file)
  unknown <- setdiff(names(supplied), names(defaults))
  if (length(unknown)) stop("Unknown pipeline input(s): ", paste(unknown, collapse = ", "))
  values <- utils::modifyList(defaults, supplied, keep.null = TRUE)
  aliases <- c(`r0-wis-realization-range` = "r0-realization-range",
    `r0-wis-county-threshold` = "r0-county-threshold")
  malformed <- args[!grepl("=", args, fixed = TRUE) & args != "--check-config"]
  if (length(malformed)) stop("Use --name=value for pipeline options: ", paste(malformed, collapse = ", "))
  flags <- sub("=.*$", "", sub("^--", "", args))
  allowed <- c(gsub("_", "-", names(defaults), fixed = TRUE), names(aliases), "config", "check-config")
  if (any(!startsWith(args, "--")) || length(setdiff(flags, allowed))) {
    stop("Unknown pipeline argument(s): ", paste(args[!flags %in% allowed | !startsWith(args, "--")], collapse = ", "))
  }
  for (key in names(defaults)) {
    flag <- gsub("_", "-", key, fixed = TRUE)
    accepted <- c(flag, names(aliases)[aliases == flag])
    for (candidate in accepted) {
      hit <- args[startsWith(args, paste0("--", candidate, "="))]
      if (length(hit)) {
        values[key] <- list(sub(paste0("--", candidate, "="), "", hit[[1]], fixed = TRUE))
        break
      }
    }
  }
  list(file = config_file, values = values)
}

#' Initialize and validate the pipeline configuration
#'
#' Converts merged input values into the runtime variables consumed by scripts
#' 0 through 9. Resolves templates, validates settings, and loads R_m search
#' helpers without creating output directories or starting simulations.
#'
#' @param config_file Input R file, or NULL to use the default template.
#' @param args Character vector of command-line overrides.
#' @param repo_root Absolute path to the repository root.
#' @param invocation_dir Directory used to resolve relative config paths.
#' @param envir Environment receiving configuration variables and input accessors.
#' @return Invisibly, the list returned by read_pipeline_inputs().
initialize_pipeline_inputs <- function(config_file = NULL, args = character(), repo_root,
                                       invocation_dir = getwd(), envir = parent.frame()) {
  loaded <- read_pipeline_inputs(config_file, args, repo_root, invocation_dir)
  assign("repo_root", repo_root, envir)
  assign("PIPELINE_CONFIG_FILE", loaded$file, envir)
  assign("pipeline_input_values", loaded$values, envir)
  evalq({
    #' Read a merged pipeline input as a command-line value
    #'
    #' @param prefix Option prefix such as --workers=.
    #' @param default Value returned when the input is NULL.
    #' @return The input collapsed to one comma-separated string, or `default`.
    get_arg_value <- function(prefix, default = NULL) {
      key <- gsub("-", "_", sub("=$", "", sub("^--", "", prefix)), fixed = TRUE)
      value <- pipeline_input_values[[key]]
      if (is.null(value)) return(default)
      if (is.logical(value)) value <- tolower(as.character(value))
      paste(value, collapse = ",")
    }
    #' Read and validate a logical pipeline input
    #'
    #' @param prefix Option prefix such as --run-web-preview=.
    #' @param default Fallback value passed to get_arg_value().
    #' @return A single logical value. Unrecognized boolean strings cause an error.
    get_bool_arg <- function(prefix, default = NULL) {
      value <- tolower(get_arg_value(prefix, default))
      if (length(value) != 1L || !value %in% c("true", "false", "1", "0", "yes", "no", "y", "n")) {
        stop("Expected true or false for ", prefix)
      }
      value %in% c("true", "1", "yes", "y")
    }
    PIPELINE_OUTPUT_DIR <- get_arg_value("--output-dir=")
    PIPELINE_PHASE <- get_arg_value("--pipeline-phase=")
    EXECUTION_TARGET <- get_arg_value("--execution-target=")
    LS6_CONTAINER_IMAGE <- get_arg_value("--ls6-container-image=", "")
    if (nzchar(LS6_CONTAINER_IMAGE)) {
      LS6_CONTAINER_IMAGE <- pipeline_input_path(path.expand(LS6_CONTAINER_IMAGE), repo_root)
    }
    if (!PIPELINE_PHASE %in% c("all", "fit", "scenarios", "results")) {
      stop("pipeline_phase must be all, fit, scenarios, or results.")
    }
    if (!EXECUTION_TARGET %in% c("local", "ls6")) {
      stop("execution_target must be local or ls6.")
    }
    if (EXECUTION_TARGET == "ls6" && PIPELINE_PHASE == "all") {
      stop("For execution_target=ls6, choose fit, scenarios, or results explicitly.")
    }
    SELECTED_RUN_STATES <- normalize_state_dir_names(split_arg(get_arg_value("--selected-states="), character()))
    SELECTED_RUN_SCENARIOS <- split_arg(get_arg_value("--selected-scenarios="), character())
    R0_FIT_SCENARIO <- get_arg_value("--r0-fit-scenario=")
    REUSE_BEST_FIT_SIMULATIONS <- get_bool_arg("--reuse-best-fit-simulations=")
    if (!R0_FIT_SCENARIO %in% c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS")) {
      stop("Unknown r0_fit_scenario: ", R0_FIT_SCENARIO)
    }
    SIM_DAY_0_ARG <- get_arg_value("--sim-day-0=")
    SIMULATION_DAYS <- as.integer(get_arg_value("--simulation-days="))
    SIM_REALIZATION_RANGE <- split_numeric_arg(get_arg_value("--sim-realization-range="))
    R0_SEARCH_REALIZATION_RANGE <- split_numeric_arg(get_arg_value("--r0-realization-range="))
    EPYDEMIX_FIT_TARGET <- get_arg_value("--epydemix-fit-target=")
    EPYDEMIX_PEAK_HEIGHT_WEIGHT <- as.numeric(get_arg_value("--epydemix-peak-height-weight="))
    EPYDEMIX_NSIM <- as.integer(get_arg_value("--epydemix-nsim="))
    R0_FIT_METHOD <- get_arg_value("--r0-fit-method=")
    if (R0_FIT_METHOD %in% c("wis_small_states", "wis_county_threshold")) {
      R0_FIT_METHOD <- "simulator_county_threshold"
    }
    sys.source(file.path(repo_root, "scripts", "5c_Rm_search_helpers.R"), envir = environment())
    R0_SELECTION_METRIC = get_arg_value("--r0-selection-metric=")
    R0_SEARCH_METRICS = get_arg_value("--r0-search-metrics=")
    if (R0_SELECTION_METRIC == "all") R0_SELECTION_METRIC <- "peak_height"
    R0_SELECTION_METRIC = parse_r0_search_metrics(R0_SELECTION_METRIC)
    if (length(R0_SELECTION_METRIC) != 1) stop("Choose one final R0 selection metric.")
    R0_SEARCH_METRICS = unique(c(R0_SELECTION_METRIC, parse_r0_search_metrics(R0_SEARCH_METRICS)))
    R0_EXECUTION_MODE = get_arg_value("--execution-mode=")
    R0_WORKERS = get_arg_value("--workers=")
    R0_FIT_LAUNCH = get_arg_value("--r0-fit-launch=")
    if (PIPELINE_PHASE != "all") {
      R0_FIT_LAUNCH <- if (PIPELINE_PHASE == "fit" && EXECUTION_TARGET == "ls6") "pylauncher" else "direct"
    }
    R0_COUNTY_THRESHOLD = as.integer(get_arg_value("--r0-county-threshold="))
    RUN_WEB_PREVIEW = get_bool_arg("--run-web-preview=")
    MAKE_PRE_SIM_FIGS = get_bool_arg("--make-pre-sim-figs=")
    MAKE_VALIDATION_FIGS = get_bool_arg("--make-validation-figs=")
    MAKE_DIAGNOSTIC_FIGS = get_bool_arg("--make-diagnostic-figs=")
    VALIDATION_OUTPUT_SOURCE_REGEX = get_arg_value("--validation-output-source-regex=")
    DEPLOY_SHINYAPPS = get_bool_arg("--deploy-shinyapps=")
    SHINYAPPS_ACCOUNT = get_arg_value("--shinyapps-account=")
    SHINYAPPS_APP_NAME = get_arg_value("--shinyapps-app-name=")

    ACS_YEAR_RANGE = get_arg_value("--acs-year-range=")
    ACS_YEAR = as.integer(sub(".*-", "", ACS_YEAR_RANGE))
    SIM_DAY_0_VALUES <- as.Date(split_arg(SIM_DAY_0_ARG, character()))
    if (any(is.na(SIM_DAY_0_VALUES))) {
      stop("Invalid --sim-day-0 value. Use one date or comma-separated dates like 2025-09-27,2025-10-04.")
    }
    if (length(SIM_REALIZATION_RANGE) != 2 || any(is.na(SIM_REALIZATION_RANGE))) {
      stop("--sim-realization-range must be two comma-separated integers, e.g. 0,9.")
    }
    SIM_REALIZATION_RANGE = as.integer(SIM_REALIZATION_RANGE)
    if (SIM_REALIZATION_RANGE[[2]] < SIM_REALIZATION_RANGE[[1]]) {
      stop("--sim-realization-range end must be greater than or equal to start.")
    }
    if (length(R0_SEARCH_REALIZATION_RANGE) != 2 || any(is.na(R0_SEARCH_REALIZATION_RANGE))) {
      stop("--r0-wis-realization-range must be two comma-separated integers, e.g. 0,9.")
    }
    R0_SEARCH_REALIZATION_RANGE = as.integer(R0_SEARCH_REALIZATION_RANGE)
    if (R0_SEARCH_REALIZATION_RANGE[[2]] < R0_SEARCH_REALIZATION_RANGE[[1]]) {
      stop("--r0-wis-realization-range end must be greater than or equal to start.")
    }
    if (REUSE_BEST_FIT_SIMULATIONS &&
        !identical(SIM_REALIZATION_RANGE, R0_SEARCH_REALIZATION_RANGE)) {
      stop("Reusing best-fit simulations requires matching sim_realization_range and r0_realization_range.")
    }
    if ((REUSE_BEST_FIT_SIMULATIONS || R0_FIT_SCENARIO != "ALL_INTERVENTIONS") &&
        (R0_FIT_METHOD != "simulator_county_threshold" || R0_COUNTY_THRESHOLD < 254L)) {
      stop("Scenario-specific fitting/reuse requires simulator_county_threshold covering all states (255 recommended).")
    }
    SIM_DAY_0 = SIM_DAY_0_VALUES[[1]]
    SIM_DAY_0_LABEL = as.character(SIM_DAY_0)
    if (!EPYDEMIX_FIT_TARGET %in% c("hosp_incident", "hosp_increase")) {
      stop("--epydemix-fit-target must be one of: hosp_incident, hosp_increase.")
    }
    if (!R0_FIT_METHOD %in% c("epydemix_all", "simulator_county_threshold")) {
      stop("--r0-fit-method must be one of: epydemix_all, simulator_county_threshold.")
    }
    if (!R0_FIT_LAUNCH %in% c("direct", "pylauncher")) {
      stop("--r0-fit-launch must be direct or pylauncher.")
    }
    if (R0_FIT_LAUNCH == "pylauncher" && R0_FIT_METHOD != "simulator_county_threshold") {
      stop("PyLauncher preparation is for Section 5c; use --r0-fit-method=simulator_county_threshold.")
    }
    if (!R0_EXECUTION_MODE %in% c("serial", "parallel") ||
      (R0_WORKERS != "auto" && (is.na(suppressWarnings(as.integer(R0_WORKERS))) || as.integer(R0_WORKERS) < 1))) {
      stop("Invalid --execution-mode or --workers.")
    }
    if (is.na(R0_COUNTY_THRESHOLD) || R0_COUNTY_THRESHOLD < 1) {
      stop("--r0-wis-county-threshold must be a positive integer.")
    }
    INPUT_TEMPLATE_DIR = pipeline_input_path(get_arg_value("--input-template-dir="), repo_root)
    NONE_TEMPLATE_FILE = get_arg_value(
      "--none-template=",
      file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_NONE_H3N2.json")
    )
    # Each scenario template is read independently. ALL_INTERVENTIONS does not
    # inherit or merge settings from VACCINE, ANTIVIRAL, or NPI, so keep the
    # combined-template intervention blocks in sync manually when needed.
    INTERVENTION_TEMPLATE_FILES = c(
      VACCINE = get_arg_value("--vaccine-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_VAX_H3N2.json")),
      ANTIVIRAL = get_arg_value("--antiviral-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_ANTIVIRAL_H3N2.json")),
      NPI = get_arg_value("--npi-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_NPI_H3N2.json")),
      ALL_INTERVENTIONS = get_arg_value("--all-interventions-template=", file.path(INPUT_TEMPLATE_DIR, "INPUT_SEIHRD-STOCH_STATE_ALL_INTERVENTIONS_H3N2.json"))
    )
    MOBILITY_YR = as.integer(get_arg_value("--mobility-year="))

    NONE_TEMPLATE_FILE <- pipeline_input_path(NONE_TEMPLATE_FILE, repo_root)
    INTERVENTION_TEMPLATE_FILES <- vapply(INTERVENTION_TEMPLATE_FILES, pipeline_input_path, character(1), repo_root = repo_root)
    # Catch syntax errors before any long-running fitting work starts.
    if (R0_FIT_METHOD == "simulator_county_threshold") {
      invisible(parse(file = file.path(repo_root, "scripts", "5c_Rm_search.R")))
    }
    available_state_dirs <- basename(list.dirs(file.path(repo_root, "data"), recursive = FALSE, full.names = TRUE))
    missing_state_dirs <- setdiff(SELECTED_RUN_STATES, available_state_dirs)
    if (length(missing_state_dirs) > 0) {
      suggestions <- vapply(
        missing_state_dirs,
        closest_state_suggestion,
        character(1),
        available_states = available_state_dirs
      )
      stop(
        "Selected state directory name(s) not found under data/: ",
        paste(
          paste0(missing_state_dirs, " (did you mean ", suggestions, "?)"),
          collapse = ", "
        ),
        ". Use repo state directory names, e.g. New-Mexico and California."
      )
    }
    WEB_PREVIEW_STATES = SELECTED_RUN_STATES
    DASHBOARD_PREVIEW_STATES = SELECTED_RUN_STATES
    DASHBOARD_PREVIEW_OUTPUT_SUBDIRS = if (length(SELECTED_RUN_STATES)) {
      c("WEB_OUTPUTS", "TACC_FILES")
    } else {
      # With no local preview states, ingest and bundle the completed TACC runs.
      VALIDATION_OUTPUT_SOURCE_REGEX <- "TACC_FILES"
      "TACC_FILES"
    }
    if (EXECUTION_TARGET == "ls6") {
      DASHBOARD_PREVIEW_OUTPUT_SUBDIRS <- "TACC_FILES"
      VALIDATION_OUTPUT_SOURCE_REGEX <- "TACC_FILES"
    }
    if (!MOBILITY_YR %in% c(2019L, 2025L)) stop("mobility_year must be 2019 or 2025.")
    if (!is.finite(SIMULATION_DAYS) || SIMULATION_DAYS < 1) stop("simulation_days must be positive.")
  }, envir = envir)
  invisible(loaded)
}

#' Split a comma-separated argument into trimmed values
#'
#' @param value A comma-separated string, NULL, or an empty value.
#' @param default Value returned when `value` is absent or empty.
#' @return A character vector with blank entries removed, or `default`.
split_arg <- function(value, default) {
  if (is.null(value) || length(value) == 0 || !nzchar(value)) return(default)
  pieces <- trimws(unlist(strsplit(value, ",", fixed = TRUE)))
  pieces[nzchar(pieces)]
}
#' Parse a comma-separated numeric argument
#'
#' @param value A comma-separated string of numbers.
#' @param default Values used when `value` is absent or empty.
#' @return A numeric vector. Nonnumeric entries cause an error.
split_numeric_arg <- function(value, default = character()) {
  pieces <- split_arg(value, as.character(default))
  numeric_pieces <- suppressWarnings(as.numeric(pieces))
  if (any(is.na(numeric_pieces))) {
    stop("Expected numeric value(s), got: ", value)
  }
  numeric_pieces
}
#' Convert state labels to repository directory names
#'
#' @param states Character vector of state names or directory names.
#' @return State names with surrounding whitespace removed and internal
#'   whitespace replaced by hyphens.
normalize_state_dir_names <- function(states) {
  gsub("[[:space:]]+", "-", trimws(states))
}
#' Suggest the closest available state directory name
#'
#' @param state A single state name to match.
#' @param available_states Character vector of available state directory names.
#' @return The closest name by case-insensitive edit distance, or NA_character_
#'   when no names are available.
closest_state_suggestion <- function(state, available_states) {
  if (length(available_states) == 0) return(NA_character_)
  distances <- utils::adist(state, available_states, ignore.case = TRUE)
  available_states[which.min(distances)]
}

#' Install missing dependencies and attach pipeline packages
#'
#' Uses pacman to load the R packages required by the orchestration script.
#' Installs pacman itself when it is unavailable.
#'
#' @return The result of pacman::p_load(), invisibly.
#' @details May install packages and attaches packages to the R search path.
load_pipeline_packages <- function() {
  if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")
  pacman::p_load(tidyverse, tidycensus, tigris, sf, reticulate, srvyr,
    ggpmisc, jsonlite, haven, rsconnect)
}

#' Create the output directory and initialize pipeline logging
#'
#' Reads the initialized configuration from `envir`, creates the output root,
#' and records console output, messages, warnings, and errors in a timestamped
#' log. The orchestration script closes the output sink and log connection.
#'
#' @param envir Environment receiving output paths and the log connection.
#' @return The result of registering global calling handlers, invisibly.
#' @details Opens an output sink and installs session-wide condition handlers.
initialize_pipeline_runtime <- function(envir = parent.frame()) {
  evalq({
    pipeline_output_root <- normalizePath(
      if (grepl("^/", PIPELINE_OUTPUT_DIR)) PIPELINE_OUTPUT_DIR else file.path(repo_root, PIPELINE_OUTPUT_DIR),
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
  }, envir = envir)
}

#' Print a pipeline progress banner
#'
#' @param section_label Text identifying the pipeline stage.
#' @return NULL, invisibly. Writes the formatted banner to standard output.
section_banner <- function(section_label) {
  cat(
    "\n\n",
    "#////////\n",
    "#### ", section_label, " ####\n",
    "#////////\n\n",
    sep = ""
  )
}

#' Run a shell command while streaming and recording its output
#'
#' Quotes the command and arguments, optionally changes the working directory,
#' and sends combined stdout and stderr to the console and pipeline log.
#' CENSUS_API_KEY assignments in command output are redacted.
#'
#' @param command Executable name or path.
#' @param args Character vector of arguments passed to the executable.
#' @param workdir Working directory, or NULL to retain the current directory.
#' @return The shell command's exit status, invisibly.
#' @details Requires `pipeline_log_file` in the enclosing pipeline environment.
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

#' Check whether a saved input uses the requested simulation date
#'
#' @param path Path to a simulator input JSON file.
#' @param expected_sim_day_0 Expected simulation start date.
#' @return TRUE when metadata_tags.sim_day_0 matches, otherwise FALSE.
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

#' Check whether an Epydemix fit matches the requested settings
#'
#' Checks the simulation date, hospitalization target, and peak-height weight
#' before reusing an existing calibrated JSON file.
#'
#' @param path Path to a calibrated input JSON file.
#' @param expected_sim_day_0 Expected simulation start date.
#' @param expected_fit_target Requested hospitalization fitting target.
#' @param expected_peak_height_weight Requested peak-height weight.
#' @return TRUE when the saved fit matches the requested settings, otherwise FALSE.
calibrated_fit_matches <- function(path, expected_sim_day_0, expected_fit_target, expected_peak_height_weight) {
  config <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
  sim_day_0 <- tryCatch(config$metadata_tags$sim_day_0, error = function(e) NA_character_)
  if (is.null(sim_day_0)) sim_day_0 <- NA_character_
  epydemix_sim_start <- tryCatch(config$metadata_tags$epydemix_fit$simulation_start_date, error = function(e) NA_character_)
  if (is.null(epydemix_sim_start)) epydemix_sim_start <- NA_character_
  expected_sim_day_0 <- as.character(expected_sim_day_0)
  date_matches <- identical(as.character(sim_day_0), expected_sim_day_0) ||
    identical(as.character(epydemix_sim_start), expected_sim_day_0)
  fit_target <- tryCatch(config$metadata_tags$epydemix_fit$fit_target, error = function(e) NA_character_)
  if (is.null(fit_target)) fit_target <- NA_character_
  generated_metric <- tryCatch(config$metadata_tags$epydemix_fit$generated_metric, error = function(e) NA_character_)
  if (is.null(generated_metric)) generated_metric <- NA_character_
  expected_generated_metric <- if (identical(expected_fit_target, "hosp_increase")) {
    "h_positive_increase"
  } else {
    "admissions"
  }
  target_matches <- identical(as.character(fit_target), as.character(expected_fit_target)) ||
    identical(as.character(generated_metric), expected_generated_metric)
  peak_height_weight <- suppressWarnings(as.numeric(tryCatch(
    config$metadata_tags$epydemix_fit$distance_settings$peak_height_weight,
    error = function(e) NA_real_
  )))
  if (is.null(peak_height_weight)) peak_height_weight <- NA_real_
  peak_height_matches <- isTRUE(all.equal(
    peak_height_weight,
    as.numeric(expected_peak_height_weight),
    tolerance = 1e-12
  ))
  date_matches && target_matches && peak_height_matches
}

#' Check whether a full-simulator R_m fit can be reused
#'
#' Checks the date, fitting method, scoring version, search criteria,
#' realization range, simulation horizon, selection criterion, and scenario.
#' The historical function name also covers criteria other than WIS.
#'
#' @param path Path to a calibrated input JSON file.
#' @param expected_sim_day_0 Expected simulation start date.
#' @param expected_simulation_days Requested simulation horizon in days.
#' @param expected_realization_range Inclusive first and last realization IDs.
#' @param expected_selection_metric Criterion used to select the exported R_m.
#' @param expected_scenario Scenario fitted to observed hospitalizations; defaults
#'   to R0_FIT_SCENARIO, or ALL_INTERVENTIONS when that variable is unavailable.
#' @return TRUE when the saved fit matches the requested settings, otherwise FALSE.
#' @details Reads R0_SCORING_VERSION and R0_SEARCH_METRICS from the enclosing
#'   pipeline environment.
wis_calibrated_fit_matches <- function(path, expected_sim_day_0, expected_simulation_days, expected_realization_range, expected_selection_metric,
                                       expected_scenario = get0("R0_FIT_SCENARIO", ifnotfound = "ALL_INTERVENTIONS")) {
  config <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(config)) return(FALSE)
  sim_day_0 <- tryCatch(config$metadata_tags$sim_day_0, error = function(e) NA_character_)
  if (is.null(sim_day_0)) sim_day_0 <- NA_character_
  wis_sim_start <- tryCatch(config$metadata_tags$epydemix_fit$simulation_start_date, error = function(e) NA_character_)
  if (is.null(wis_sim_start)) wis_sim_start <- NA_character_
  expected_sim_day_0 <- as.character(expected_sim_day_0)
  date_matches <- identical(as.character(sim_day_0), expected_sim_day_0) ||
    identical(as.character(wis_sim_start), expected_sim_day_0)
  fit_method <- tryCatch(config$metadata_tags$epydemix_fit$method, error = function(e) NA_character_)
  if (is.null(fit_method)) fit_method <- NA_character_
  simulation_days <- suppressWarnings(as.integer(tryCatch(
    config$metadata_tags$epydemix_fit$distance_settings$simulation_days,
    error = function(e) NA_integer_
  )))
  realization_range <- suppressWarnings(as.integer(tryCatch(
    config$metadata_tags$epydemix_fit$distance_settings$realization_range,
    error = function(e) c(NA_integer_, NA_integer_)
  )))
  selection_metric <- tryCatch(
    config$metadata_tags$epydemix_fit$distance_settings$r0_selection_metric,
    error = function(e) NA_character_
  )
  if (is.null(selection_metric)) {
    selection_metric <- tryCatch(
      config$metadata_tags$r0_search$r0_selection_metric,
      error = function(e) NA_character_
    )
  }
  if (is.null(selection_metric)) selection_metric <- NA_character_
  fit_scenario <- config$metadata_tags$epydemix_fit$distance_settings$scenario_label
  if (is.null(fit_scenario)) fit_scenario <- config$metadata_tags$r0_search$scenario_label
  if (is.null(fit_scenario)) fit_scenario <- "ALL_INTERVENTIONS"
  date_matches &&
    identical(fit_scenario, expected_scenario) &&
    identical(as.character(fit_method), "full_simulator_all_interventions_state_feature_search") &&
    identical(simulation_days, as.integer(expected_simulation_days)) &&
    identical(config$metadata_tags$epydemix_fit$distance_settings$scoring_version, R0_SCORING_VERSION) &&
    identical(as.character(unlist(config$metadata_tags$epydemix_fit$distance_settings$search_metrics)), R0_SEARCH_METRICS) &&
    identical(realization_range, as.integer(expected_realization_range)) &&
    identical(as.character(selection_metric), as.character(expected_selection_metric))
}

#' Select completed best-fit batches for downstream analyses
#'
#' Finds the winning candidate for each calibrated state and date, verifies
#' its settings and realization IDs, and records the selected metadata paths.
#' Falls back to searching saved sweep outputs when an LS6 path has moved.
#'
#' @param envir Environment containing the pipeline settings and receiving
#'   REUSED_FIT_OUTPUTS and the updated validation source filter.
#' @return NULL, invisibly, after reporting the number of reused batches.
#' @details Writes reused_fit_outputs.csv under the pipeline output root.
#'   An empty manifest is written when reuse is disabled or the fitting scenario
#'   is excluded from selected_scenarios. Missing or incomplete requested batches
#'   cause an error before rerun commands are omitted.
prepare_reused_fit_outputs <- function(envir = parent.frame()) {
  evalq({
    REUSED_FIT_OUTPUTS <- data.frame(state = character(), sim_day_0 = character(),
      scenario = character(), metadata_file = character())
    if (REUSE_BEST_FIT_SIMULATIONS && R0_FIT_SCENARIO %in% SELECTED_RUN_SCENARIOS) {
      for (date in as.character(SIM_DAY_0_VALUES)) {
        fit_files <- list.files(file.path(pipeline_output_root, "epydemix_fit", date),
          pattern = "_EPYDEMIX_R0_ONLY\\.json$", recursive = TRUE, full.names = TRUE)
        if (!length(fit_files)) stop("No calibrated fits available to reuse for ", date)
        candidates <- list.files(file.path(pipeline_output_root, "Rm_search", date),
          pattern = "^metadata_batch-.*\\.json$", recursive = TRUE, full.names = TRUE)
        for (fit_file in fit_files) {
          fit <- jsonlite::read_json(fit_file)
          if (!wis_calibrated_fit_matches(fit_file, date, SIMULATION_DAYS,
                R0_SEARCH_REALIZATION_RANGE, R0_SELECTION_METRIC)) {
            stop("Fit does not match the requested reuse settings: ", fit_file)
          }
          state <- sub("^INPUT_SEIHRD-STOCH_", "", sub("_SEED_NONE_EPYDEMIX_R0_ONLY\\.json$", "", basename(fit_file)))
          chosen <- fit$metadata_tags$r0_search$selected_metadata_file
          # A saved LS6 absolute path may have moved when results were copied.
          paths <- unique(c(chosen, candidates))
          paths <- paths[!is.na(paths) & file.exists(paths)]
          #' Check a saved batch against the selected calibrated fit
          #'
          #' @param path Path to a candidate metadata JSON file.
          #' @return TRUE when the candidate matches the enclosing state's scenario, date,
          #'   horizon, and R_m and contains every requested realization ID, otherwise FALSE.
          matches_candidate <- function(path) {
            m <- jsonlite::read_json(path)
            if (!identical(m$metadata_tags$scenario_label, R0_FIT_SCENARIO) ||
                !identical(m$metadata_tags$state_dir, state) ||
                !identical(m$metadata_tags$sim_day_0, date) ||
                !identical(as.integer(m$cli_args$days), SIMULATION_DAYS) ||
                !isTRUE(all.equal(as.numeric(m$disease_model$parameters$R0),
                  as.numeric(fit$disease_model$parameters$R0), tolerance = 1e-5))) return(FALSE)
            timing <- file.path(dirname(path), paste0("simulation_times_batch-", m$batch_num, ".csv"))
            if (!file.exists(timing)) return(FALSE)
            ids <- readr::read_csv(timing, show_col_types = FALSE)$sim_id
            identical(sort(unique(as.integer(ids))), seq.int(SIM_REALIZATION_RANGE[1], SIM_REALIZATION_RANGE[2]))
          }
          selected_path <- NA_character_
          for (path in paths) {
            if (matches_candidate(path)) {
              selected_path <- path
              break
            }
          }
          if (is.na(selected_path)) stop("No complete best-fit batch available for ", state, " / ", date,
            ". Resume 5c with the original outputs before enabling reuse.")
          REUSED_FIT_OUTPUTS <- rbind(REUSED_FIT_OUTPUTS, data.frame(state = state,
            sim_day_0 = date, scenario = R0_FIT_SCENARIO,
            metadata_file = normalizePath(selected_path, mustWork = TRUE)))
        }
      }
    }
    readr::write_csv(REUSED_FIT_OUTPUTS, file.path(pipeline_output_root, "reused_fit_outputs.csv"))
    if (nrow(REUSED_FIT_OUTPUTS) && nzchar(VALIDATION_OUTPUT_SOURCE_REGEX)) {
      VALIDATION_OUTPUT_SOURCE_REGEX <- paste(c(VALIDATION_OUTPUT_SOURCE_REGEX,
        paste0("\\Q", REUSED_FIT_OUTPUTS$metadata_file, "\\E")), collapse = "|")
    }
    message("Reusing ", nrow(REUSED_FIT_OUTPUTS), " best-fit batches for downstream analyses.")
  }, envir)
}

#' Extract the state directory name from a seed filename
#'
#' @param path Path to an INPUT_SEIHRD-STOCH_<state>_SEED_NONE.json file.
#' @return The state directory name extracted from the filename.
state_dir_from_seed_file <- function(path) {
  basename(path) %>%
    stringr::str_remove("^INPUT_SEIHRD-STOCH_") %>%
    stringr::str_remove("_SEED_NONE\\.json$")
}

#' Count counties in a state's population input
#'
#' Prefers the configured ACS year range and otherwise uses the first matching
#' county population CSV available for the state.
#'
#' @param state_dir Repository state directory name, such as New-Jersey.
#' @return The number of rows in the state's county population CSV.
#' @details Reads repo_root and ACS_YEAR_RANGE from the enclosing pipeline
#'   environment. Missing population files cause an error.
county_count_for_state <- function(state_dir) {
  pop_files <- list.files(
    file.path(repo_root, "data", state_dir),
    pattern = paste0("^county_pop_by_age_", state_dir, "_", ACS_YEAR_RANGE, "ACS\\.csv$"),
    full.names = TRUE
  )
  if (length(pop_files) == 0) {
    pop_files <- list.files(
      file.path(repo_root, "data", state_dir),
      pattern = paste0("^county_pop_by_age_", state_dir, "_.*ACS\\.csv$"),
      full.names = TRUE
    )
  }
  if (length(pop_files) == 0) {
    stop("No county population file found for ", state_dir, " under data/", state_dir, ".")
  }
  nrow(readr::read_csv(pop_files[[1]], show_col_types = FALSE))
}

#' Express a filesystem path relative to another directory
#'
#' @param path Absolute path to express relative to from.
#' @param from Directory from which the returned path will be used.
#' @return A relative path, or a dot when both paths are identical.
pipeline_relative_path <- function(path, from) {
  target <- strsplit(normalizePath(path, mustWork = FALSE), "/", fixed = TRUE)[[1]]
  origin <- strsplit(normalizePath(from, mustWork = FALSE), "/", fixed = TRUE)[[1]]
  common <- 0L
  while (common < min(length(target), length(origin)) &&
         target[[common + 1L]] == origin[[common + 1L]]) common <- common + 1L
  parts <- c(rep("..", length(origin) - common), tail(target, length(target) - common))
  if (length(parts)) paste(parts, collapse = "/") else "."
}

#' Build a shell-safe command prefix for optional LS6 container execution.
ls6_command_prefix <- function(command, batch_dir, image = "", repo_root,
                               execution_target = "local") {
  if (execution_target != "ls6") return(command)
  wrapper <- pipeline_relative_path(file.path(repo_root, "scripts", "ls6_container_exec.sh"), batch_dir)
  image_args <- if (is.null(image) || !nzchar(image)) "" else paste(" --image", shQuote(image))
  paste0("bash ", shQuote(wrapper), image_args, " ", command)
}

#' Ensure a generated container launcher loads Apptainer, preserving user edits.
ensure_ls6_apptainer_module <- function(shell_file, execution_target = "local") {
  if (execution_target != "ls6") return(invisible(NULL))
  lines <- readLines(shell_file)
  if (any(grepl("^[[:space:]]*module[[:space:]]+load[[:space:]].*tacc-apptainer", lines))) {
    return(invisible(NULL))
  }
  position <- grep("^[[:space:]]*(module[[:space:]]+load[[:space:]]+pylauncher|python3[[:space:]])", lines)
  if (!length(position)) stop("Cannot locate PyLauncher startup in ", shell_file)
  lines <- append(lines, "module load tacc-apptainer", after = position[[1]] - 1L)
  writeLines(lines, shell_file)
  invisible(NULL)
}

#' Write state-level R_m fitting commands for LS6 PyLauncher
#'
#' Commands run from batch_dir using relative script paths. When configured,
#' LS6_CONTAINER_IMAGE selects the image used by the shared runtime wrapper.
#' Existing allocation settings are retained; container jobs load Apptainer.
#'
#' @param states Character vector of state directory names to fit.
#' @param fit_args Character vector of Rscript arguments for the fitting stage.
#' @param batch_dir Directory receiving commands, launchers, and state logs.
#' @return The generated shell commands, invisibly.
#' @details Reads repo_root from the enclosing pipeline environment. Does not
#'   submit jobs or launch simulations.
write_rm_fit_launcher <- function(states, fit_args, batch_dir) {
  # States share inputs and simulation directories, but write private checkpoint
  # and log files. Combined sweep tables are published by the scenarios phase.
  # Enforce queue order here as well as upstream so every caller gets the same
  # fewest-to-most-counties ordering, with state name breaking ties.
  county_counts <- vapply(states, county_count_for_state, integer(1))
  state_order <- order(county_counts, states)
  states <- states[state_order]
  county_counts <- county_counts[state_order]
  message("State fit command order by county count: ",
    paste0(states, " (", county_counts, ")", collapse = ", "))
  dir.create(batch_dir, recursive = TRUE, showWarnings = FALSE)
  batch_dir <- normalizePath(batch_dir, mustWork = TRUE)
  dir.create(file.path(batch_dir, "logs"), showWarnings = FALSE)
  script <- pipeline_relative_path(file.path(repo_root, "scripts", "5c_Rm_search.R"), batch_dir)
  image <- get0("LS6_CONTAINER_IMAGE", ifnotfound = "")
  target <- get0("EXECUTION_TARGET", ifnotfound = "local")
  command_prefix <- ls6_command_prefix("Rscript", batch_dir, image, repo_root, target)
  # Direct Rscript calls keep each line readable; input initialization already
  # parsed the fitting script before any launch files were written.
  fit_args <- c(script, fit_args[-seq_len(if (fit_args[[1]] == "-e") 2L else 1L)])
  fit_args <- vapply(fit_args, function(arg) {
    if (grepl("^--[^=]+=", arg)) {
      value <- sub("^--[^=]+=", "", arg)
      if (startsWith(value, "/")) {
        return(paste0(sub("=.*$", "", arg), "=", pipeline_relative_path(value, repo_root)))
      }
    }
    arg
  }, character(1), USE.NAMES = FALSE)
  commands <- vapply(states, function(state) {
    state_args <- fit_args
    state_args[startsWith(state_args, "--selected-states=")] <- paste0("--selected-states=", state)
    state_args <- c(state_args, "--state-output-subdir=false",
      "--defer-sweep-tables=true",
      paste0("--shared-figure-dir=", pipeline_relative_path(file.path(batch_dir, "plots"), repo_root)),
      "--source-5a-if-missing=false", "--source-6d-if-missing=false")
    quoted <- vapply(state_args, function(arg) {
      if (grepl("^[A-Za-z0-9_./=,:+-]+$", arg)) arg else shQuote(arg)
    }, character(1), USE.NAMES = FALSE)
    paste0(command_prefix, " ", paste(quoted, collapse = " "),
      " > logs/", state, "_fit.log 2>&1")
  }, character(1), USE.NAMES = FALSE)
  writeLines(commands, file.path(batch_dir, "fit_state_commands.txt"))
  python_template <- readLines(file.path(repo_root, "data", "INPUT_FILE_TEMPLATES", "state_pylauncher.py"))
  writeLines(gsub("state_commands.txt", "fit_state_commands.txt", python_template, fixed = TRUE),
    file.path(batch_dir, "fit_state_pylauncher.py"))
  shell_file <- file.path(batch_dir, "fit_state_pylauncher.sh")
  if (!file.exists(shell_file)) {
    template <- readLines(file.path(repo_root, "data", "INPUT_FILE_TEMPLATES", "state_pylauncher.sh"))
    template <- gsub("state_pylauncher.py", "fit_state_pylauncher.py", template, fixed = TRUE)
    template <- gsub("state_commands.txt", "fit_state_commands.txt", template, fixed = TRUE)
    template <- sub("^(#SBATCH[[:space:]]+-J[[:space:]]+)[^[:space:]]+", "\\1fit_state_Rm", template)
    template <- sub("^(#SBATCH[[:space:]]+-o[[:space:]]+)[^[:space:]]+", "\\1fit_state_Rm.%j.o", template)
    template <- sub("^(#SBATCH[[:space:]]+-e[[:space:]]+)[^[:space:]]+", "\\1fit_state_Rm.%j.e", template)
    writeLines(template, shell_file)
  }
  ensure_ls6_apptainer_module(shell_file, target)
  message("Prepared ", length(commands), " state fit commands using the PyLauncher template:\n  ", batch_dir,
    "\nSet the allocation in fit_state_pylauncher.sh, then submit it from that directory.")
  invisible(commands)
}

#' Print the initialized pipeline settings
#'
#' Reports the input file, simulation settings, fitting choices, selected
#' scenarios, and deployment settings to the console and active pipeline log.
#'
#' @return NULL, invisibly.
#' @details Reads configuration and logging variables from the enclosing pipeline
#'   environment; call after initializing inputs and runtime logging.
log_pipeline_settings <- function() {
  cat("Input file: ", PIPELINE_CONFIG_FILE, "\n", sep = "")
  section_banner("Section 0 Pipeline Settings")
  cat("Pipeline log file: ", pipeline_log_file, "\n", sep = "")
  cat("Pipeline settings:\n")
  cat("  PIPELINE_PHASE = ", PIPELINE_PHASE, "\n", sep = "")
  cat("  EXECUTION_TARGET = ", EXECUTION_TARGET, "\n", sep = "")
  cat("  ACS_YEAR_RANGE = ", ACS_YEAR_RANGE, "\n", sep = "")
  cat("  ACS_YEAR = ", ACS_YEAR, "\n", sep = "")
  cat("  SIM_DAY_0 = ", paste(as.character(SIM_DAY_0_VALUES), collapse = ", "), "\n", sep = "")
  cat("  SIMULATION_DAYS = ", SIMULATION_DAYS, "\n", sep = "")
  cat("  SIM_REALIZATION_RANGE = ", paste(SIM_REALIZATION_RANGE, collapse = ", "), "\n", sep = "")
  cat("  R0_SEARCH_REALIZATION_RANGE = ", paste(R0_SEARCH_REALIZATION_RANGE, collapse = ", "), "\n", sep = "")
  cat("  PIPELINE_OUTPUT_DIR = ", PIPELINE_OUTPUT_DIR, "\n", sep = "")
  cat("  NONE_TEMPLATE_FILE = ", NONE_TEMPLATE_FILE, "\n", sep = "")
  cat("  INTERVENTION_TEMPLATE_FILES = ", paste(names(INTERVENTION_TEMPLATE_FILES), INTERVENTION_TEMPLATE_FILES, sep = ":", collapse = ", "), "\n", sep = "")
  cat("  EPYDEMIX_NSIM = ", EPYDEMIX_NSIM, "\n", sep = "")
  cat("  EPYDEMIX_FIT_TARGET = ", EPYDEMIX_FIT_TARGET, "\n", sep = "")
  cat("  EPYDEMIX_PEAK_HEIGHT_WEIGHT = ", EPYDEMIX_PEAK_HEIGHT_WEIGHT, "\n", sep = "")
  cat("  R0_FIT_METHOD = ", R0_FIT_METHOD, "\n", sep = "")
  cat("  R0_SELECTION_METRIC = ", R0_SELECTION_METRIC, "\n", sep = "")
  cat("  R0_FIT_SCENARIO = ", R0_FIT_SCENARIO, "\n", sep = "")
  cat("  REUSE_BEST_FIT_SIMULATIONS = ", REUSE_BEST_FIT_SIMULATIONS, "\n", sep = "")
  cat("  R0_SEARCH_METRICS = ", paste(R0_SEARCH_METRICS, collapse = ","), "\n", sep = "")
  cat("  R0_COUNTY_THRESHOLD = ", R0_COUNTY_THRESHOLD, "\n", sep = "")
  cat("  R0_FIT_LAUNCH = ", R0_FIT_LAUNCH, "\n", sep = "")
  cat("  RUN_WEB_PREVIEW = ", RUN_WEB_PREVIEW, "\n", sep = "")
  cat("  MAKE_PRE_SIM_FIGS = ", MAKE_PRE_SIM_FIGS, "\n", sep = "")
  cat("  MAKE_VALIDATION_FIGS = ", MAKE_VALIDATION_FIGS, "\n", sep = "")
  cat("  MAKE_DIAGNOSTIC_FIGS = ", MAKE_DIAGNOSTIC_FIGS, "\n", sep = "")
  cat("  VALIDATION_OUTPUT_SOURCE_REGEX = ", VALIDATION_OUTPUT_SOURCE_REGEX, "\n", sep = "")
  cat("  SELECTED_RUN_STATES = ", paste(SELECTED_RUN_STATES, collapse = ", "), "\n", sep = "")
  cat("  SELECTED_RUN_SCENARIOS = ", paste(SELECTED_RUN_SCENARIOS, collapse = ", "), "\n", sep = "")
  cat("  DEPLOY_SHINYAPPS = ", DEPLOY_SHINYAPPS, "\n", sep = "")
  cat("  SHINYAPPS_ACCOUNT = ", ifelse(nzchar(SHINYAPPS_ACCOUNT), SHINYAPPS_ACCOUNT, "<not set>"), "\n", sep = "")
  cat("  SHINYAPPS_APP_NAME = ", SHINYAPPS_APP_NAME, "\n", sep = "")
}

#' Publish combined sweep tables after all LS6 state fits have completed
#'
#' @param states State directory names to combine, defaulting to all states/DC.
#' @return TRUE, invisibly. Incomplete or mismatched state checkpoints cause an
#'   error before combined CSVs are written.
#' @details Reads state-specific RDS files in each date's checkpoints directory
#'   and atomically publishes Rm_search_*.csv tables in the shared date directory.
#'   Called once by the scenarios phase; performs no fitting or simulations.
aggregate_rm_search_checkpoints <- function(states = gsub(" ", "-", c(state.name, "District of Columbia"))) {
  for (date in as.character(SIM_DAY_0_VALUES)) {
    root <- file.path(pipeline_output_root, "Rm_search", date)
    checkpoints <- file.path(root, "checkpoints")
    expected <- list(sim_day_0 = date, scenario = R0_FIT_SCENARIO,
      simulation_days = as.integer(SIMULATION_DAYS), realization_range = as.integer(R0_SEARCH_REALIZATION_RANGE),
      selection_metric = R0_SELECTION_METRIC, search_metrics = R0_SEARCH_METRICS,
      scoring_version = R0_SCORING_VERSION)
    required <- c("search_trace", "scores_by_week", "quantile_predictions", "best_by_state",
      "summary", "featured_candidate_comparison", "calibrated_json_manifest")
    tables <- list()
    missing <- character()
    for (state in states) {
      prefix <- paste0(state, "_Rm_search_")
      settings <- file.path(checkpoints, paste0(prefix, "settings.rds"))
      paths <- file.path(checkpoints, paste0(prefix, required, ".rds"))
      if (!file.exists(settings) || !identical(readRDS(settings), expected) || !all(file.exists(paths))) {
        missing <- c(missing, state)
        next
      }
      stem <- paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE")
      fit_path <- file.path(pipeline_output_root, "epydemix_fit", date, stem,
        paste0(stem, "_EPYDEMIX_R0_ONLY.json"))
      best <- readRDS(file.path(checkpoints, paste0(prefix, "best_by_state.rds")))
      fit <- jsonlite::read_json(fit_path)
      if (nrow(best) != 1L || !isTRUE(all.equal(as.numeric(best$disease_R0),
          as.numeric(fit$disease_model$parameters$R0), tolerance = 1e-5))) {
        missing <- c(missing, state)
        next
      }
      paths <- list.files(checkpoints, full.names = TRUE)
      paths <- paths[startsWith(basename(paths), prefix) & endsWith(paths, ".rds") & paths != settings]
      for (path in paths) {
        name <- sub("\\.rds$", ".csv", substring(basename(path), nchar(state) + 2L))
        tables[[name]] <- dplyr::bind_rows(tables[[name]], readRDS(path))
      }
    }
    if (length(missing)) stop("Finish state fitting checkpoints before preparing scenarios for ", date,
      ": ", paste(missing, collapse = ", "))
    for (name in names(tables)) {
      path <- file.path(root, name)
      temporary <- tempfile(pattern = ".sweep-table-", tmpdir = root)
      readr::write_csv(tables[[name]], temporary)
      if (!file.rename(temporary, path)) stop("Could not publish combined sweep table: ", path)
    }
    message("Published ", length(tables), " combined Rm_search CSV tables for ", date, ".")
  }
  invisible(TRUE)
}

#' Require matching completed calibrations before a later pipeline phase
#'
#' @param states State directory names whose fits must exist; defaults to all
#'   50 states and the District of Columbia.
#' @return TRUE, invisibly. Missing or outdated fits cause an error identifying
#'   the state/date pairs to finish. No fitting commands are executed.
#' @details Uses initialized settings and pipeline_output_root from the
#'   enclosing pipeline environment.
require_completed_pipeline_fits <- function(states = gsub(" ", "-", c(state.name, "District of Columbia"))) {
  missing <- character()
  for (date in as.character(SIM_DAY_0_VALUES)) {
    for (state in states) {
      stem <- paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE")
      path <- file.path(pipeline_output_root, "epydemix_fit", date, stem,
        paste0(stem, "_EPYDEMIX_R0_ONLY.json"))
      full_simulator <- R0_FIT_METHOD == "simulator_county_threshold" &&
        county_count_for_state(state) <= R0_COUNTY_THRESHOLD
      matches <- file.exists(path) && if (full_simulator) {
        wis_calibrated_fit_matches(path, date, SIMULATION_DAYS,
          R0_SEARCH_REALIZATION_RANGE, R0_SELECTION_METRIC)
      } else calibrated_fit_matches(path, date, EPYDEMIX_FIT_TARGET, EPYDEMIX_PEAK_HEIGHT_WEIGHT)
      if (!matches) missing <- c(missing, paste(state, date, sep = " / "))
    }
  }
  if (length(missing)) stop("Finish the fit phase before continuing. Missing or outdated fits: ",
    paste(missing, collapse = ", "))
  invisible(TRUE)
}

#' Require complete scenario batches before ingesting or plotting results
#'
#' @param states State directory names to check. By default checks selected
#'   local states, or all states and DC when the selection is empty.
#' @return TRUE, invisibly. Missing inputs or incomplete batches cause an error
#'   listing state/date/scenario combinations. Never starts simulations.
#' @details Checks the requested R_m, simulation horizon, realization IDs,
#'   network export, and node export presence for each selected scenario.
#'   Includes the chosen fitting batches recorded in REUSED_FIT_OUTPUTS.
require_completed_scenario_outputs <- function(states = if (length(SELECTED_RUN_STATES))
    SELECTED_RUN_STATES else gsub(" ", "-", c(state.name, "District of Columbia"))) {
  roots <- file.path(pipeline_output_root, if (EXECUTION_TARGET == "ls6") "TACC_FILES"
    else c("WEB_OUTPUTS", "TACC_FILES"))
  files <- unlist(lapply(roots, list.files, pattern = "^metadata_batch-.*\\.json$",
    recursive = TRUE, full.names = TRUE), use.names = FALSE)
  files <- unique(c(files, REUSED_FIT_OUTPUTS$metadata_file))
  metadata <- lapply(files, function(path) tryCatch(jsonlite::read_json(path), error = function(e) NULL))
  keys <- vapply(metadata, function(m) {
    if (is.null(m$metadata_tags)) return("")
    paste(m$metadata_tags$state_dir, m$metadata_tags$sim_day_0,
      m$metadata_tags$scenario_label, sep = "|")
  }, character(1))
  index <- split(seq_along(files), keys)
  missing <- character()
  for (date in as.character(SIM_DAY_0_VALUES)) {
    for (state in states) {
      for (scenario in SELECTED_RUN_SCENARIOS) {
        input <- file.path(pipeline_output_root, "TACC_FILES", date,
          paste0("INPUT_", state, "_", scenario, ".json"))
        complete <- FALSE
        if (file.exists(input)) {
          expected <- jsonlite::read_json(input)
          candidates <- index[[paste(state, date, scenario, sep = "|")]]
          reused <- REUSED_FIT_OUTPUTS$metadata_file[REUSED_FIT_OUTPUTS$state == state &
            REUSED_FIT_OUTPUTS$sim_day_0 == date & REUSED_FIT_OUTPUTS$scenario == scenario]
          for (i in candidates) {
            if (length(reused) && !files[[i]] %in% reused) next
            m <- metadata[[i]]
            if (!identical(as.integer(m$cli_args$days), SIMULATION_DAYS) ||
                !isTRUE(all.equal(as.numeric(m$disease_model$parameters$R0),
                  as.numeric(expected$disease_model$parameters$R0), tolerance = 1e-5))) next
            folder <- dirname(files[[i]])
            timing <- file.path(folder, paste0("simulation_times_batch-", m$batch_num, ".csv"))
            network <- file.path(folder, paste0("network_batch-", m$batch_num, ".csv"))
            if (!file.exists(timing) || !file.exists(network)) next
            nodes <- list.files(folder, pattern = "^node_.*\\.csv$")
            nodes <- nodes[endsWith(nodes, paste0("_batch-", m$batch_num, ".csv"))]
            expected_nodes <- if (is.null(m$geo$node_count)) 1L else as.integer(m$geo$node_count)
            if (length(nodes) < expected_nodes) next
            ids <- readr::read_csv(timing, show_col_types = FALSE)$sim_id
            complete <- identical(sort(unique(as.integer(ids))),
              seq.int(SIM_REALIZATION_RANGE[1], SIM_REALIZATION_RANGE[2]))
            if (complete) break
          }
        }
        if (!complete) missing <- c(missing, paste(state, date, scenario, sep = " / "))
      }
    }
  }
  if (length(missing)) stop("Finish the scenarios phase before processing results. Missing or incomplete outputs: ",
    paste(missing, collapse = ", "))
  invisible(TRUE)
}

#' Ensure state seed inputs and hospitalization validation data exist
#'
#' Checks the current simulation date's state and county exposure estimates,
#' seed JSON files, and validation CSV files for all 50 states plus DC.
#' Sources Section 5a when the expected inputs are missing or outdated.
#'
#' @return NULL, invisibly, when existing files are reused; otherwise the result
#'   of sourcing Section 5a, invisibly.
#' @details Reads pipeline_output_root and SIM_DAY_0_LABEL and the settings used
#'   by Section 5a from the enclosing pipeline environment. May write seed inputs,
#'   exposure estimates, and validation data.
prepare_pipeline_seeds <- function() {
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
}

#' Run or prepare the hospitalization fitting stage
#'
#' Reuses matching calibrated inputs and fits remaining states with Epydemix
#' or the full simulator according to the configured county threshold.
#' Full-simulator fitting uses the requested scenario and selection criterion.
#' PyLauncher mode prepares state commands instead of starting the fits.
#'
#' @return TRUE invisibly when direct fitting is complete or existing fits are
#'   reusable; FALSE invisibly after preparing PyLauncher commands.
#' @details Reads initialized pipeline settings from the enclosing environment.
#'   May source intervention preparation scripts, create inputs and fit outputs,
#'   execute fitting commands, or write launcher files. Failed commands cause
#'   an error. PyLauncher mode does not submit jobs.
run_pipeline_fits <- function() {
  #' Fit the requested seed inputs with Epydemix
  #'
  #' Uses the all-states command when every seed is requested; otherwise runs
  #' one fitting command per input file.
  #'
  #' @param input_files Character vector of seed input JSON paths to fit.
  #' @return TRUE, invisibly. A nonzero fitting command exit status causes an error.
  #' @details Uses fitting settings and paths from the enclosing run_pipeline_fits()
  #'   call and writes calibrated JSON files through the Python fitting script.
  run_epydemix_batch <- function(input_files) {
    if (length(input_files) == 0) return(invisible(TRUE))
    if (length(input_files) == length(epydemix_seed_files)) {
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
        "--fit-target",
        EPYDEMIX_FIT_TARGET,
        "--peak-height-weight",
        as.character(EPYDEMIX_PEAK_HEIGHT_WEIGHT),
        "--write-calibrated-json"
      )
      cat("Epydemix command:\n")
      cat("  poetry ", paste(shQuote(epydemix_args), collapse = " "), "\n", sep = "")
      epydemix_status <- run_logged_command("poetry", epydemix_args, workdir = repo_root)
      if (!identical(epydemix_status, 0L)) {
        stop("Epydemix fitting failed with exit status ", epydemix_status)
      }
      return(invisible(TRUE))
    }

    for (input_file in input_files) {
      state_output_dir <- file.path(epydemix_output_dir, tools::file_path_sans_ext(basename(input_file)))
      dir.create(state_output_dir, recursive = TRUE, showWarnings = FALSE)
      epydemix_args <- c(
        "run",
        "python3",
        file.path(repo_root, "scripts", "5b_epydemix_fit_seihrd_hospitalizations.py"),
        "--input-json",
        input_file,
        "--output-dir",
        state_output_dir,
        "--nsim",
        as.character(EPYDEMIX_NSIM),
        "--fit-target",
        EPYDEMIX_FIT_TARGET,
        "--peak-height-weight",
        as.character(EPYDEMIX_PEAK_HEIGHT_WEIGHT),
        "--write-calibrated-json"
      )
      cat("Epydemix command:\n")
      cat("  poetry ", paste(shQuote(epydemix_args), collapse = " "), "\n", sep = "")
      epydemix_status <- run_logged_command("poetry", epydemix_args, workdir = repo_root)
      if (!identical(epydemix_status, 0L)) {
        stop("Epydemix fitting failed for ", input_file, " with exit status ", epydemix_status)
      }
    }
    invisible(TRUE)
  }

  epydemix_input_dir <- normalizePath(
    file.path(pipeline_output_root, "SEED_INPUT_JSONS", SIM_DAY_0_LABEL),
    mustWork = FALSE
  )
  epydemix_output_dir <- normalizePath(
    file.path(pipeline_output_root, "epydemix_fit", SIM_DAY_0_LABEL),
    mustWork = FALSE
  )
  dir.create(epydemix_output_dir, showWarnings = FALSE, recursive = TRUE)
  epydemix_seed_files <- list.files(
    epydemix_input_dir,
    pattern = "^INPUT_SEIHRD-STOCH_.*_SEED_NONE\\.json$",
    full.names = TRUE
  )
  seed_fit_states <- vapply(epydemix_seed_files, state_dir_from_seed_file, character(1))
  expected_calibrated_jsons <- file.path(
    epydemix_output_dir,
    tools::file_path_sans_ext(basename(epydemix_seed_files)),
    paste0(tools::file_path_sans_ext(basename(epydemix_seed_files)), "_EPYDEMIX_R0_ONLY.json")
  )
  names(expected_calibrated_jsons) <- seed_fit_states
  epydemix_calibrated_jsons_match <- length(expected_calibrated_jsons) >= 51 &&
    all(file.exists(expected_calibrated_jsons)) &&
    all(vapply(
      expected_calibrated_jsons,
      calibrated_fit_matches,
      logical(1),
      expected_sim_day_0 = SIM_DAY_0_LABEL,
      expected_fit_target = EPYDEMIX_FIT_TARGET,
      expected_peak_height_weight = EPYDEMIX_PEAK_HEIGHT_WEIGHT
    ))

  if (R0_FIT_METHOD == "epydemix_all") {
    if (length(epydemix_seed_files) >= 51 && epydemix_calibrated_jsons_match) {
      cat(
        "Epydemix calibrated JSONs already exist for sim_day_0 ",
        SIM_DAY_0_LABEL,
        ", fit_target ",
        EPYDEMIX_FIT_TARGET,
        ", and peak_height_weight ",
        EPYDEMIX_PEAK_HEIGHT_WEIGHT,
        ": ",
        length(expected_calibrated_jsons),
        " state/DC fits.\n",
        sep = ""
      )
    } else {
      cat(
        "Epydemix calibrated JSONs missing or not all for sim_day_0 ",
        SIM_DAY_0_LABEL,
        ", fit_target ",
        EPYDEMIX_FIT_TARGET,
        ", and peak_height_weight ",
        EPYDEMIX_PEAK_HEIGHT_WEIGHT,
        "; running 5b.\n",
        sep = ""
      )
      run_epydemix_batch(epydemix_seed_files)
    }
  } else if (R0_FIT_METHOD == "simulator_county_threshold") {
    county_counts <- tibble(
      state_dir = seed_fit_states,
      input_file = epydemix_seed_files,
      calibrated_json = unname(expected_calibrated_jsons[seed_fit_states]),
      county_count = vapply(seed_fit_states, county_count_for_state, integer(1))
    )
    wis_fit_states <- county_counts %>%
      dplyr::filter(.data$county_count <= R0_COUNTY_THRESHOLD)
    epydemix_fit_states <- county_counts %>%
      dplyr::filter(.data$county_count > R0_COUNTY_THRESHOLD)
    if (R0_FIT_LAUNCH == "pylauncher" && nrow(epydemix_fit_states) > 0) {
      stop("Section 5c PyLauncher preparation requires --r0-county-threshold to cover all states (255 for all states/DC).")
    }

    cat(
      "R0 fit method simulator_county_threshold: using the full simulator for ",
      nrow(wis_fit_states),
      " state/DC inputs with county_count <= ",
      R0_COUNTY_THRESHOLD,
      " using final R0 selection metric ",
      R0_SELECTION_METRIC,
      ", and Epydemix for ",
      nrow(epydemix_fit_states),
      " larger state inputs.\n",
      sep = ""
    )

    epydemix_missing_or_stale <- epydemix_fit_states %>%
      dplyr::filter(
        !file.exists(.data$calibrated_json) |
          !vapply(
            .data$calibrated_json,
            calibrated_fit_matches,
            logical(1),
            expected_sim_day_0 = SIM_DAY_0_LABEL,
            expected_fit_target = EPYDEMIX_FIT_TARGET,
            expected_peak_height_weight = EPYDEMIX_PEAK_HEIGHT_WEIGHT
          )
      )
    if (nrow(epydemix_missing_or_stale) == 0) {
      cat("Epydemix calibrated JSONs already exist for all larger states.\n")
    } else {
      cat(
        "Running Epydemix for larger states missing fresh calibrated JSONs: ",
        paste(epydemix_missing_or_stale$state_dir, collapse = ", "),
        "\n",
        sep = ""
      )
      run_epydemix_batch(epydemix_missing_or_stale$input_file)
    }

    wis_missing_or_stale <- wis_fit_states %>%
      dplyr::filter(
        !file.exists(.data$calibrated_json) |
          !vapply(
            .data$calibrated_json,
            wis_calibrated_fit_matches,
            logical(1),
            expected_sim_day_0 = SIM_DAY_0_LABEL,
            expected_simulation_days = SIMULATION_DAYS,
            expected_realization_range = R0_SEARCH_REALIZATION_RANGE,
            expected_selection_metric = R0_SELECTION_METRIC
          )
      ) %>%
      dplyr::arrange(.data$county_count, .data$state_dir)
    # A calibrated JSON can be copied between machines without its simulator
    # outputs or checkpoints. Queue every state for LS6 and let the fitting
    # process verify/reuse completed results on the machine running the job.
    if (R0_FIT_LAUNCH == "pylauncher") {
      wis_missing_or_stale <- wis_fit_states %>%
        dplyr::arrange(.data$county_count, .data$state_dir)
    }
    if (nrow(wis_missing_or_stale) == 0 && R0_FIT_LAUNCH == "direct") {
      cat("Full-simulator calibrated JSONs already exist for all states at or below the county threshold.\n")
    } else {
      cat(
        if (R0_FIT_LAUNCH == "pylauncher") "Preparing full-simulator state fit commands: " else
          "Running full-simulator R0 search for states at or below the county threshold missing fresh calibrated JSONs: ",
        paste(wis_missing_or_stale$state_dir, collapse = ", "),
        "\n",
        sep = ""
      )
      source("6a_vaccine_coverage_by_state.R", local = TRUE)
      source("6b_outpatient_antiviral_coverage_by_state.R", local = TRUE)
      source("6c_weekend_npi_schedule.R", local = TRUE)
      original_run_scenarios <- SELECTED_RUN_SCENARIOS
      SELECTED_RUN_SCENARIOS <- unique(c(SELECTED_RUN_SCENARIOS, R0_FIT_SCENARIO))
      source("6d_create_intervention_inputs.R", local = TRUE)
      SELECTED_RUN_SCENARIOS <- original_run_scenarios
      wis_args <- c(
        "-e",
        # source() parses the entire file before evaluating it. Direct Rscript
        # execution can discover a syntax error only after earlier fits finish.
        sprintf("source(%s)", encodeString(
          file.path(repo_root, "scripts", "5c_Rm_search.R"),
          quote = '"'
        )),
        paste0("--output-dir=", PIPELINE_OUTPUT_DIR),
        paste0("--sim-day-0=", SIM_DAY_0_LABEL),
        paste0("--selected-states=", paste(wis_missing_or_stale$state_dir, collapse = ",")),
        paste0("--realization-range=", paste(R0_SEARCH_REALIZATION_RANGE, collapse = ",")),
        paste0("--simulation-days=", SIMULATION_DAYS),
        paste0("--scenario=", R0_FIT_SCENARIO),
        paste0("--none-template=", NONE_TEMPLATE_FILE),
        paste0("--vaccine-template=", INTERVENTION_TEMPLATE_FILES[["VACCINE"]]),
        paste0("--antiviral-template=", INTERVENTION_TEMPLATE_FILES[["ANTIVIRAL"]]),
        paste0("--npi-template=", INTERVENTION_TEMPLATE_FILES[["NPI"]]),
        paste0("--all-interventions-template=", INTERVENTION_TEMPLATE_FILES[["ALL_INTERVENTIONS"]]),
        paste0("--r0-selection-metric=", R0_SELECTION_METRIC),
        paste0("--r0-search-metrics=", paste(R0_SEARCH_METRICS, collapse = ",")),
        paste0("--execution-mode=", R0_EXECUTION_MODE),
        paste0("--workers=", R0_WORKERS),
        paste0("--calibrated-output-root=", epydemix_output_dir),
        "--write-calibrated-jsons=true",
        "--reuse-existing=true"
      )
      cat("Full-simulator R0 search command:\n")
      cat("  Rscript ", paste(shQuote(wis_args), collapse = " "), "\n", sep = "")
      if (R0_FIT_LAUNCH == "pylauncher") {
        write_rm_fit_launcher(wis_missing_or_stale$state_dir, wis_args,
          file.path(pipeline_output_root, "Rm_search", SIM_DAY_0_LABEL))
        return(invisible(FALSE))
      }
      wis_status <- run_logged_command("Rscript", wis_args, workdir = repo_root)
      if (!identical(wis_status, 0L)) {
        stop("Full-simulator R0 search failed with exit status ", wis_status)
      }
    }
  }
  invisible(TRUE)
}
