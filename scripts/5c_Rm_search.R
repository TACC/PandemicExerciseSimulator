# Full-simulator R_m calibration and adaptive search.
# Default: minimize absolute total incident-hospitalization error over complete
# MMWR weeks entirely within simulation days 1..200. The existing weekly
# hospitalization series is retained. Post-window observations are excluded
# from both scoring and plots. Completed extinct simulations are zero-padded.
#
# --r0-selection-metric=total|peak_height|peak_timing|wis (default total)
# --r0-search-metrics=all explores total, peak_height and peak_timing independently.
# Explicit comma-separated lists can include wis. There is no combined loss.
# --r0-selection-metric=all is shorthand for --r0-selection-metric=total
# --r0-search-metrics=all; total supplies the downstream calibrated JSON.
# --execution-mode=parallel --workers=auto controls candidate realizations.
# --fit-initial-exposed=true fits R0 by peak height, then initial exposures by
# dominant-peak timing; confirmation and bounded rechecks run in this process.
# --defer-sweep-tables=true stores private state checkpoints instead of combined
# CSVs; script 0 combines them once in the scenarios phase after fitting finishes.
# --state-output-subdir=true isolates one state's tables/plots under <date>/<state>
# while sharing the inputs and calibrated JSON output root prepared by script 0.
#
# Outputs: <output-dir>/Rm_search/<sim-day-0>/ (old WIS outputs are untouched).
# Retains --run-sims=false, --recover-existing=true, and diagnostic refresh flags.
# Example: Rscript scripts/5c_Rm_search.R \
#   --output-dir=MANUSCRIPT_EXAMPLE_TEST --selected-states=Delaware \
#   --simulation-days=200 --r0-selection-metric=total --realization-range=0,9

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  # Check plotting dependencies before spending hours on candidate simulations.
  library(ggrepel)
  library(jsonlite)
  library(purrr)
  library(readr)
  library(stringr)
  library(tibble)
  library(tidyr)
})

filter <- dplyr::filter
mutate <- dplyr::mutate
select <- dplyr::select
arrange <- dplyr::arrange
group_by <- dplyr::group_by
ungroup <- dplyr::ungroup
summarise <- dplyr::summarise
transmute <- dplyr::transmute
slice <- dplyr::slice
bind_rows <- dplyr::bind_rows
left_join <- dplyr::left_join

args <- commandArgs(trailingOnly = TRUE)

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

get_arg_value <- function(prefix, default = NA_character_) {
  hit <- args[startsWith(args, prefix)]
  if (length(hit) == 0) return(default)
  sub(prefix, "", hit[[1]], fixed = TRUE)
}

get_bool_arg <- function(prefix, default = TRUE) {
  value <- get_arg_value(prefix, if (default) "true" else "false")
  tolower(value) %in% c("1", "true", "t", "yes", "y")
}

split_arg <- function(value, default = character()) {
  if (is.null(value) || length(value) == 0 || !nzchar(value)) return(default)
  out <- trimws(unlist(strsplit(value, ",", fixed = TRUE)))
  out[nzchar(out)]
}

safe_num <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.nan(out), NA_real_, out)
}

script_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
repo_root <- if (length(script_file_arg)) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_file_arg[[1]]), mustWork = TRUE)))
} else normalizePath(".", mustWork = FALSE)
if (basename(repo_root) == "scripts") {
  repo_root <- normalizePath("..", mustWork = TRUE)
}
setwd(repo_root)

source(file.path(repo_root, "scripts", "5c_Rm_search_helpers.R"))

pipeline_output_dir <- get_arg_value("--output-dir=", "MANUSCRIPT_EXAMPLE_TEST") # "STATE_H-INCREASE_ALL-ANTIVIAL_TEST"
pipeline_root <- normalizePath(
  if (grepl("^/", pipeline_output_dir)) pipeline_output_dir else file.path(repo_root, pipeline_output_dir),
  mustWork = FALSE
)
sim_day_0 <- get_arg_value("--sim-day-0=", "2025-10-04")
states <- split_arg(
  get_arg_value("--selected-states=", ""),
  c("District-of-Columbia", "Delaware", "Rhode-Island", "Connecticut",
    "Hawaii", "New-Hampshire")
)
scenario_label <- get_arg_value("--scenario=", "ALL_INTERVENTIONS")
fit_initial_exposed <- get_bool_arg("--fit-initial-exposed=", FALSE)
staged_version <- "staged_r0_exposures_v4"
screening_realizations <- as.integer(get_arg_value("--screening-realizations=", "25"))
exposure_multipliers <- sort(unique(as.numeric(split_arg(get_arg_value("--exposure-multipliers=",
  "0.03125,0.0625,0.125,0.25,0.5,0.666666666666667,0.8,1,1.5,2")))))
peak_height_tolerance <- as.numeric(get_arg_value("--peak-height-tolerance=", "0.15"))
refine_step <- as.numeric(get_arg_value("--refine-step=", "0.025"))
active_staged_context <- NULL
winning_staged_contexts <- new.env(parent = emptyenv())
state_output_subdir <- get_bool_arg("--state-output-subdir=", FALSE)
defer_sweep_tables <- get_bool_arg("--defer-sweep-tables=", FALSE)
if (defer_sweep_tables && length(states) != 1L) {
  stop("--defer-sweep-tables=true requires exactly one state per fitting command.")
}
if (state_output_subdir && length(states) != 1L) {
  stop("--state-output-subdir=true requires exactly one --selected-states entry.")
}
simulation_days <- as.integer(get_arg_value("--simulation-days=", "200"))
realization_range <- as.integer(split_arg(get_arg_value("--realization-range=", if (fit_initial_exposed) "0,99" else "0,9")))
if (length(realization_range) != 2 || any(is.na(realization_range))) {
  stop("--realization-range must be two comma-separated integers, e.g. 0,9.")
}

base_r0 <- as.numeric(get_arg_value("--base-r0=", "1.2"))
r0_min <- as.numeric(get_arg_value("--r0-min=", "1.01"))
r0_max <- as.numeric(get_arg_value("--r0-max=", "3.5"))
initial_step <- as.numeric(get_arg_value("--initial-step=", "0.4"))
min_step <- as.numeric(get_arg_value("--min-step=", "0.05"))
step_shrink <- as.numeric(get_arg_value("--step-shrink=", "0.5"))
max_iterations <- as.integer(get_arg_value("--max-iterations=", "8"))
r0_selection_metric <- get_arg_value("--r0-selection-metric=", if (fit_initial_exposed) "peak_height" else "total")
# 'all' is shorthand for exploring all three features, with total selected for
# the single calibrated JSON consumed downstream. Explicit search lists may add WIS.
default_search_metrics <- r0_selection_metric
if (r0_selection_metric == "all") r0_selection_metric <- "total"
r0_selection_metric <- parse_r0_search_metrics(r0_selection_metric)
if (length(r0_selection_metric) != 1) stop("Select one final R0 metric; use --r0-search-metrics for multiple paths.")
r0_search_metrics <- unique(c(r0_selection_metric, parse_r0_search_metrics(
  get_arg_value("--r0-search-metrics=", default_search_metrics))))
if (fit_initial_exposed && (!identical(r0_search_metrics, "peak_height") ||
    is.na(screening_realizations) || screening_realizations < 1L ||
    !length(exposure_multipliers) || any(!is.finite(exposure_multipliers) | exposure_multipliers <= 0) ||
    !is.finite(peak_height_tolerance) || peak_height_tolerance <= 0 || peak_height_tolerance >= 1 ||
    !is.finite(refine_step) || refine_step <= 0 || refine_step > .2 ||
    realization_range[[1]] < 0 || realization_range[[2]] < realization_range[[1]])) {
  stop("Staged fitting requires peak_height only, positive exposure/screening settings, and an ordered nonnegative realization range.")
}
execution_mode <- get_arg_value("--execution-mode=", "parallel")
workers_arg <- get_arg_value("--workers=", "auto")
workers <- if (workers_arg == "auto") "auto" else as.integer(workers_arg)
if (!execution_mode %in% c("serial", "parallel") ||
    (workers_arg != "auto" && (is.na(workers) || workers < 1))) stop("Invalid execution mode or worker count.")

run_sims <- get_bool_arg("--run-sims=", TRUE)
reuse_existing <- get_bool_arg("--reuse-existing=", TRUE)
recover_existing <- get_bool_arg("--recover-existing=", FALSE)
if (recover_existing && !reuse_existing) {
  stop("--recover-existing=true requires --reuse-existing=true.")
}
refresh_search_window_plots <- get_bool_arg("--refresh-search-window-plots=", FALSE)
refresh_diagnostic_plots <- get_bool_arg("--refresh-diagnostic-plots=", FALSE)
refresh_burden_heatmap <- get_bool_arg("--refresh-burden-heatmap=", FALSE)
refresh_runtime_heatmap <- get_bool_arg("--refresh-runtime-heatmap=", FALSE)
refresh_burden_from_complete_metadata <- get_bool_arg("--refresh-burden-from-complete-metadata=", TRUE)
source_5a_if_missing <- get_bool_arg("--source-5a-if-missing=", TRUE)
source_6d_if_missing <- get_bool_arg("--source-6d-if-missing=", TRUE)
write_calibrated_jsons <- get_bool_arg("--write-calibrated-jsons=", fit_initial_exposed)
calibrated_output_root_arg <- get_arg_value("--calibrated-output-root=", "")
input_template_dir <- get_arg_value("--input-template-dir=", file.path(repo_root, "data", "INPUT_FILE_TEMPLATES"))
shared_figure_dir <- get_arg_value("--shared-figure-dir=", file.path(repo_root, "figures"))
none_template_file <- get_arg_value(
  "--none-template=",
  file.path(input_template_dir, "INPUT_SEIHRD-STOCH_STATE_NONE_H3N2.json")
)
vaccine_template_file <- get_arg_value(
  "--vaccine-template=",
  file.path(input_template_dir, "INPUT_SEIHRD-STOCH_STATE_VAX_H3N2.json")
)
antiviral_template_file <- get_arg_value(
  "--antiviral-template=",
  file.path(input_template_dir, "INPUT_SEIHRD-STOCH_ANTIVIRAL_H3N2.json")
)
npi_template_file <- get_arg_value(
  "--npi-template=",
  file.path(input_template_dir, "INPUT_SEIHRD-STOCH_STATE_NPI_H3N2.json")
)
all_interventions_template_file <- get_arg_value(
  "--all-interventions-template=",
  file.path(input_template_dir, "INPUT_SEIHRD-STOCH_STATE_ALL_INTERVENTIONS_H3N2.json")
)

sweep_id <- format(Sys.time(), "%Y%m%d_%H%M%S")
sweep_root <- file.path(pipeline_root, "Rm_search", sim_day_0)
if (state_output_subdir) sweep_root <- file.path(sweep_root, states[[1]])
candidate_input_dir <- file.path(sweep_root, "candidate_inputs")
sim_output_dir <- file.path(sweep_root, "sim_outputs")
plot_dir <- file.path(sweep_root, "plots")
if (state_output_subdir) shared_figure_dir <- plot_dir
calibrated_output_root <- if (nzchar(calibrated_output_root_arg)) {
  normalizePath(
    if (grepl("^/", calibrated_output_root_arg)) calibrated_output_root_arg else file.path(repo_root, calibrated_output_root_arg),
    mustWork = FALSE
  )
} else {
  file.path(pipeline_root, "epydemix_fit", sim_day_0)
}

dir.create(candidate_input_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(sim_output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(plot_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(sweep_root, "mpl_cache"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(sweep_root, "xdg_cache"), recursive = TRUE, showWarnings = FALSE)
Sys.setenv(
  MPLBACKEND = "Agg",
  MPLCONFIGDIR = file.path(sweep_root, "mpl_cache"),
  XDG_CACHE_HOME = file.path(sweep_root, "xdg_cache")
)

#' Resolve a sweep table to a private per-state checkpoint during LS6 fitting
#' @param path Path of the combined CSV normally produced by the sweep.
#' @return The CSV path, or its state-specific RDS checkpoint path.
sweep_table_path <- function(path) {
  if (!get0("defer_sweep_tables", ifnotfound = FALSE)) return(path)
  checkpoint_dir <- file.path(sweep_root, "checkpoints")
  dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
  file.path(checkpoint_dir, paste0(states[[1]], "_", sub("\\.csv$", ".rds", basename(path))))
}

#' Read a saved sweep checkpoint or an ordinary CSV
#' @param file File path to read.
#' @param ... CSV reader arguments, ignored for RDS checkpoints.
#' @return The stored data frame.
read_sweep_table <- function(file, ...) {
  if (endsWith(file, ".rds")) readRDS(file) else readr::read_csv(file, ...)
}

high_risk_palette <- c("#f3e79b", "#fac484", "#f8a07e", "#eb7f86", "#ce6693", "#a059a0", "#5c53a5")

#' Serialize access to a shared sweep output using an atomic directory lock
#' @param path Output path used to name the lock directory.
#' @param code Expression evaluated while holding the lock.
#' @return The value returned by code.
with_sweep_file_lock <- function(path, code) {
  lock <- paste0(path, ".lock")
  deadline <- Sys.time() + 120
  while (!dir.create(lock, showWarnings = FALSE)) {
    if (Sys.time() > deadline) stop("Timed out waiting for sweep output lock: ", lock)
    Sys.sleep(0.1)
  }
  on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  force(code)
}

#' Merge sweep rows without losing updates from concurrent state fits
#' @param data New rows to add, preferred over existing rows with the same keys.
#' @param path Shared output CSV path.
#' @param keys Optional column names identifying rows to replace.
#' @return The output path, invisibly.
write_csv_preserving_existing <- function(data, path, keys = NULL) {
  with_sweep_file_lock(path, {
  if (nrow(data) == 0 && file.exists(path)) {
    message("Preserved existing file with no new rows: ", path)
    return(invisible(path))
  }
  out <- data
  if (file.exists(path)) {
    existing <- read_sweep_table(path, show_col_types = FALSE)
    # A staged result describes one selected exposure allocation per state.
    # Replace that state's old rows together, rather than retaining R0 points
    # scored under a previous allocation or input fingerprint.
    if (isTRUE(get0("fit_initial_exposed", ifnotfound = FALSE)) &&
        "geo_region" %in% names(data) && "geo_region" %in% names(existing)) {
      existing <- existing[!existing$geo_region %in% data$geo_region, , drop = FALSE]
    }
    if ("search_centers" %in% names(existing)) existing$search_centers <- as.character(existing$search_centers)
    # Prefer recomputed rows by identity. Comparing every floating-point score
    # after a CSV round-trip can duplicate a candidate during recovery.
    if (is.null(keys)) keys <- intersect(c("geo_region", "scenario_label", "disease_R0", "date", "quantile",
                        "iteration", "optimization_choice", "search_metrics", "scoring_version", "r0_selection_metric"), names(data))
    out <- bind_rows(data, existing)
    out <- if (length(keys)) out %>% distinct(across(all_of(keys)), .keep_all = TRUE) else distinct(out)
  }
  temporary <- tempfile(pattern = paste0(".", basename(path), "-"), tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  if (endsWith(path, ".rds")) saveRDS(out, temporary) else readr::write_csv(out, temporary)
  if (!file.rename(temporary, path)) stop("Could not publish sweep CSV: ", path)
  invisible(path)
  })
}

QUANTILE_LEVELS <- c(0.01, 0.025, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.975, 0.99)
INTERVAL_ALPHAS <- c(0.02, 0.05, 0.10, 0.20, 0.50)

normalize_state_dir <- function(x) {
  stringr::str_replace_all(trimws(x), "\\s+", "-")
}

county_count_for_state <- function(state) {
  pop_files <- list.files(
    file.path(repo_root, "data", state),
    pattern = paste0("^county_pop_by_age_", state, "_.*ACS\\.csv$"),
    full.names = TRUE
  )
  if (length(pop_files) == 0) {
    stop("No county population file found for ", state, " under data/", state, ".", call. = FALSE)
  }
  nrow(read_sweep_table(pop_files[[1]], show_col_types = FALSE))
}

state_population_for_state <- function(state) {
  pop_files <- list.files(
    file.path(repo_root, "data", state),
    pattern = paste0("^county_pop_by_age_", state, "_.*ACS\\.csv$"),
    full.names = TRUE
  )
  if (length(pop_files) == 0) {
    warning("No county population file found for ", state, " under data/", state, ".")
    return(NA_real_)
  }

  pop <- read_sweep_table(pop_files[[1]], show_col_types = FALSE)
  age_cols <- names(pop)[grepl("^[0-9]+(-[0-9]+|\\+)$", names(pop))]
  if (length(age_cols) == 0) {
    warning("No age population columns found in ", pop_files[[1]], ".")
    return(NA_real_)
  }
  sum(as.matrix(dplyr::mutate(pop[age_cols], dplyr::across(dplyr::everything(), safe_num))), na.rm = TRUE)
}

sort_states_by_county_count <- function(states) {
  state_counts <- tibble(
    geo_region = states,
    county_count = vapply(states, county_count_for_state, integer(1))
  ) %>%
    arrange(.data$county_count, .data$geo_region)
  message(
    "State fit order by county count: ",
    paste0(state_counts$geo_region, " (", state_counts$county_count, ")", collapse = ", ")
  )
  state_counts$geo_region
}

clip_r0 <- function(r0) {
  pmin(pmax(r0, r0_min), r0_max)
}

r0_key <- function(r0) {
  formatC(clip_r0(r0), format = "f", digits = 4)
}

r0_label <- function(r0) {
  formatC(r0, format = "f", digits = 2)
}

state_plot_label <- function(state) {
  dplyr::recode(
    state,
    "District-of-Columbia" = "DC",
    .default = stringr::str_replace_all(state, "-", " ")
  )
}

absolute_data_path <- function(path, source_file) {
  if (is.null(path) || !nzchar(path)) return(path)
  if (grepl("^template:", path)) return(path)
  if (grepl("^/", path)) return(normalizePath(path, mustWork = FALSE))

  candidates <- c(file.path(dirname(source_file), path), file.path(repo_root, path))
  stripped <- path
  while (startsWith(stripped, "../")) stripped <- sub("^\\.\\./", "", stripped)
  candidates <- c(candidates, file.path(repo_root, stripped))
  existing <- candidates[file.exists(candidates)]
  if (length(existing) > 0) return(normalizePath(existing[[1]], mustWork = TRUE))
  normalizePath(candidates[[1]], mustWork = FALSE)
}

absolutize_data_paths <- function(config, source_file) {
  if (is.null(config$data)) return(config)
  for (data_name in intersect(names(config$data), c("population", "contact", "flow", "high_risk_ratios"))) {
    config$data[[data_name]] <- absolute_data_path(config$data[[data_name]], source_file)
  }
  config
}

base_input_file <- function(state) {
  file.path(
    pipeline_root,
    "TACC_FILES",
    sim_day_0,
    paste0("INPUT_", state, "_", scenario_label, ".json")
  )
}

pipeline_output_dir_for_6d <- function() {
  pipeline_root_abs <- normalizePath(pipeline_root, mustWork = FALSE)
  repo_root_prefix <- paste0(repo_root, .Platform$file.sep)
  if (startsWith(pipeline_root_abs, repo_root_prefix)) {
    return(sub(repo_root_prefix, "", pipeline_root_abs, fixed = TRUE))
  }
  stop(
    "Cannot source Section 6d for output dir outside repo root: ", pipeline_root_abs,
    ". Run 6d manually for that output dir or use a repo-local --output-dir.",
    call. = FALSE
  )
}

source_6d_for_base_inputs <- function(states) {
  if (!source_6d_if_missing) return(invisible(FALSE))

  seed_dir <- file.path(pipeline_root, "SEED_INPUT_JSONS", sim_day_0)
  seed_files <- file.path(seed_dir, paste0("INPUT_SEIHRD-STOCH_", states, "_SEED_NONE.json"))
  missing_seed_files <- seed_files[!file.exists(seed_files)]
  if (length(missing_seed_files) > 0) {
    source_5a_for_seed_inputs()
  }

  scripts_dir <- file.path(repo_root, "scripts")
  script_6d <- file.path(scripts_dir, "6d_create_intervention_inputs.R")
  if (!file.exists(script_6d)) {
    stop("Cannot source Section 6d because script is missing: ", script_6d, call. = FALSE)
  }

  message("Missing ", scenario_label, " TACC input(s); sourcing Section 6d to generate scenario JSONs.")
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(scripts_dir)

  env_6d <- new.env(parent = globalenv())
  env_6d$SIM_DAY_0 <- as.Date(sim_day_0)
  env_6d$SIMULATION_DAYS <- as.integer(simulation_days)
  env_6d$SIM_REALIZATION_RANGE <- as.integer(realization_range)
  env_6d$PIPELINE_OUTPUT_DIR <- pipeline_output_dir_for_6d()
  env_6d$NONE_TEMPLATE_FILE <- none_template_file
  env_6d$INTERVENTION_TEMPLATE_FILES <- c(
    VACCINE = vaccine_template_file,
    ANTIVIRAL = antiviral_template_file,
    NPI = npi_template_file,
    ALL_INTERVENTIONS = all_interventions_template_file
  )
  env_6d$SELECTED_RUN_SCENARIOS <- scenario_label

  source(script_6d, local = env_6d)
  invisible(TRUE)
}

source_5a_for_seed_inputs <- function() {
  if (!source_5a_if_missing) return(invisible(FALSE))

  script_5a <- file.path(repo_root, "scripts", "5a_derive_initial_exposures.R")
  if (!file.exists(script_5a)) {
    stop("Cannot source Section 5a because script is missing: ", script_5a, call. = FALSE)
  }

  message("Missing seed input(s); sourcing Section 5a to generate dated seed JSONs and validation data.")
  env_5a <- new.env(parent = globalenv())
  env_5a$SIM_DAY_0 <- as.Date(sim_day_0)
  env_5a$PIPELINE_OUTPUT_DIR <- pipeline_output_dir
  source(script_5a, local = env_5a)
  invisible(TRUE)
}

check_base_inputs <- function(states, allow_source_6d = TRUE) {
  required <- tibble(
    geo_region = states,
    input_file = purrr::map_chr(states, base_input_file),
    exists = file.exists(.data$input_file)
  )
  missing <- required %>% filter(!.data$exists)
  if (nrow(missing) == 0) return(invisible(required))

  if (allow_source_6d) {
    source_6d_for_base_inputs(missing$geo_region)
    return(check_base_inputs(states, allow_source_6d = FALSE))
  }

  stop(
    "Missing generated ", scenario_label, " input(s) for Section 5c:\n",
    paste0("  - ", missing$geo_region, ": ", missing$input_file, collapse = "\n"),
    "\n\nSection 5c rewrites R0 on already generated scenario JSONs from ",
    "TACC_FILES/<sim_day_0>/INPUT_<state>_", scenario_label, ".json. ",
    "Those files are produced by Section 6d after seed/calibrated inputs exist. ",
    "Run Section 6d for the missing state(s), choose an --output-dir that already contains them, ",
    "or copy/regenerate the matching TACC_FILES inputs before rerunning 5c.",
    call. = FALSE
  )
}

seed_input_file <- function(state) {
  file.path(
    pipeline_root,
    "SEED_INPUT_JSONS",
    sim_day_0,
    paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE.json")
  )
}

candidate_context <- function(state) {
  if (!is.null(active_staged_context) && identical(active_staged_context$state, state)) return(active_staged_context)
  if (exists(state, winning_staged_contexts, inherits = FALSE)) get(state, winning_staged_contexts) else NULL
}

candidate_input_file <- function(state, r0) {
  file.path(
    candidate_context(state)$input_dir %||% candidate_input_dir,
    paste0("INPUT_", state, "_", scenario_label, "_R0-", sprintf("%.4f", clip_r0(r0)), ".json")
  )
}

write_candidate_input <- function(state, r0) {
  source_file <- base_input_file(state)
  if (!file.exists(source_file)) {
    stop("Missing generated scenario input: ", source_file, ". Run Section 6d first.")
  }
  r0 <- clip_r0(r0)
  config <- jsonlite::fromJSON(source_file, simplifyVector = FALSE)
  config <- absolutize_data_paths(config, source_file)
  context <- candidate_context(state)
  candidate_range <- context$realization_range %||% realization_range
  if (!is.null(context)) {
    config$initial_exposed <- context$rows
    config$metadata_tags$staged_fit <- list(version = staged_version, run_signature = context$run_signature)
  }
  config$output_dir_path <- "GENERATE"
  config$batch_num <- "GENERATE"
  config$realization_range <- as.character(candidate_range)
  config$execution <- list(mode = execution_mode, workers = workers)
  config$disease_model$parameters$R0 <- formatC(r0, format = "f", digits = 5)
  if (is.null(config$metadata_tags)) config$metadata_tags <- list()
  config$metadata_tags$scenario_label <- scenario_label
  config$metadata_tags$r0_search <- list(
    kind = "all_interventions_state_incident_hosp_feature_search",
    sweep_id = sweep_id,
    candidate_R0 = r0,
    source_input_file = source_file,
    realization_range = candidate_range,
    simulation_days = simulation_days,
    scoring_version = R0_SCORING_VERSION,
    r0_selection_metric = r0_selection_metric,
    search_metrics = r0_search_metrics
  )
  out_file <- candidate_input_file(state, r0)
  jsonlite::write_json(config, out_file, auto_unbox = TRUE, pretty = TRUE, null = "null")
  out_file
}

metadata_candidate_r0 <- function(metadata) {
  safe_num(metadata$metadata_tags$r0_search$candidate_R0 %||%
             metadata$disease_model$parameters$R0)
}

metadata_state <- function(metadata) {
  as.character(metadata$metadata_tags$state_dir %||% NA_character_)
}

metadata_sim_day_0 <- function(metadata) {
  as.character(metadata$metadata_tags$sim_day_0 %||% NA_character_)
}

metadata_matches_candidate <- function(metadata_file, state, r0) {
  metadata <- tryCatch(jsonlite::fromJSON(metadata_file, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(metadata)) return(FALSE)
  context <- candidate_context(state)
  if (!is.null(context) && (!identical(metadata$metadata_tags$staged_fit$run_signature, context$run_signature) ||
      !identical(exposure_allocation_key(metadata$initial_exposed), exposure_allocation_key(context$rows)))) return(FALSE)
  identical(metadata_state(metadata), state) &&
    identical(metadata$metadata_tags$scenario_label, scenario_label) &&
    identical(metadata_sim_day_0(metadata), sim_day_0) &&
    isTRUE(all.equal(metadata_candidate_r0(metadata), clip_r0(r0), tolerance = 1e-8)) &&
    identical(as.integer(metadata$cli_args$days %||% NA_integer_), as.integer(simulation_days))
}

complete_metadata_for_candidate <- function(state, r0) {
  context <- candidate_context(state)
  candidate_range <- context$realization_range %||% realization_range
  expected_ids <- seq.int(candidate_range[[1]], candidate_range[[2]])
  metadata_files <- list.files(
    context$sim_dir %||% sim_output_dir,
    pattern = "^metadata_batch-.*\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  matches <- metadata_files[vapply(metadata_files, metadata_matches_candidate, logical(1), state = state, r0 = r0)]
  if (length(matches) == 0) return(NA_character_)

  complete <- keep(matches, function(metadata_file) {
    metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
    batch_num <- as.character(metadata$batch_num %||% "")
    timing_file <- file.path(dirname(metadata_file), paste0("simulation_times_batch-", batch_num, ".csv"))
    if (!file.exists(timing_file)) return(FALSE)
    timing <- read_sweep_table(timing_file, show_col_types = FALSE)
    identical(sort(unique(as.integer(timing$sim_id))), expected_ids)
  })
  if (length(complete) > 0) complete[[1]] else NA_character_
}

run_candidate <- function(input_file, state, r0) {
  context <- candidate_context(state)
  candidate_range <- context$realization_range %||% realization_range
  existing <- complete_metadata_for_candidate(state, r0)
  if (reuse_existing && !is.na(existing)) {
    message("SKIP existing complete output: ", state, " R0=", r0_key(r0))
    return(existing)
  }

  if (recover_existing) {
    stop("Recovery needs complete saved output for ", state, " R0=", r0_key(r0),
         ". No simulations were launched. Check the original search settings, ",
         "simulation days, and realization range.")
  }

  if (!run_sims) {
    message("DRY RUN candidate input only: ", input_file)
    return(NA_character_)
  }

  message("RUN ", state, " ", scenario_label, " R0=", r0_key(r0),
          " sims=", candidate_range[[1]], "-", candidate_range[[2]])
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(normalizePath(context$sim_dir %||% sim_output_dir, mustWork = TRUE))
  dir.create("GENERATE", recursive = TRUE, showWarnings = FALSE)
  status <- system2(
    "poetry",
    args = c(
      "run", "python3", file.path(repo_root, "src", "simulator.py"),
      "-l", "WARNING",
      "-d", as.character(simulation_days),
      "-i", normalizePath(input_file, mustWork = TRUE)
    ),
    stdout = "",
    stderr = "",
    wait = TRUE
  )
  if (!identical(status, 0L)) {
    stop("Simulator failed for ", state, " R0=", r0_key(r0), " with exit status ", status)
  }

  metadata_file <- complete_metadata_for_candidate(state, r0)
  if (is.na(metadata_file)) {
    stop("Simulator finished but no complete matching metadata was found for ", state, " R0=", r0_key(r0))
  }
  metadata_file
}

resolve_validation_file <- function(metadata) {
  path <- metadata$metadata_tags$validation$fit_data_file %||% NA_character_
  if (is.na(path) || !nzchar(path)) return(NA_character_)
  if (grepl("^/", path)) return(normalizePath(path, mustWork = FALSE))
  stripped <- path
  while (startsWith(stripped, "../")) stripped <- sub("^\\.\\./", "", stripped)
  candidates <- c(
    file.path(dirname(metadata$file_path %||% ""), path),
    file.path(pipeline_root, path),
    file.path(repo_root, path),
    file.path(repo_root, stripped)
  )
  existing <- candidates[file.exists(candidates)]
  normalizePath(if (length(existing) > 0) existing[[1]] else candidates[[1]], mustWork = FALSE)
}

first_complete_mmwr_week_end <- function(start_date) {
  start_date <- as.Date(start_date)
  days_until_saturday <- (6 - as.integer(format(start_date, "%w"))) %% 7
  week_end <- start_date + days_until_saturday
  week_start <- week_end - 6
  if (week_start < start_date) week_end <- week_end + 7
  week_end
}

mmwr_week_end_date <- function(date) {
  date <- as.Date(date)
  date + ((6 - as.integer(format(date, "%w"))) %% 7)
}

read_csv_state_daily_h <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  batch_num <- as.character(metadata$batch_num)
  node_files <- list.files(
    dirname(metadata_file),
    pattern = paste0("^node_.*_batch-", batch_num, "\\.csv$"),
    full.names = TRUE
  )
  if (length(node_files) == 0) return(tibble())

  purrr::map_dfr(node_files, function(node_file) {
    read_sweep_table(
      node_file,
      show_col_types = FALSE,
      col_select = c("sim_id", "day", "H")
    ) %>%
      group_by(.data$sim_id, .data$day) %>%
      summarise(H = sum(.data$H, na.rm = TRUE), .groups = "drop")
  }) %>%
    group_by(.data$sim_id, .data$day) %>%
    summarise(H = sum(.data$H, na.rm = TRUE), .groups = "drop")
}

read_json_state_daily_h <- function(metadata_file) {
  sim_dirs <- list.dirs(dirname(metadata_file), recursive = FALSE, full.names = TRUE)
  sim_dirs <- sim_dirs[grepl("^output_sim[0-9]+$", basename(sim_dirs))]
  if (length(sim_dirs) == 0) return(tibble())

  purrr::map_dfr(sim_dirs, function(sim_dir) {
    sim_id <- as.integer(sub("^output_sim", "", basename(sim_dir)))
    output_files <- list.files(sim_dir, pattern = "^output_[0-9]+\\.json$", full.names = TRUE)
    purrr::map_dfr(output_files, function(output_file) {
      day_doc <- jsonlite::fromJSON(output_file, simplifyVector = FALSE)
      tibble(
        sim_id = sim_id,
        day = as.integer(day_doc$day),
        H = safe_num(day_doc$total_summary$H %||% 0)
      )
    })
  })
}

read_network_state_daily_h <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  batch_num <- as.character(metadata$batch_num)
  network_file <- file.path(dirname(metadata_file), paste0("network_batch-", batch_num, ".csv"))
  if (!file.exists(network_file)) return(tibble())

  read_sweep_table(
    network_file,
    show_col_types = FALSE,
    col_select = dplyr::any_of(c("sim_id", "day", "H"))
  ) %>%
    mutate(H = if ("H" %in% names(.)) safe_num(.data$H) else 0) %>%
    group_by(.data$sim_id, .data$day) %>%
    summarise(H = sum(.data$H, na.rm = TRUE), .groups = "drop")
}

read_csv_state_daily_compartments <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  batch_num <- as.character(metadata$batch_num)
  node_files <- list.files(
    dirname(metadata_file),
    pattern = paste0("^node_.*_batch-", batch_num, "\\.csv$"),
    full.names = TRUE
  )
  if (length(node_files) == 0) return(tibble())

  purrr::map_dfr(node_files, function(node_file) {
    read_sweep_table(
      node_file,
      show_col_types = FALSE,
      col_select = dplyr::any_of(c("sim_id", "day", "H", "D"))
    ) %>%
      mutate(
        H = if ("H" %in% names(.)) safe_num(.data$H) else 0,
        D = if ("D" %in% names(.)) safe_num(.data$D) else 0
      ) %>%
      group_by(.data$sim_id, .data$day) %>%
      summarise(
        H = sum(.data$H, na.rm = TRUE),
        D = sum(.data$D, na.rm = TRUE),
        .groups = "drop"
      )
  }) %>%
    group_by(.data$sim_id, .data$day) %>%
    summarise(
      H = sum(.data$H, na.rm = TRUE),
      D = sum(.data$D, na.rm = TRUE),
      .groups = "drop"
    )
}

read_json_state_daily_compartments <- function(metadata_file) {
  sim_dirs <- list.dirs(dirname(metadata_file), recursive = FALSE, full.names = TRUE)
  sim_dirs <- sim_dirs[grepl("^output_sim[0-9]+$", basename(sim_dirs))]
  if (length(sim_dirs) == 0) return(tibble())

  purrr::map_dfr(sim_dirs, function(sim_dir) {
    sim_id <- as.integer(sub("^output_sim", "", basename(sim_dir)))
    output_files <- list.files(sim_dir, pattern = "^output_[0-9]+\\.json$", full.names = TRUE)
    purrr::map_dfr(output_files, function(output_file) {
      day_doc <- jsonlite::fromJSON(output_file, simplifyVector = FALSE)
      tibble(
        sim_id = sim_id,
        day = as.integer(day_doc$day),
        H = safe_num(day_doc$total_summary$H %||% 0),
        D = safe_num(day_doc$total_summary$D %||% 0)
      )
    })
  })
}

read_network_state_daily_compartments <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  batch_num <- as.character(metadata$batch_num)
  network_file <- file.path(dirname(metadata_file), paste0("network_batch-", batch_num, ".csv"))
  if (!file.exists(network_file)) return(tibble())

  read_sweep_table(
    network_file,
    show_col_types = FALSE,
    col_select = dplyr::any_of(c("sim_id", "day", "H", "D"))
  ) %>%
    mutate(
      H = if ("H" %in% names(.)) safe_num(.data$H) else 0,
      D = if ("D" %in% names(.)) safe_num(.data$D) else 0
    ) %>%
    group_by(.data$sim_id, .data$day) %>%
    summarise(
      H = sum(.data$H, na.rm = TRUE),
      D = sum(.data$D, na.rm = TRUE),
      .groups = "drop"
    )
}

read_candidate_burden_samples <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  weekly <- read_candidate_weekly_samples(metadata_file)
  daily <- read_network_state_daily_compartments(metadata_file)
  if (!nrow(daily)) daily <- read_csv_state_daily_compartments(metadata_file)
  if (!nrow(daily)) daily <- read_json_state_daily_compartments(metadata_file)
  hospital <- weekly %>% group_by(.data$sim_id) %>% summarise(burden = sum(.data$generated), .groups = "drop") %>%
    mutate(outcome = "hospitalizations")
  deaths <- daily %>% filter(.data$day <= simulation_days) %>% group_by(.data$sim_id) %>%
    arrange(.data$day, .by_group = TRUE) %>% slice_tail(n = 1) %>% ungroup() %>%
    transmute(sim_id = .data$sim_id, burden = .data$D, outcome = "deaths")
  bind_rows(hospital, deaths) %>% mutate(geo_region = metadata_state(metadata), scenario_label = scenario_label,
      disease_R0 = metadata_candidate_r0(metadata), batch_num = as.character(metadata$batch_num),
      metadata_file = metadata_file, .before = 1)
}

read_candidate_weekly_samples <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  daily <- read_network_state_daily_h(metadata_file)
  if (nrow(daily) == 0) daily <- read_csv_state_daily_h(metadata_file)
  if (nrow(daily) == 0) daily <- read_json_state_daily_h(metadata_file)
  if (nrow(daily) == 0) stop("No daily hospitalization output: ", metadata_file)
  r0_weekly_incident_samples(daily, metadata, simulation_days) %>%
    mutate(geo_region = metadata_state(metadata), scenario_label = scenario_label,
           disease_R0 = metadata_candidate_r0(metadata), batch_num = as.character(metadata$batch_num), .before = 1)
}

read_observed_state_weekly <- function(metadata_file) {
  metadata <- jsonlite::fromJSON(metadata_file, simplifyVector = FALSE)
  metadata$file_path <- metadata_file
  validation_file <- resolve_validation_file(metadata)
  if (is.na(validation_file) || !file.exists(validation_file)) {
    stop("Missing validation fit data file for ", metadata_state(metadata), ": ", validation_file)
  }

  window <- r0_scoring_window(metadata, simulation_days)
  read_sweep_table(validation_file, show_col_types = FALSE) %>%
    transmute(
      date = as.Date(.data$date),
      observed = safe_num(.data$incident_hospitalizations)
    ) %>%
    filter(.data$date %in% window$weeks) %>%
    group_by(.data$date) %>%
    summarise(observed = sum(.data$observed, na.rm = TRUE), .groups = "drop") %>%
    mutate(geo_region = metadata_state(metadata), .before = 1)
}

quantile_predictions <- function(samples) {
  samples %>%
    group_by(.data$geo_region, .data$scenario_label, .data$disease_R0, .data$date) %>%
    summarise(
      quantile = list(QUANTILE_LEVELS),
      value = list(as.numeric(stats::quantile(.data$generated, QUANTILE_LEVELS, na.rm = TRUE, names = FALSE))),
      sample_count = dplyr::n(),
      mean_generated = mean(.data$generated, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    tidyr::unnest(c("quantile", "value"))
}

score_wis_manual <- function(predictions, observed, scoring_method = "manual_hubverse_style") {
  pred_wide <- predictions %>%
    mutate(q_col = paste0("q", gsub("\\.", "_", as.character(.data$quantile)))) %>%
    select(-"quantile") %>%
    tidyr::pivot_wider(names_from = "q_col", values_from = "value")

  scored <- pred_wide %>%
    left_join(observed, by = c("geo_region", "date")) %>%
    filter(!is.na(.data$observed))

  for (alpha in INTERVAL_ALPHAS) {
    lower_col <- paste0("q", gsub("\\.", "_", as.character(alpha / 2)))
    upper_col <- paste0("q", gsub("\\.", "_", as.character(1 - alpha / 2)))
    score_col <- paste0("interval_score_", round((1 - alpha) * 100))
    cover_col <- paste0("interval_coverage_", round((1 - alpha) * 100))
    lower <- scored[[lower_col]]
    upper <- scored[[upper_col]]
    observed_value <- scored[["observed"]]
    scored[[score_col]] <- upper - lower +
      (2 / alpha) * (lower - observed_value) * (observed_value < lower) +
      (2 / alpha) * (observed_value - upper) * (observed_value > upper)
    scored[[cover_col]] <- observed_value >= lower & observed_value <= upper
  }

  interval_score_cols <- paste0("interval_score_", c(98, 95, 90, 80, 50))
  coverage_cols <- paste0("interval_coverage_", c(98, 95, 90, 80, 50))
  alpha_weights <- INTERVAL_ALPHAS / 2

  scored %>%
    rowwise() %>%
    mutate(
      ae_median = abs(.data$q0_5 - .data$observed),
      dispersion = sum(alpha_weights * c_across(dplyr::all_of(interval_score_cols)), na.rm = TRUE) /
        (length(INTERVAL_ALPHAS) + 0.5),
      wis = (0.5 * .data$ae_median + sum(alpha_weights * c_across(dplyr::all_of(interval_score_cols)), na.rm = TRUE)) /
        (length(INTERVAL_ALPHAS) + 0.5)
    ) %>%
    ungroup() %>%
    select(
      "geo_region", "scenario_label", "disease_R0", "date", "sample_count",
      "observed", "mean_generated", "q0_025", "q0_5", "q0_975",
      "wis", "ae_median", "dispersion",
      dplyr::all_of(interval_score_cols), dplyr::all_of(coverage_cols)
    ) %>%
    mutate(scoring_method = scoring_method, .after = "sample_count")
}

score_wis_hubevals <- function(predictions, observed) {
  pred_wide <- predictions %>%
    mutate(q_col = paste0("q", gsub("\\.", "_", as.character(.data$quantile)))) %>%
    select(-"quantile") %>%
    tidyr::pivot_wider(names_from = "q_col", values_from = "value")

  model_out_tbl <- predictions %>%
    mutate(
      model_id = paste(.data$geo_region, .data$scenario_label, format(round(.data$disease_R0, 4), nsmall = 4), sep = "-"),
      reference_date = as.Date(sim_day_0),
      target_end_date = .data$date,
      horizon = as.integer(as.numeric(.data$target_end_date - .data$reference_date) / 7),
      location = .data$geo_region,
      target = "wk inc flu hosp",
      output_type = "quantile",
      output_type_id = .data$quantile
    ) %>%
    transmute(
      .data$model_id, .data$reference_date, .data$horizon, .data$target_end_date,
      .data$location, .data$target, .data$output_type, .data$output_type_id,
      value = .data$value
    )

  oracle_output <- observed %>%
    transmute(
      location = .data$geo_region,
      target = "wk inc flu hosp",
      target_end_date = .data$date,
      oracle_value = .data$observed
    )

  metrics <- c(
    "wis", "overprediction", "underprediction", "dispersion", "bias", "ae_median",
    "interval_coverage_50", "interval_coverage_80", "interval_coverage_90",
    "interval_coverage_95", "interval_coverage_98"
  )
  hub_scores <- hubEvals::score_model_out(
    model_out_tbl = model_out_tbl,
    oracle_output = oracle_output,
    metrics = metrics,
    summarize = FALSE
  ) %>%
    as_tibble() %>%
    transmute(
      model_id = as.character(.data$model_id),
      date = as.Date(.data$target_end_date),
      wis = .data$wis,
      ae_median = .data$ae_median,
      dispersion = .data$dispersion,
      interval_coverage_98 = .data$interval_coverage_98,
      interval_coverage_95 = .data$interval_coverage_95,
      interval_coverage_90 = .data$interval_coverage_90,
      interval_coverage_80 = .data$interval_coverage_80,
      interval_coverage_50 = .data$interval_coverage_50
    )

  pred_wide %>%
    mutate(model_id = paste(.data$geo_region, .data$scenario_label, format(round(.data$disease_R0, 4), nsmall = 4), sep = "-")) %>%
    left_join(observed, by = c("geo_region", "date")) %>%
    filter(!is.na(.data$observed)) %>%
    left_join(hub_scores, by = c("model_id", "date")) %>%
    mutate(
      interval_score_98 = NA_real_,
      interval_score_95 = NA_real_,
      interval_score_90 = NA_real_,
      interval_score_80 = NA_real_,
      interval_score_50 = NA_real_,
      scoring_method = "hubEvals::score_model_out",
      .after = "sample_count"
    ) %>%
    select(
      "geo_region", "scenario_label", "disease_R0", "date", "sample_count", "scoring_method",
      "observed", "mean_generated", "q0_025", "q0_5", "q0_975",
      "wis", "ae_median", "dispersion",
      "interval_score_98", "interval_score_95", "interval_score_90", "interval_score_80", "interval_score_50",
      "interval_coverage_98", "interval_coverage_95", "interval_coverage_90", "interval_coverage_80", "interval_coverage_50"
    )
}

score_wis <- function(predictions, observed) {
  if (requireNamespace("hubEvals", quietly = TRUE)) {
    return(score_wis_hubevals(predictions, observed))
  }
  score_wis_manual(predictions, observed)
}

summarise_candidate <- function(scores) {
  if (nrow(scores) == 0) return(tibble())
  observed_peak <- max(scores$observed, na.rm = TRUE)
  predicted_peak <- max(scores$q0_5, na.rm = TRUE)
  observed_total <- sum(scores$observed, na.rm = TRUE)
  predicted_total <- sum(scores$q0_5, na.rm = TRUE)
  observed_peak_date <- scores$date[which.max(scores$observed)][[1]]
  predicted_peak_date <- scores$date[which.max(scores$q0_5)][[1]]
  peak_lag_weeks <- as.numeric(predicted_peak_date - observed_peak_date) / 7
  scores %>%
    summarise(
      geo_region = dplyr::first(.data$geo_region),
      scenario_label = dplyr::first(.data$scenario_label),
      disease_R0 = dplyr::first(.data$disease_R0),
      n_weeks = n(),
      sample_count = dplyr::first(.data$sample_count),
      mean_wis = mean(.data$wis, na.rm = TRUE),
      median_wis = median(.data$wis, na.rm = TRUE),
      mean_ae_median = mean(.data$ae_median, na.rm = TRUE),
      mean_dispersion = mean(.data$dispersion, na.rm = TRUE),
      observed_total = observed_total,
      predicted_median_total = predicted_total,
      total_ratio = (predicted_total + 1) / (observed_total + 1),
      observed_peak_height = observed_peak,
      predicted_peak_height = predicted_peak,
      peak_ratio = (predicted_peak + 1) / (observed_peak + 1),
      observed_peak_date = observed_peak_date,
      predicted_peak_date = predicted_peak_date,
      peak_lag_weeks = peak_lag_weeks,
      scored_week_start = min(.data$date),
      scored_week_end = max(.data$date),
      simulation_end_date = as.Date(sim_day_0) + simulation_days,
      scoring_version = R0_SCORING_VERSION,
      search_metrics = paste(r0_search_metrics, collapse = ","),
      .groups = "drop"
    ) %>% mutate(search_score = r0_metric_values(., r0_selection_metric))
}

evaluate_candidate <- function(state, r0) {
  r0 <- clip_r0(r0)
  input_file <- write_candidate_input(state, r0)
  metadata_file <- run_candidate(input_file, state, r0)
  if (is.na(metadata_file)) {
    return(list(
      summary = tibble(),
      scores = tibble(),
      predictions = tibble(),
      samples = tibble(),
      observed = tibble(),
      input_file = input_file,
      metadata_file = metadata_file
    ))
  }

  samples <- read_candidate_weekly_samples(metadata_file)
  predictions <- quantile_predictions(samples)
  observed <- read_observed_state_weekly(metadata_file)
  scores <- score_wis(predictions, observed)
  summary <- summarise_candidate(scores)
  list(
    summary = summary,
    scores = scores,
    predictions = predictions,
    samples = samples,
    observed = observed,
    input_file = input_file,
    metadata_file = metadata_file
  )
}

select_best_r0 <- function(summary_tbl, selection_metric = r0_selection_metric) {
  if (nrow(summary_tbl) == 0) return(tibble())
  summary_tbl %>%
    mutate(total_abs_error = abs(.data$predicted_median_total - .data$observed_total),
           peak_height_abs_error = abs(.data$predicted_peak_height - .data$observed_peak_height),
           peak_timing_abs_weeks = abs(.data$peak_lag_weeks),
           selection_metric = .env$selection_metric,
           selection_value = r0_metric_values(., .env$selection_metric)) %>%
    arrange(.data$selection_value, .data$disease_R0) %>% slice(1)
}

search_state <- function(state, search_base = base_r0, search_step = initial_step, search_min_step = min_step) {
  state <- normalize_state_dir(state)
  message("\nSearching R0 for ", state, " using ", paste(r0_search_metrics, collapse = ", "))
  evaluated <- new.env(parent = emptyenv())
  trace <- list(); summary_history <- list(); all_scores <- list(); all_predictions <- list()
  center <- clip_r0(search_base); step <- search_step; exploration_centers <- center
  seen_candidate_windows <- character()
  get_eval <- function(r0) {
    key <- r0_key(r0)
    if (exists(key, evaluated, inherits = FALSE)) return(get(key, evaluated, inherits = FALSE))
    result <- evaluate_candidate(state, as.numeric(key))
    assign(key, result, evaluated)
    if (nrow(result$scores)) all_scores[[length(all_scores) + 1]] <<- result$scores
    if (nrow(result$predictions)) all_predictions[[length(all_predictions) + 1]] <<- result$predictions
    result
  }
  for (iter in seq_len(max_iterations)) {
    repeat {
      candidates <- sort(unique(unlist(purrr::map(exploration_centers, ~ c(.x, .x - step, .x + step)))))
      candidates <- candidates[candidates >= r0_min & candidates <= r0_max]
      signature <- paste(formatC(candidates, format = "f", digits = 4), collapse = "|")
      if (!signature %in% seen_candidate_windows || step < search_min_step) break
      step <- step * step_shrink
    }
    if (step < search_min_step) break
    seen_candidate_windows <- c(seen_candidate_windows, signature)
    summaries <- purrr::map_dfr(purrr::map(candidates, get_eval), "summary")
    if (!nrow(summaries)) stop("No scored candidates for ", state)
    summary_history[[length(summary_history) + 1]] <- summaries
    explored <- bind_rows(summary_history) %>% distinct(.data$disease_R0, .keep_all = TRUE)
    path_best <- purrr::map_dfr(r0_search_metrics, ~ select_best_r0(explored, .x))
    iter_best <- select_best_r0(summaries, r0_selection_metric)
    trace[[length(trace) + 1]] <- summaries %>%
      mutate(iteration = iter, step = step, search_center = center,
             search_centers = paste0("R0=", paste(exploration_centers, collapse = "|")), .before = 1)
    message("  iter=", iter, " step=", step, " selected=", r0_key(iter_best$disease_R0),
            " ", r0_selection_metric, " error=", round(iter_best$selection_value, 3),
            " path centers=", paste(r0_key(path_best$disease_R0), collapse = ","))
    next_centers <- sort(unique(path_best$disease_R0))
    # Refine only when every requested path has stopped moving and none is at
    # the evaluated frontier. Unrequested criteria never steer exploration.
    frontier <- any((next_centers <= min(explored$disease_R0) + 1e-8 & next_centers > r0_min) |
                    (next_centers >= max(explored$disease_R0) - 1e-8 & next_centers < r0_max))
    if (identical(next_centers, sort(unique(exploration_centers))) && !frontier) step <- step * step_shrink
    center <- select_best_r0(explored, r0_selection_metric)$disease_R0
    exploration_centers <- next_centers
    if (step < search_min_step) break
  }
  explored <- bind_rows(summary_history) %>% distinct(.data$disease_R0, .keep_all = TRUE)
  selected <- select_best_r0(explored, r0_selection_metric) %>% mutate(r0_selection_metric = r0_selection_metric)
  final <- get_eval(selected$disease_R0)
  list(best = selected, trace = bind_rows(trace), scores = bind_rows(all_scores) %>% distinct(),
       predictions = bind_rows(all_predictions) %>% distinct(), final_samples = final$samples,
       final_observed = final$observed, final_scores = final$scores)
}

# Staged fitting shares the existing evaluator, adaptive R0 search, plotting,
# calibrated JSON writer and state checkpoints. Only candidate E0/ranges differ.
exposure_allocation_key <- function(rows) {
  sort(vapply(rows, function(row) paste(as.character(row$county), as.integer(row$age_group),
    as.integer(row$infected), sep = ":"), character(1)))
}

scale_initial_exposed <- function(rows, total) {
  weights <- vapply(rows, function(row) as.numeric(row$infected), numeric(1))
  if (sum(weights) <= 0 || total < 1) stop("Staged fitting requires positive original exposures.")
  exact <- weights / sum(weights) * total
  counts <- floor(exact)
  remaining <- as.integer(total - sum(counts))
  if (remaining) {
    chosen <- order(-(exact - counts), seq_along(counts))[seq_len(remaining)]
    counts[chosen] <- counts[chosen] + 1
  }
  result <- Map(function(row, count) { row$infected <- as.character(count); row }, rows, counts)
  result[counts > 0]
}

rank_exposure_candidates <- function(rows, tolerance = peak_height_tolerance, prefer_original = FALSE) {
  rows$exposure_distance <- if (prefer_original && "original_initial_exposed_total" %in% names(rows))
    abs(log(rows$initial_exposed_total / rows$original_initial_exposed_total)) else 0
  rows %>% mutate(
    height_error = abs(.data$predicted_peak_height / pmax(.data$observed_peak_height, 1e-12) - 1),
    height_ok = .data$height_error <= tolerance + 1e-12,
    timing_rank = if_else(.data$height_ok, abs(.data$peak_lag_weeks), .data$height_error)) %>%
    arrange(desc(.data$height_ok), .data$timing_rank, .data$exposure_distance, .data$mean_wis, .data$height_error)
}

next_exposure_total <- function(records, final) {
  current <- final$initial_exposed_total[[1]]
  lag <- final$peak_lag_weeks[[1]]
  options <- records$initial_exposed_total[records$sample_count == final$sample_count[[1]] &
    ((lag > 0 & records$initial_exposed_total > current) | (lag < 0 & records$initial_exposed_total < current))]
  if (!length(options)) return(NULL)
  neighbor <- options[which.min(abs(log(options/current)))]
  if (max(neighbor, current)/min(neighbor, current) <= 2) neighbor else floor(sqrt(neighbor*current) + .5)
}

# Bracket peak timing in log(E0), then refine toward the original seed on a
# matching-week plateau. No smooth or globally monotonic response is assumed.
next_adaptive_exposure <- function(rows, original, lower, upper, relative_tolerance = .1) {
  rows <- rows %>% arrange(.data$initial_exposed_total) %>%
    distinct(.data$initial_exposed_total, .keep_all = TRUE)
  totals <- rows$initial_exposed_total
  lag <- rows$peak_lag_weeks
  midpoint <- function(a, b) {
    if (abs(a-b) <= 1 || abs(log(a/b)) <= log1p(relative_tolerance)) return(NULL)
    value <- as.integer(floor(sqrt(a*b) + .5))
    if (value %in% totals || value <= lower || value >= upper) return(NULL)
    value
  }
  zero <- which(lag == 0)
  if (length(zero)) {
    best <- zero[which.min(abs(log(totals[zero]/original)))]
    if (totals[best] == original) return(NULL)
    toward <- which((totals-totals[best])*(original-totals[best]) > 0 &
      abs(log(totals/original)) < abs(log(totals[best]/original)))
    if (!length(toward)) return(NULL)
    neighbor <- toward[which.min(abs(log(totals[toward]/totals[best])))]
    return(midpoint(totals[best], totals[neighbor]))
  }
  if (length(totals) > 1L) {
    brackets <- which(head(lag,-1L)*tail(lag,-1L) < 0)
    if (length(brackets)) {
      i <- brackets[which.min(log(totals[brackets+1L]/totals[brackets]))]
      return(midpoint(totals[i], totals[i+1L]))
    }
  }
  best <- order(abs(lag), abs(log(totals/original)))[[1]]
  value <- if (lag[best] < 0) max(lower, floor(min(totals)/2 + .5)) else
    min(upper, floor(max(totals)*2 + .5))
  if (value %in% totals) NULL else as.integer(value)
}

make_staged_context <- function(state) {
  seed_path <- seed_input_file(state)
  seed <- jsonlite::read_json(seed_path)
  base <- absolutize_data_paths(jsonlite::read_json(base_input_file(state)), base_input_file(state))
  original <- sum(vapply(seed$initial_exposed, function(row) as.numeric(row$infected), numeric(1)))
  if (original < 1) stop(state, ": no original Section 5a exposures to scale.")
  base$disease_model$parameters$R0 <- NULL
  settings <- list(version = staged_version, scenario = scenario_label, simulation_days = simulation_days,
    realization_range = realization_range, screening_realizations = min(screening_realizations, diff(realization_range) + 1L),
    exposure_multipliers = exposure_multipliers, height_tolerance = peak_height_tolerance,
    base_r0 = base_r0, refine_step = refine_step, exposure_max_rounds = 8L,
    exposure_relative_tolerance = .1, coordinate_passes = 3L,
    r0_selection_metric = "peak_height", search_metrics = "peak_height")
  sources <- c(list.files(file.path(repo_root, "src"), pattern = "[.]py$", recursive = TRUE, full.names = TRUE),
    file.path(repo_root, "scripts", c("5c_Rm_search.R", "5c_Rm_search_helpers.R")))
  inputs <- c(seed_path, unlist(base$data), resolve_validation_file(base), none_template_file,
    vaccine_template_file, antiviral_template_file, npi_template_file, all_interventions_template_file,
    file.path(repo_root, "data", "VACCINATION", "all_US_weekly_vax_distribution.csv"),
    file.path(repo_root, "data", "RISK_RATIOS", "state_insured-high-risk-antiviral-counts.csv"))
  inputs <- unique(inputs[file.exists(inputs)])
  manifest <- function(paths, pipeline = FALSE) {
    paths <- normalizePath(paths, mustWork = TRUE)
    names <- vapply(paths, function(path) {
      if (pipeline && startsWith(path, paste0(pipeline_root, "/"))) return(paste0("pipeline:", substring(path, nchar(pipeline_root) + 2L)))
      if (startsWith(path, paste0(repo_root, "/"))) substring(path, nchar(repo_root) + 2L) else path
    }, character(1))
    as.list(setNames(unname(tools::md5sum(paths)), names))
  }
  source_hashes <- manifest(sort(sources))
  input_hashes <- manifest(inputs, TRUE)
  protected <- base[c("disease_model", "travel_model", "non_pharma_interventions", "antiviral_model", "vaccine_model")]
  payload <- list(settings = settings, original_exposed = seed$initial_exposed,
    protected = protected, source_hashes = source_hashes, input_hashes = input_hashes)
  temporary <- tempfile()
  on.exit(unlink(temporary), add = TRUE)
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, digits = NA, null = "null"), temporary)
  signature <- unname(tools::md5sum(temporary))
  list(state = state, original_rows = seed$initial_exposed, original_total = original,
    settings = settings, source_hashes = source_hashes, input_hashes = input_hashes, run_signature = signature)
}

search_state_staged <- function(state) {
  original_context <- make_staged_context(state)
  confirm_n <- diff(realization_range) + 1L
  trials <- list()
  run_stage <- function(total, n, center, search = FALSE, step = initial_step, minimum = min_step,
                        stage = "E0 screen") {
    context <- original_context
    context$rows <- scale_initial_exposed(context$original_rows, total)
    context$realization_range <- c(realization_range[[1]], realization_range[[1]] + n - 1L)
    suffix <- file.path(state, context$run_signature, paste0("E", total, "_N", n))
    context$sim_dir <- file.path(sim_output_dir, suffix)
    context$input_dir <- file.path(candidate_input_dir, suffix)
    dir.create(context$sim_dir, recursive = TRUE, showWarnings = FALSE)
    dir.create(context$input_dir, recursive = TRUE, showWarnings = FALSE)
    previous <- active_staged_context
    active_staged_context <<- context
    on.exit(active_staged_context <<- previous, add = TRUE)
    message(state, ": E0=", total, ", realizations=", n, if (search) "; adaptive R0" else paste0("; fixed R0=", center))
    if (search) result <- search_state(state, center, step, minimum) else {
      evaluated <- evaluate_candidate(state, center)
      best <- select_best_r0(evaluated$summary) %>% mutate(r0_selection_metric = r0_selection_metric)
      result <- list(best = best, trace = best %>% mutate(iteration = 1L, step = 0,
        search_center = center, search_centers = paste0("R0=", r0_key(center))),
        scores = evaluated$scores, predictions = evaluated$predictions,
        final_samples = evaluated$samples, final_observed = evaluated$observed, final_scores = evaluated$scores)
    }
    result$best <- result$best %>% mutate(trial_id = length(trials) + 1L, stage = stage,
      adaptive_search = search, initial_exposed_total = total,
      original_initial_exposed_total = context$original_total, exposure_multiplier = total/context$original_total)
    result$context <- context
    result$adaptive_search <- search
    trials[[length(trials) + 1L]] <<- result
    result
  }
  # Every evaluated Rm is eligible for the incumbent, including candidates
  # that were not the height-optimal point returned by an Rm refinement.
  pool <- function(n = confirm_n) {
    bind_rows(lapply(trials, function(trial) {
      trial$trace %>% distinct(.data$disease_R0, .keep_all = TRUE) %>% mutate(
        trial_id = trial$best$trial_id[[1]], stage = trial$best$stage[[1]],
        initial_exposed_total = trial$best$initial_exposed_total[[1]],
        original_initial_exposed_total = original_context$original_total,
        exposure_multiplier = .data$initial_exposed_total / original_context$original_total)
    })) %>% filter(.data$sample_count == n)
  }
  incumbent <- function() rank_exposure_candidates(pool(), prefer_original = TRUE) %>% slice(1L)
  original <- original_context$original_total
  screen_n <- original_context$settings$screening_realizations
  baseline <- run_stage(original, screen_n, base_r0, search = TRUE, stage = "Initial Rm search")
  if (baseline$best$observed_peak_height[[1]] <= 0) stop(state, ": no positive observed peak in the fitting window.")
  confirmed_original <- if (screen_n < confirm_n) run_stage(original, confirm_n, baseline$best$disease_R0[[1]],
    search = TRUE, step = 2*refine_step, minimum = refine_step, stage = "Confirm original E0: refine Rm") else baseline
  lower <- max(1L, as.integer(floor(original*min(exposure_multipliers) + .5)))
  upper <- max(original, as.integer(floor(original*max(exposure_multipliers) + .5)))
  current <- confirmed_original$best
  selected <- baseline
  stop_reason <- "coordinate pass limit"
  for (pass in seq_len(3L)) {
    before <- current
    center <- current$disease_R0[[1]]
    total <- current$initial_exposed_total[[1]]
    probes <- list()
    for (iteration in seq_len(8L)) {
      trial <- run_stage(total, screen_n, center,
        stage = paste0("E0 bracket/refine ", pass, ".", iteration))
      probes[[length(probes)+1L]] <- trial
      probe_rows <- bind_rows(lapply(probes, `[[`, "best"))
      total <- next_adaptive_exposure(probe_rows, original, lower, upper)
      if (is.null(total)) break
    }
    # Timing determines which E0 to recheck with Rm, even when that E0's
    # current height misses tolerance. This avoids rejecting a viable pair
    # before Rm has had a chance to compensate.
    target <- bind_rows(lapply(probes, `[[`, "best")) %>% mutate(
      height_error = abs(.data$predicted_peak_height/.data$observed_peak_height-1),
      distance = abs(log(.data$initial_exposed_total/original))) %>%
      arrange(abs(.data$peak_lag_weeks), .data$distance, .data$height_error, .data$mean_wis) %>% slice(1L)
    selected <- probes[[which(vapply(probes, function(x)
      x$best$trial_id[[1]] == target$trial_id[[1]], logical(1)))[[1]]]]
    refined <- run_stage(target$initial_exposed_total[[1]], confirm_n, center,
      search = TRUE, step = 2*refine_step, minimum = refine_step,
      stage = paste0("Refine Rm at adaptive E0 ", pass))
    best_so_far <- incumbent()
    if (best_so_far$height_ok[[1]] && best_so_far$peak_lag_weeks[[1]] == 0) {
      stop_reason <- "matching peak week within height tolerance"; break
    }
    # Exploration follows the refined pair even when the incumbent remains
    # better. A new coordinate can be a bridge to a better E0 on the next pass.
    current <- refined$best
    if (pass > 1L && identical(current$initial_exposed_total[[1]], before$initial_exposed_total[[1]]) &&
        abs(current$disease_R0[[1]]-before$disease_R0[[1]]) < 1e-8) {
      stop_reason <- "exploratory coordinate pair unchanged"; break
    }
  }
  winner <- incumbent()
  final <- trials[[winner$trial_id[[1]]]]
  # Materialize the retained point from its completed batch; this may be an
  # earlier point in an adaptive Rm search rather than that search's height best.
  previous <- active_staged_context
  active_staged_context <<- final$context
  evaluated <- tryCatch(evaluate_candidate(state, winner$disease_R0[[1]]),
    finally = {active_staged_context <<- previous})
  final$best <- select_best_r0(evaluated$summary) %>% mutate(
    trial_id = winner$trial_id[[1]], stage = winner$stage[[1]],
    adaptive_search = final$adaptive_search,
    initial_exposed_total = winner$initial_exposed_total[[1]],
    original_initial_exposed_total = original, exposure_multiplier = .data$initial_exposed_total/original,
    r0_selection_metric = r0_selection_metric)
  final$final_samples <- evaluated$samples
  final$final_observed <- evaluated$observed
  final$final_scores <- evaluated$scores
  records <- bind_rows(lapply(trials, `[[`, "best"))
  final$best <- final$best %>% mutate(fit_method = "full_simulator_staged_r0_exposures",
    peak_height_within_tolerance = abs(.data$predicted_peak_height/.data$observed_peak_height - 1) <= peak_height_tolerance + 1e-12,
    median_peak_week_matches = .data$peak_lag_weeks == 0)
  assign(state, final$context, winning_staged_contexts)
  audit_dir <- file.path(sweep_root, "staged", state)
  dir.create(audit_dir, recursive = TRUE, showWarnings = FALSE)
  final$procedure <- records
  final$procedure[final$best$trial_id[[1]], names(final$best)] <- final$best
  final$procedure <- final$procedure %>% mutate(final_selected = .data$trial_id == final$best$trial_id[[1]])
  readr::write_csv(pool(), file.path(audit_dir, "searched_candidates.csv"))
  final$procedure$tested_r0_min <- vapply(trials, function(trial) min(trial$trace$disease_R0), numeric(1))
  final$procedure$tested_r0_max <- vapply(trials, function(trial) max(trial$trace$disease_R0), numeric(1))
  final$procedure$tested_rm <- vapply(trials, function(trial)
    paste(sort(unique(trial$trace$disease_R0)), collapse = "|"), character(1))
  readr::write_csv(final$procedure, file.path(audit_dir, "procedure.csv"))
  # Preserve each adaptive search separately: exposures and replicate counts
  # change between stages, so their error values must not share one path.
  adaptive_trials <- Filter(function(trial) isTRUE(trial$adaptive_search), trials)
  final$search_window_trace <- bind_rows(lapply(seq_along(adaptive_trials), function(i) {
    trial <- adaptive_trials[[i]]
    trial$trace %>% mutate(search_stage = paste0(if (i == 1L) "Initial search" else paste0("Refinement ", i - 1L),
      "; E0=", trial$best$initial_exposed_total[[1]], "; n=", trial$best$sample_count[[1]]))
  }))
  readr::write_csv(final$search_window_trace, file.path(audit_dir, "search_windows.csv"))
  readr::write_csv(records, file.path(audit_dir, "candidates.csv"))
  jsonlite::write_json(list(baseline = baseline$best, exposure_selected = selected$best, final = final$best, stop_reason = stop_reason),
    file.path(audit_dir, "result.json"), auto_unbox = TRUE, pretty = TRUE, digits = NA)
  final
}

scenario_plot_label <- function(value) {
  stringr::str_to_title(gsub("_", " ", value, fixed = TRUE))
}

plot_sample_cache <- new.env(parent = emptyenv())

candidate_plot_samples <- function(state_result, selected_r0) {
  state <- state_result$best$geo_region[[1]]
  purrr::map_dfr(selected_r0, function(r0) {
    if (!is.null(state_result$final_samples) &&
        abs(r0 - state_result$best$disease_R0[[1]]) < 1e-8) {
      return(state_result$final_samples)
    }
    metadata_file <- complete_metadata_for_candidate(state, r0)
    if (is.na(metadata_file)) stop("Missing saved realization trajectories for ", state, " R_m=", r0)
    if (!exists(metadata_file, plot_sample_cache, inherits = FALSE)) {
      assign(metadata_file, read_candidate_weekly_samples(metadata_file), plot_sample_cache)
    }
    get(metadata_file, plot_sample_cache, inherits = FALSE)
  })
}

plot_final_fit <- function(state_result) {
  plot_featured_candidate_fit(state_result, final_only = TRUE)
}

plot_final_fit_from_scores <- function(state_result) {
  # The quantile table cannot reconstruct individual stochastic trajectories.
  # Read the completed candidate's existing weekly samples; never run new sims.
  plot_final_fit(state_result)
}

featured_candidate_rows <- function(state_result) {
  summaries <- state_result$trace %>% distinct(.data$disease_R0, .keep_all = TRUE)
  purrr::map_dfr(r0_search_metrics, function(metric) {
    select_best_r0(summaries, metric) %>%
      mutate(optimization_choice = r0_metric_label(metric), metric_value = .data$selection_value,
             r0_label = paste0(format(round(.data$disease_R0, 2), nsmall = 2), " ", .data$optimization_choice))
  })
}

plot_featured_candidate_fit <- function(state_result, final_only = FALSE) {
  featured <- if (final_only) {
    state_result$best %>% mutate(optimization_choice = r0_metric_label(r0_selection_metric))
  } else featured_candidate_rows(state_result)
  if (nrow(featured) == 0) return(NA_character_)

  state <- featured$geo_region[[1]]
  selected_r0 <- sort(unique(featured$disease_R0))
  label_by_r0 <- featured %>%
    group_by(.data$disease_R0) %>%
    summarise(
      optimization_choices = list(sort(unique(.data$optimization_choice))),
      first_optimization_choice = .data$optimization_choices[[1]][[1]],
      r0_label = paste0(
        format(round(dplyr::first(.data$disease_R0), 2), nsmall = 2),
        " ",
        paste(.data$optimization_choices[[1]], collapse = ", ")
      ),
      .groups = "drop"
    ) %>%
    arrange(.data$first_optimization_choice, .data$r0_label)

  samples <- candidate_plot_samples(state_result, selected_r0) %>%
    left_join(label_by_r0, by = "disease_R0") %>%
    mutate(r0_label = factor(.data$r0_label, levels = label_by_r0$r0_label))
  trajectory <- samples %>%
    group_by(.data$date, .data$disease_R0, .data$r0_label) %>%
    summarise(q0_5 = median(.data$generated),
              q0_025 = as.numeric(stats::quantile(.data$generated, 0.025, names = FALSE)),
              q0_975 = as.numeric(stats::quantile(.data$generated, 0.975, names = FALSE)),
              .groups = "drop")
  single_candidate <- length(selected_r0) == 1
  sample_counts <- samples %>% distinct(.data$disease_R0, .data$sim_id) %>% count(.data$disease_R0)
  sample_count_label <- paste(sort(unique(sample_counts$n)), collapse = "–")

  observed <- state_result$final_observed
  if (nrow(trajectory) == 0 || nrow(observed) == 0) return(NA_character_)
  fit_start_date <- min(observed$date)
  guide_labels <- tibble(
    date = fit_start_date,
    label = "first complete\nMMWR week",
    linetype = "longdash",
    hjust = -0.05
  )

  metric_color_values <- c(
    `Peak Height` = "#bd6b4f",
    Timing = "#f2ad2e",
    Total = "#596246",
    WIS = "#2f8990"
  )
  color_values <- metric_color_values[label_by_r0$first_optimization_choice]
  names(color_values) <- label_by_r0$r0_label

  plot_title <- if (single_candidate) {
    paste0(state_plot_label(state), " ", scenario_plot_label(scenario_label),
           " · R_m = ", format(selected_r0[[1]], trim = TRUE))
  } else paste0(state_plot_label(state), " ", scenario_plot_label(scenario_label), " R_m comparison")
  base_size <- if (final_only) 15 else 28
  p <- ggplot(trajectory, aes(x = .data$date)) +
    {if (final_only) geom_ribbon(
      aes(ymin = .data$q0_025, ymax = .data$q0_975, fill = .data$r0_label),
      alpha = 0.2, show.legend = FALSE)
     else geom_line(data = samples,
      aes(y = .data$generated, color = .data$r0_label,
          group = interaction(.data$disease_R0, .data$sim_id)),
      alpha = 0.2, linewidth = 0.45, show.legend = FALSE)} +
    geom_vline(
      data = guide_labels,
      aes(xintercept = .data$date, linetype = .data$linetype),
      color = "#666666",
      linewidth = 0.45,
      show.legend = FALSE
    ) +
    geom_label(
      data = guide_labels,
      aes(x = .data$date, y = Inf, label = .data$label, hjust = .data$hjust),
      inherit.aes = FALSE,
      vjust = 1.8,
      color = "#555555",
      size = if (final_only) 3.5 else 6.0,
      lineheight = 0.92
    ) +
    geom_line(aes(y = .data$q0_5, color = .data$r0_label), linewidth = 1.25) +
    geom_point(
      data = observed,
      aes(x = .data$date, y = .data$observed),
      inherit.aes = FALSE,
      color = "#d73027",
      size = if (final_only) 2.3 else 4.2,
      alpha = 0.92
    ) +
    scale_linetype_identity() +
    scale_color_manual(values = color_values, drop = FALSE) +
    {if (final_only) scale_fill_manual(values = color_values, drop = FALSE)} +
    labs(
      x = NULL,
      y = "Weekly incident hospitalizations",
      title = plot_title,
      subtitle = paste0(
        if (final_only) paste0("Median and 95% simulation interval from ", sample_count_label, " simulations")
        else paste0("Dark median and ", sample_count_label, " individual simulations"),
        "; validation = red points\nComplete MMWR weeks: ",
        format(min(observed$date)), " to ", format(max(observed$date))
      ),
      color = "R_m"
    ) +
    theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      axis.title.y = element_text(size = base_size + 2),
      axis.text = element_text(size = base_size - 1),
      plot.title = element_text(face = "bold", size = base_size + 6),
      plot.subtitle = element_text(size = base_size - 1),
      legend.position = if (single_candidate) "none" else "bottom",
      legend.title = element_text(face = "bold", size = 27),
      legend.text = element_text(size = 25),
      legend.key.width = grid::unit(1.15, "cm")
    )

  out_file <- file.path(plot_dir, paste0(state, if (final_only) "_final_r0_fit.png" else "_r0_feature_candidates.png"))
  p <- rm_plot_labels(p)
  ggsave(out_file, p, width = if (final_only) 9 else 13.3, height = if (final_only) 5.2 else 7.5, dpi = 300)
  out_file
}

plot_wis_loss_landscape <- function(state_result) {
  trace <- state_result$trace
  if (nrow(trace) == 0) return(NA_character_)
  state <- trace$geo_region[[1]]
  trace$metric_value <- r0_metric_values(trace, r0_selection_metric)
  state_summary <- trace %>%
    arrange(.data$geo_region, .data$disease_R0, .data$search_score) %>%
    group_by(.data$geo_region, .data$disease_R0) %>%
    slice(1) %>%
    ungroup() %>%
    mutate(first_iteration = vapply(.data$disease_R0, function(r0) {
      min(trace$iteration[abs(trace$disease_R0 - r0) < 1e-8])
    }, numeric(1)))

  high_risk_gradient <- c("#f3e79b", "#fac484", "#f8a07e", "#eb7f86", "#ce6693", "#a059a0", "#5c53a5")
  search_round_breaks <- sort(unique(state_summary$first_iteration))

  best <- select_best_r0(state_summary, r0_selection_metric)
  plot_data <- state_summary %>% mutate(search_round = .data$first_iteration,
                                        search_round_label = as.character(.data$first_iteration))
  selection_note <- paste0("Minimum ", r0_metric_axis_label(r0_selection_metric), " selects R_m ",
                           formatC(best$disease_R0, format = "f", digits = 3))

  p <- ggplot(plot_data, aes(x = .data$disease_R0, y = .data$metric_value)) +
    geom_line(color = "#737373", linewidth = 0.6) +
    geom_point(aes(color = .data$search_round), size = 3.0) +
    geom_text(
      aes(label = .data$search_round_label, color = .data$search_round),
      size = 3.4,
      show.legend = FALSE,
      nudge_y = 0.035 * diff(range(plot_data$metric_value, na.rm = TRUE))
    ) +
    geom_vline(xintercept = best$disease_R0, color = "#2f8990", linewidth = 0.75) +
    scale_color_gradientn(
      colors = high_risk_gradient,
      breaks = search_round_breaks,
      guide = guide_colorbar(
        barheight = grid::unit(3.2, "cm"),
        ticks = TRUE
      )
    ) +
    labs(
      x = "Candidate R_m",
      y = r0_metric_axis_label(r0_selection_metric),
      color = "Search Round",
      title = paste0(state_plot_label(state), " R_m loss landscape"),
      subtitle = paste0(stringr::str_wrap(selection_note, width = 82), "\nPoint labels show the search round when each R_m was first evaluated")
    ) +
    theme_minimal(base_size = 9) +
    theme(
      panel.grid.minor = element_blank(),
      plot.title = element_text(face = "bold"),
      plot.subtitle = element_text(lineheight = 1.05),
      legend.position = "right"
    )

  out_file <- file.path(plot_dir, paste0(state, "_r0_loss_landscape.png"))
  p <- rm_plot_labels(p)
  ggsave(out_file, p, width = 9.2, height = 5.6, dpi = 220)
  out_file
}

plot_wis_convergence <- function(state_result) {
  trace <- state_result$trace
  if (nrow(trace) == 0) return(NA_character_)
  state <- trace$geo_region[[1]]
  trace$search_score <- r0_metric_values(trace, r0_selection_metric)
  iter_best <- trace %>%
    arrange(.data$iteration, .data$search_score, .data$disease_R0) %>%
    group_by(.data$iteration) %>%
    slice(1) %>%
    ungroup() %>%
    arrange(.data$iteration) %>%
    mutate(
      best_score_so_far = cummin(.data$search_score),
      best_changed = .data$best_score_so_far < dplyr::lag(.data$best_score_so_far, default = Inf)
    )

  score_panel <- iter_best %>%
    transmute(
      iteration = .data$iteration,
      value = .data$best_score_so_far,
      panel = paste0("Best ", r0_metric_label(r0_selection_metric), " error so far"),
      best_changed = .data$best_changed
    )
  step_panel <- iter_best %>%
    transmute(
      iteration = .data$iteration,
      value = .data$step,
      panel = "Search step size",
      best_changed = .data$best_changed
    )
  plot_data <- bind_rows(score_panel, step_panel)

  p <- ggplot(plot_data, aes(x = .data$iteration, y = .data$value)) +
    geom_line(color = "#2f8990", linewidth = 0.85) +
    geom_point(aes(shape = .data$best_changed), color = "#2f8990", size = 2.6) +
    facet_wrap(~panel, scales = "free_y", ncol = 1) +
    scale_shape_manual(values = c(`TRUE` = 16, `FALSE` = 1), labels = c(`TRUE` = "Improved", `FALSE` = "No improvement")) +
    scale_x_continuous(breaks = sort(unique(plot_data$iteration))) +
    labs(
      x = "Adaptive search iteration",
      y = NULL,
      shape = "Best score",
      title = paste0(state_plot_label(state), paste0(" ", r0_metric_label(r0_selection_metric), " R_m convergence")),
      subtitle = paste0(
        "The search stops when step size drops below ",
        formatC(if (fit_initial_exposed) refine_step else min_step, format = "f", digits = 3),
        " or after ",
        max_iterations,
        " iterations"
      )
    ) +
    theme_minimal(base_size = 13) +
    theme(
      panel.grid.minor = element_blank(),
      plot.title = element_text(face = "bold"),
      legend.position = "bottom"
    )

  out_file <- file.path(plot_dir, paste0(state, "_r0_convergence.png"))
  p <- rm_plot_labels(p)
  ggsave(out_file, p, width = 8.8, height = 6.8, dpi = 220)
  out_file
}

plot_staged_procedure <- function(records, state, path) {
  records <- records %>% arrange(.data$trial_id) %>% mutate(
    height_error_percent = 100 * (.data$predicted_peak_height/.data$observed_peak_height - 1),
    row_label = paste0(stringr::str_wrap(paste0(sprintf("%02d", .data$trial_id), ". ", .data$stage), width = 27),
      "\n(n=", .data$sample_count, ")", if_else(.data$final_selected, " [FINAL]", "")))
  panels <- c("Rm", "Initial\nexposed", "Peak height\nerror (%)", "Peak lag\n(weeks)")
  data <- bind_rows(
    transmute(records, trial_id, final_selected, panel = panels[1], value = disease_R0,
      label = sprintf("%.3f", disease_R0)),
    transmute(records, trial_id, final_selected, panel = panels[2], value = initial_exposed_total,
      label = as.character(initial_exposed_total)),
    transmute(records, trial_id, final_selected, panel = panels[3], value = height_error_percent,
      label = sprintf("%+.1f%%", height_error_percent)),
    transmute(records, trial_id, final_selected, panel = panels[4], value = peak_lag_weeks,
      label = sprintf("%+d", as.integer(peak_lag_weeks)))) %>%
    mutate(panel = factor(.data$panel, levels = panels))
  band <- tibble(panel = factor(panels[3], levels = panels),
    low = -100*peak_height_tolerance, high = 100*peak_height_tolerance)
  zero <- tibble(panel = factor(panels[3:4], levels = panels), value = 0)
  ranges <- records %>% filter(.data$adaptive_search) %>% mutate(panel = factor(panels[1], levels = panels))
  tested <- if ("tested_rm" %in% names(ranges)) ranges %>%
    transmute(trial_id, panel, value = strsplit(.data$tested_rm, "|", fixed = TRUE)) %>%
    tidyr::unnest_longer("value") %>% mutate(value = as.numeric(.data$value)) else tibble()
  p <- ggplot(data, aes(x = .data$value, y = .data$trial_id)) +
    geom_rect(data = band, aes(xmin = .data$low, xmax = .data$high, ymin = -Inf, ymax = Inf),
      inherit.aes = FALSE, fill = "#e5f1e7") +
    geom_vline(data = zero, aes(xintercept = .data$value), inherit.aes = FALSE,
      color = "#888888", linetype = "dashed", linewidth = .4) +
    geom_hline(yintercept = records$trial_id[records$final_selected], color = "#fce9cf", linewidth = 7) +
    geom_segment(data = ranges,
      inherit.aes = FALSE, mapping = aes(x = .data$tested_r0_min, xend = .data$tested_r0_max,
        y = .data$trial_id, yend = .data$trial_id), color = "#aaaaaa", linewidth = 1) +
    geom_point(data = tested, aes(x = .data$value, y = .data$trial_id), inherit.aes = FALSE,
      color = "#888888", fill = "white", shape = 21, size = 2.2) +
    geom_point(aes(color = .data$final_selected), size = 2.4) +
    geom_text(aes(label = .data$label), nudge_y = -.24, size = 4) +
    scale_color_manual(values = c("FALSE" = "#347d86", "TRUE" = "#dd7000"), guide = "none") +
    facet_wrap(vars(.data$panel), nrow = 1, scales = "free_x") +
    scale_y_reverse(breaks = records$trial_id, labels = records$row_label,
      expand = expansion(add = c(.8, .5))) +
    scale_x_continuous(expand = expansion(mult = .12, add = .05)) +
    labs(title = paste0(state_plot_label(state), ": staged fitting procedure"),
      subtitle = "Comparisons in execution order; the highlighted row is the retained final fit",
      x = NULL, y = NULL,
      caption = stringr::str_wrap(paste(
        "Each row is one E0 comparison or an adaptive Rm search. Hollow grey dots show every Rm tested; the colored dot shows the row's representative result (the retained point on the highlighted row).",
        "Rows are trials, not successive accepted fits. Final E0 selection prioritizes peak-week alignment within the green height tolerance band, then proximity to the hospital-derived E0, then WIS.",
        "Rm searches minimize peak-height error. Negative peak lag means early; positive means late.",
        "Earlier eligible candidates remain available after refinement."), width = 104)) +
    theme_minimal(base_size = 14) +
    theme(panel.grid.minor = element_blank(), panel.grid.major.y = element_line(color = "#eeeeee"),
      axis.text.y = element_text(size = 13, lineheight = .95),
      strip.text = element_text(face = "bold", size = 14), plot.title = element_text(face = "bold", size = 21),
      plot.caption = element_text(hjust = 0, size = 11.5), panel.spacing.x = unit(.7, "lines"))
  ggsave(path, p, width = 12, height = max(8, 3.3 + .63*nrow(records)), dpi = 200)
  path
}

plot_wis_search_windows <- function(state_result) {
  trace <- state_result$trace
  if (!nrow(trace)) return(NA_character_)
  state <- trace$geo_region[[1]]
  window_trace <- state_result$search_window_trace
  saved_windows <- file.path(sweep_root, "staged", state, "search_windows.csv")
  if (is.null(window_trace) && fit_initial_exposed && file.exists(saved_windows)) {
    window_trace <- readr::read_csv(saved_windows, show_col_types = FALSE)
  }
  if (!is.null(window_trace) && nrow(window_trace)) trace <- window_trace
  staged <- "search_stage" %in% names(trace)
  if (staged) {
    stages <- unique(trace$search_stage)
    parts <- lapply(stages, function(stage) {
      part <- r0_search_window_data(filter(trace, .data$search_stage == stage), r0_search_metrics, r0_min, r0_max)
      lapply(part, function(rows) mutate(rows, facet_label = paste0(stage, "\n", .data$facet_label)))
    })
    data <- setNames(lapply(names(parts[[1]]), function(key) bind_rows(lapply(parts, `[[`, key))), names(parts[[1]]))
    for (key in names(data)) data[[key]]$facet_label <- factor(data[[key]]$facet_label,
      levels = unique(data$points$facet_label))
  } else data <- r0_search_window_data(trace, r0_search_metrics, r0_min, r0_max)
  if (!nrow(data$points)) return(NA_character_)
  n_panels <- length(unique(data$points$facet_label))
  caption_text <- stringr::str_wrap(paste(
    if (staged) "Columns show the initial R_m search and later refinements at their stated exposures and realization counts." else
      "Each column shows one requested R_m search path.",
    "Grey segments connect candidates in that round's window;",
    "teal diamonds mark centers unless also round-best; orange points mark the best candidate for that column's criterion.",
    "Black stars and facet titles mark the best in the last displayed window.",
    "Numeric labels show that criterion's error the first time an R_m appears in each column."
  ), width = if (staged) 115 else if (n_panels == 1) 95 else 165)
  p <- ggplot() +
    geom_segment(data = data$segments,
      aes(x = .data$x_low, xend = .data$x_high, y = .data$iteration, yend = .data$iteration),
      color = "#737373", linewidth = 0.6, lineend = "round") +
    geom_point(data = filter(data$points, !.data$is_center),
      aes(x = .data$disease_R0, y = .data$iteration), color = "#666666", fill = "white",
      shape = 21, size = 2.0, stroke = 0.7) +
    geom_point(data = data$centers, aes(x = .data$disease_R0, y = .data$iteration),
      color = "#2f8990", shape = 18, size = 2.8) +
    geom_point(data = data$best, aes(x = .data$disease_R0, y = .data$iteration),
      color = "#e36c0a", size = 2.1) +
    geom_text(data = data$final, aes(x = .data$disease_R0, y = .data$iteration),
      label = "\u2606", color = "black", size = 3.6, vjust = 0.50, hjust = 0.50) +
    ggrepel::geom_text_repel(data = data$labels,
      aes(x = .data$disease_R0, y = .data$iteration, label = .data$score_label),
      color = "#4d4d4d", size = 3.6, nudge_y = 0.25, direction = "both",
      box.padding = 0.12, point.padding = 0.20, min.segment.length = Inf,
      max.overlaps = Inf, seed = 20251004) +
    facet_wrap(vars(.data$facet_label), nrow = 1, scales = "free_x",
      labeller = if (staged) label_value else as_labeller(rm_plot_parse_strings, default = label_parsed)) +
    scale_y_reverse(breaks = sort(unique(trace$iteration)), expand = expansion(add = c(0.80, 0.45))) +
    scale_x_continuous(expand = expansion(mult = 0.16)) +
    labs(x = "Candidate R_m", y = "Search round",
         title = paste0(state_plot_label(state), " adaptive R_m search windows"), caption = caption_text) +
    theme_minimal(base_size = 14) +
    theme(panel.grid.major = element_line(color = "#ececec", linewidth = 0.18),
          panel.grid.minor = element_blank(), panel.grid.minor.x = element_line(color = "#f2f2f2", linewidth = 0.18),
          plot.title = element_text(face = "bold", size = 22), strip.text = element_text(face = "bold", size = 14),
          axis.title = element_text(size = 18), axis.text = element_text(size = 13),
          plot.caption = element_text(size = 13, hjust = 0, lineheight = 1.05),
          panel.spacing.x = unit(1.5, "lines"),
          plot.caption.position = "panel", plot.margin = margin(10, 26, 8, 26))
  path <- file.path(plot_dir, paste0(state, "_Rm_search_windows.png"))
  p <- rm_plot_labels(p)
  ggsave(path, p, width = max(8.8, (if (staged) 6 else 4.125) * n_panels), height = 7.5, dpi = 300)
  procedure <- state_result$procedure
  procedure_file <- file.path(sweep_root, "staged", state, "procedure.csv")
  if (is.null(procedure) && fit_initial_exposed && file.exists(procedure_file)) {
    procedure <- readr::read_csv(procedure_file, show_col_types = FALSE)
  }
  if (!is.null(procedure) && nrow(procedure)) {
    path <- file.path(plot_dir, paste0(state, "_Rm_E0_procedure.png"))
    plot_staged_procedure(procedure, state, path)
  }
  path
}

summarise_r0_burden_from_trace <- function(trace_tbl) {
  if (nrow(trace_tbl) == 0) return(tibble())

  candidates <- trace_tbl %>%
    mutate(geo_region = normalize_state_dir(.data$geo_region)) %>%
    filter(.data$geo_region %in% states, .data$scenario_label == scenario_label) %>%
    distinct(.data$geo_region, .data$scenario_label, .data$disease_R0) %>%
    arrange(.data$geo_region, .data$disease_R0)
  if (nrow(candidates) == 0) return(tibble())

  burden_samples <- purrr::pmap_dfr(candidates, function(geo_region, scenario_label, disease_R0) {
    metadata_file <- complete_metadata_for_candidate(geo_region, disease_R0)
    if (is.na(metadata_file)) {
      warning(
        "Skipping burden summary for ",
        geo_region,
        " R0=",
        r0_key(disease_R0),
        ": no complete simulator metadata found."
      )
      return(tibble())
    }
    read_candidate_burden_samples(metadata_file)
  })
  if (nrow(burden_samples) == 0) return(tibble())

  summarise_burden_samples(burden_samples)
}

complete_candidate_metadata_table <- function(selected_states = states) {
  expected_ids <- seq.int(realization_range[[1]], realization_range[[2]])
  metadata_files <- list.files(
    sim_output_dir,
    pattern = "^metadata_batch-.*\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  if (length(metadata_files) == 0) return(tibble())

  purrr::map_dfr(metadata_files, function(metadata_file) {
    metadata <- tryCatch(jsonlite::fromJSON(metadata_file, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(metadata)) return(tibble())
    if (fit_initial_exposed && !metadata_matches_candidate(metadata_file, metadata_state(metadata),
        metadata_candidate_r0(metadata))) return(tibble())

    batch_num <- as.character(metadata$batch_num %||% "")
    timing_file <- file.path(dirname(metadata_file), paste0("simulation_times_batch-", batch_num, ".csv"))
    sim_ids <- if (file.exists(timing_file)) {
      sort(unique(as.integer(read_sweep_table(timing_file, show_col_types = FALSE)$sim_id)))
    } else {
      integer()
    }

    tibble(
      geo_region = normalize_state_dir(metadata_state(metadata)),
      scenario_label = metadata$metadata_tags$scenario_label %||% scenario_label,
      disease_R0 = metadata_candidate_r0(metadata),
      sim_day_0 = metadata_sim_day_0(metadata),
      simulation_days = as.integer(metadata$cli_args$days %||% NA_integer_),
      metadata_file = metadata_file,
      complete = identical(sim_ids, expected_ids)
    )
  }) %>%
    filter(
      .data$complete,
      .data$geo_region %in% selected_states,
      .data$scenario_label == scenario_label,
      .data$sim_day_0 == sim_day_0,
      .data$simulation_days == simulation_days,
      is.finite(.data$disease_R0)
    ) %>%
    arrange(.data$geo_region, .data$disease_R0, .data$metadata_file) %>%
    group_by(.data$geo_region, .data$disease_R0) %>%
    slice(1) %>%
    ungroup()
}

summarise_burden_samples <- function(burden_samples) {
  if (nrow(burden_samples) == 0) return(tibble())

  population_lookup <- burden_samples %>%
    distinct(.data$geo_region) %>%
    mutate(state_population = vapply(.data$geo_region, state_population_for_state, numeric(1)))

  burden_samples %>%
    left_join(population_lookup, by = "geo_region") %>%
    group_by(.data$geo_region, .data$scenario_label, .data$disease_R0, .data$outcome, .data$state_population) %>%
    summarise(
      sample_count = dplyr::n(),
      mean_burden = mean(.data$burden, na.rm = TRUE),
      median_burden = median(.data$burden, na.rm = TRUE),
      q025_burden = as.numeric(stats::quantile(.data$burden, 0.025, na.rm = TRUE, names = FALSE)),
      q975_burden = as.numeric(stats::quantile(.data$burden, 0.975, na.rm = TRUE, names = FALSE)),
      .groups = "drop"
    ) %>%
    mutate(median_burden_per_100k = 1e5 * .data$median_burden / .data$state_population) %>%
    arrange(.data$geo_region, .data$outcome, .data$disease_R0)
}

summarise_r0_burden_from_complete_metadata <- function(selected_states = states) {
  candidates <- complete_candidate_metadata_table(selected_states)
  if (nrow(candidates) == 0) return(tibble())

  burden_samples <- purrr::map_dfr(candidates$metadata_file, read_candidate_burden_samples)
  summarise_burden_samples(burden_samples)
}

summarise_wis_from_complete_metadata <- function(selected_states = states) {
  candidates <- complete_candidate_metadata_table(selected_states)
  if (nrow(candidates) == 0) return(tibble())

  purrr::map_dfr(candidates$metadata_file, function(metadata_file) {
    tryCatch({
      samples <- read_candidate_weekly_samples(metadata_file)
      if (nrow(samples) == 0) return(tibble())
      predictions <- quantile_predictions(samples)
      observed <- read_observed_state_weekly(metadata_file)
      scores <- score_wis(predictions, observed)
      summarise_candidate(scores)
    }, error = function(e) {
      warning("Skipping WIS summary for ", metadata_file, ": ", conditionMessage(e))
      tibble()
    })
  }) %>%
    arrange(.data$geo_region, .data$mean_wis, .data$search_score, .data$disease_R0)
}

select_wis_minimizing_r0 <- function(wis_summary) {
  if (nrow(wis_summary) == 0) return(tibble())

  wis_summary %>%
    group_by(.data$geo_region) %>%
    arrange(.data$mean_wis, .data$search_score, .data$disease_R0, .by_group = TRUE) %>%
    slice(1) %>%
    ungroup() %>%
    transmute(
      geo_region = .data$geo_region,
      wis_minimizing_R0 = .data$disease_R0,
      mean_wis = .data$mean_wis,
      search_score = .data$search_score
    )
}

write_r0_runtime_outputs <- function() {
  candidates <- complete_candidate_metadata_table(states)
  if (nrow(candidates) == 0) {
    message("No complete R0 candidates were available for the runtime heatmap.")
    return(invisible(NULL))
  }
  runtime_summary <- purrr::map_dfr(seq_len(nrow(candidates)), function(i) {
    candidate <- candidates[i, ]
    metadata <- jsonlite::fromJSON(candidate$metadata_file, simplifyVector = FALSE)
    timing_file <- file.path(dirname(candidate$metadata_file),
                             paste0("simulation_times_batch-", metadata$batch_num, ".csv"))
    timings <- read_sweep_table(timing_file, show_col_types = FALSE) %>%
      filter(.data$sim_id %in% seq.int(realization_range[[1]], realization_range[[2]]))
    if (any(!is.finite(timings$time_seconds) | timings$time_seconds <= 0)) {
      stop("Nonpositive or missing runtime in: ", timing_file)
    }
    # Metadata precedes worker startup; the timing CSV is updated when results
    # are published. This is a retrospective estimate, not a recorded timer.
    started <- as.POSIXct(metadata$created_at_utc %||% NA_character_,
                         format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
    wall_seconds <- as.numeric(difftime(file.info(timing_file)$mtime, started, units = "secs"))
    if (!is.finite(wall_seconds) || wall_seconds <= 0) wall_seconds <- NA_real_
    tibble(
      geo_region = candidate$geo_region,
      scenario_label = candidate$scenario_label,
      disease_R0 = candidate$disease_R0,
      simulation_days = simulation_days,
      sample_count = nrow(timings),
      median_seconds = median(timings$time_seconds),
      mean_seconds = mean(timings$time_seconds),
      min_seconds = min(timings$time_seconds),
      max_seconds = max(timings$time_seconds),
      total_seconds = sum(timings$time_seconds),
      workers = as.integer(metadata$execution$resolved_workers %||% 1L),
      wall_seconds_approx = wall_seconds,
      projected_100_sims_4_workers_seconds = ceiling(100 / 4) * median(timings$time_seconds),
      projected_100_sims_32_workers_seconds = ceiling(100 / 32) * median(timings$time_seconds),
      timing_file = timing_file
    )
  })
  state_axis <- runtime_summary %>%
    distinct(.data$geo_region) %>%
    mutate(county_count = vapply(.data$geo_region, county_count_for_state, integer(1))) %>%
    arrange(.data$county_count, .data$geo_region) %>%
    mutate(y_index = rev(seq_len(dplyr::n())),
           state_label = paste0(state_plot_label(.data$geo_region), " (", .data$county_count, ")"))
  state_totals <- runtime_summary %>%
    group_by(.data$geo_region) %>%
    summarise(candidate_count = dplyr::n(), realization_count = sum(.data$sample_count),
              total_seconds = sum(.data$total_seconds),
              wall_seconds_approx = sum(.data$wall_seconds_approx),
              projected_100_sims_4_workers_seconds = sum(.data$projected_100_sims_4_workers_seconds),
              projected_100_sims_32_workers_seconds = sum(.data$projected_100_sims_32_workers_seconds),
              .groups = "drop") %>%
    mutate(total_minutes = .data$total_seconds / 60,
           total_hours = .data$total_seconds / 3600,
           total_label = sprintf("%dh %02dm %02ds",
                                 as.integer(round(.data$total_seconds) %/% 3600),
                                 as.integer(round(.data$total_seconds) %% 3600 %/% 60),
                                 as.integer(round(.data$total_seconds) %% 60)))
  state_axis <- state_axis %>% left_join(state_totals, by = "geo_region")
  r0_levels <- sort(unique(runtime_summary$disease_R0))
  runtime_summary <- runtime_summary %>%
    left_join(select(state_axis, "geo_region", "county_count"), by = "geo_region") %>%
    mutate(median_minutes = .data$median_seconds / 60,
           median_hours = .data$median_seconds / 3600) %>%
    arrange(.data$county_count, .data$geo_region, .data$disease_R0)
  plot_data <- runtime_summary %>%
    left_join(select(state_axis, "geo_region", "y_index"), by = "geo_region") %>%
    mutate(x_index = match(.data$disease_R0, r0_levels))
  row_bands <- state_axis %>% filter(.data$y_index %% 2 == 0)
  time_breaks <- c(0.5, 1, 5, 15, 60, 300, 1800, 3600, 7200, 14400, 28800, 86400)
  time_labels <- c("0.5 s", "1 s", "5 s", "15 s", "1 min", "5 min",
                   "30 min / 0.5 h", "1 h", "2 h", "4 h", "8 h", "24 h")
  p <- ggplot(plot_data, aes(.data$x_index, .data$y_index, fill = .data$median_seconds)) +
    geom_rect(data = row_bands,
              aes(xmin = 0.5, xmax = length(r0_levels) + 0.5,
                  ymin = .data$y_index - 0.5, ymax = .data$y_index + 0.5),
              inherit.aes = FALSE, fill = "#f4f4f4", color = NA) +
    geom_tile(color = "white", linewidth = 0.18, width = 1, height = 1) +
    scale_fill_gradientn(colors = high_risk_palette, transform = "log10",
                         limits = c(min(runtime_summary$median_seconds),
                                    max(1800, runtime_summary$median_seconds)),
                         breaks = time_breaks, labels = time_labels,
                         name = "Median runtime\n(log scale)") +
    scale_x_continuous(breaks = seq_along(r0_levels), labels = r0_label(r0_levels),
                       expand = expansion(add = 0)) +
    scale_y_continuous(breaks = state_axis$y_index, labels = state_axis$state_label,
                       sec.axis = dup_axis(name = "Total runtime\n(h min s)",
                                           breaks = state_axis$y_index,
                                           labels = state_axis$total_label),
                       expand = expansion(add = 0)) +
    labs(x = "Candidate R_m", y = "State (number of counties)",
         title = "Simulation runtime by state and R_m",
         subtitle = paste0(scenario_plot_label(scenario_label), "; ", simulation_days,
                           " simulated days; median per realization across ",
                           realization_range[[2]] - realization_range[[1]] + 1, " realizations"),
         caption = paste0("Row totals sum elapsed runtimes across all displayed R_m candidates and realizations.\n",
                          "States ordered by county count. Blank tiles indicate untested candidates.")) +
    guides(fill = guide_colourbar(barheight = 0.5, barwidth = 24)) +
    theme_classic(base_size = 13) +
    theme(plot.title = element_text(face = "bold", size = 18),
          plot.subtitle = element_text(size = 12),
          axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
          axis.text.y = element_text(size = 11, color = "black"),
          axis.text.y.right = element_text(size = 11, margin = margin(l = 12)),
          axis.ticks.y.right = element_blank(), axis.line.y.right = element_blank(),
          legend.position = "bottom")
  summary_file <- sweep_table_path(file.path(sweep_root, "Rm_search_runtime_by_state_r0.csv"))
  out_file <- file.path(plot_dir, "state_runtime_by_r0_heatmap.png")
  figure_file <- file.path(shared_figure_dir, "state_runtime_by_r0_heatmap.png")
  dir.create(dirname(figure_file), recursive = TRUE, showWarnings = FALSE)
  write_csv_preserving_existing(runtime_summary, summary_file)
  write_csv_preserving_existing(state_axis %>% select(-"y_index", -"state_label"),
                   sweep_table_path(file.path(sweep_root, "Rm_search_runtime_totals_by_state.csv")))
  for (path in c(out_file, figure_file)) {
    p <- rm_plot_labels(p)
    ggsave(path, p, width = max(14, 0.26 * length(r0_levels) + 5),
           height = max(7.5, 0.28 * nrow(state_axis) + 3.5),
           units = "in", dpi = 300, bg = "white")
  }
  if (all(is.finite(runtime_summary$wall_seconds_approx))) {
    wall_axis <- state_axis %>% mutate(wall_label = sprintf("%dh %02dm %02ds",
      as.integer(round(.data$wall_seconds_approx) %/% 3600),
      as.integer(round(.data$wall_seconds_approx) %% 3600 %/% 60),
      as.integer(round(.data$wall_seconds_approx) %% 60)))
    wall_plot <- p + aes(fill = .data$wall_seconds_approx) +
      scale_fill_gradientn(colors = high_risk_palette, transform = "log10",
        limits = c(min(runtime_summary$wall_seconds_approx), max(1800, runtime_summary$wall_seconds_approx)),
        breaks = time_breaks, labels = time_labels, name = "Approx. wall time\n(log scale)") +
      scale_y_continuous(breaks = wall_axis$y_index, labels = wall_axis$state_label,
        sec.axis = dup_axis(name = "Total wall time\n(h min s)", breaks = wall_axis$y_index,
                           labels = wall_axis$wall_label), expand = expansion(add = 0)) +
      labs(title = "Approximate wall-clock runtime by state and R_m",
           subtitle = paste0(scenario_plot_label(scenario_label), "; ", simulation_days, " simulated days; ",
             realization_range[[2]] - realization_range[[1]] + 1, " realizations per candidate"),
           caption = paste0("Estimated from metadata creation to final timing-file update; includes worker startup and result writes.\n",
             "Row totals sum completed candidate durations; exclude search scoring, plots and queue waits.\n",
             "Preserved file timestamps are required. Blank tiles have no completed candidate."))
    wall_plot <- rm_plot_labels(wall_plot)
    ggsave(file.path(plot_dir, "state_runtime_by_r0_wall_clock_heatmap.png"), wall_plot,
      width = max(14, 0.26 * length(r0_levels) + 5), height = max(7.5, 0.28 * nrow(state_axis) + 3.5),
      units = "in", dpi = 300, bg = "white")
  }
  message("Wrote runtime summary and heatmap:\n  ", summary_file, "\n  ", out_file)
  invisible(runtime_summary)
}

plot_r0_burden_heatmap <- function(burden_summary, wis_best = tibble()) {
  if (nrow(burden_summary) == 0) return(NA_character_)
  if (!nrow(wis_best)) wis_best <- tibble(geo_region = character(), wis_minimizing_R0 = numeric())

  r0_levels <- sort(unique(burden_summary$disease_R0))
  state_order <- if (nrow(wis_best)) wis_best %>%
    filter(.data$geo_region %in% unique(burden_summary$geo_region)) %>%
    arrange(desc(.data$wis_minimizing_R0), .data$geo_region) %>%
    pull(.data$geo_region) else character()
  state_levels <- c(
    state_order,
    setdiff(sort(unique(burden_summary$geo_region)), state_order)
  )
  state_axis <- tibble(
    geo_region = state_levels,
    geo_region_label = state_plot_label(state_levels),
    y_index = rev(seq_along(state_levels))
  )
  r0_axis <- tibble(
    disease_R0 = r0_levels,
    r0_label = r0_label(r0_levels),
    x_index = seq_along(r0_levels)
  )
  plot_data <- burden_summary %>%
    left_join(state_axis, by = "geo_region") %>%
    left_join(r0_axis, by = "disease_R0") %>%
    mutate(
      outcome_label = dplyr::recode(
        .data$outcome,
        hospitalizations = "Hospitalizations",
        deaths = "Deaths",
        .default = .data$outcome
      ) %>%
        factor(levels = c("Hospitalizations", "Deaths")),
      fill_value = .data$median_burden_per_100k
    )
  row_bands <- state_axis %>%
    mutate(row_index = seq_along(.data$geo_region)) %>%
    filter(.data$row_index %% 2 == 0) %>%
    tidyr::expand_grid(outcome_label = factor(c("Hospitalizations", "Deaths"), levels = c("Hospitalizations", "Deaths")))
  star_data <- wis_best %>%
    filter(.data$geo_region %in% state_levels) %>%
    left_join(state_axis, by = "geo_region") %>%
    left_join(r0_axis, by = c("wis_minimizing_R0" = "disease_R0")) %>%
    tidyr::expand_grid(outcome_label = factor(c("Hospitalizations", "Deaths"), levels = c("Hospitalizations", "Deaths"))) %>%
    transmute(
      x_index = .data$x_index,
      y_index = .data$y_index,
      outcome_label = .data$outcome_label
    ) %>%
    filter(!is.na(.data$x_index), !is.na(.data$y_index))

  p <- ggplot(plot_data, aes(x = .data$x_index, y = .data$y_index, fill = .data$fill_value)) +
    geom_rect(
      data = row_bands,
      aes(
        xmin = 0.5,
        xmax = length(r0_levels) + 0.5,
        ymin = .data$y_index - 0.5,
        ymax = .data$y_index + 0.5
      ),
      inherit.aes = FALSE,
      fill = "#f4f4f4",
      color = NA
    ) +
    geom_tile(color = "white", linewidth = 0.18, width = 1, height = 1) +
    geom_text(
      data = star_data,
      aes(x = .data$x_index, y = .data$y_index),
      inherit.aes = FALSE,
      label = "*",
      color = "black",
      size = 3.6,
      fontface = "bold",
      vjust = 0.52
    ) +
    facet_wrap(vars(.data$outcome_label), ncol = 2) +
    scale_fill_gradientn(
      colors = high_risk_palette,
      name = "Median burden\nper 100K",
      labels = scales::label_number(accuracy = 1, trim = TRUE)
    ) +
    scale_x_continuous(
      breaks = r0_axis$x_index,
      labels = r0_axis$r0_label,
      expand = expansion(add = 0)
    ) +
    scale_y_continuous(
      breaks = state_axis$y_index,
      labels = state_axis$geo_region_label,
      expand = expansion(add = 0)
    ) +
    labs(
      x = "Candidate R_m",
      y = NULL,
      title = "State burden per 100K across R_m candidates",
      subtitle = paste0(
        scenario_plot_label(scenario_label),
        " simulations; tiles show the median across ",
        realization_range[[2]] - realization_range[[1]] + 1,
        " realizations for each completed state/R_m"
      )
    ) +
    guides(fill = guide_colourbar(barheight = 0.5, barwidth = 20)) +
    theme_classic(base_size = 13) +
    theme(
      plot.title = element_text(face = "bold", size = 18),
      plot.subtitle = element_text(size = 12),
      strip.text = element_text(face = "bold", size = 13),
      axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
      axis.text.y = element_text(size = 8),
      legend.position = "bottom"
    )

  out_file <- file.path(plot_dir, "state_burden_by_r0_per100k_heatmap.png")
  figure_file <- file.path(shared_figure_dir, "state_burden_by_r0_per100k_heatmap.png")
  dir.create(dirname(figure_file), recursive = TRUE, showWarnings = FALSE)
  plot_width <- max(11, 0.34 * length(r0_levels) + 5)
  plot_height <- max(7.5, 0.22 * length(state_levels) + 3.5)
  p <- rm_plot_labels(p)
  ggsave(out_file, p, width = plot_width, height = plot_height, bg = "white", units = "in", dpi = 300)
  p <- rm_plot_labels(p)
  ggsave(figure_file, p, width = plot_width, height = plot_height, bg = "white", units = "in", dpi = 300)
  out_file
}

write_r0_burden_outputs <- function(trace_tbl, use_complete_metadata = FALSE) {
  burden_summary <- if (use_complete_metadata) {
    summarise_r0_burden_from_complete_metadata(states)
  } else {
    summarise_r0_burden_from_trace(trace_tbl)
  }
  if (nrow(burden_summary) == 0) {
    message("No R0 burden summary rows were available to plot.")
    return(list(summary_file = NA_character_, heatmap_file = NA_character_))
  }

  summary_file <- sweep_table_path(file.path(sweep_root, "Rm_search_state_burden_by_r0_per100k.csv"))
  with_sweep_file_lock(file.path(sweep_root, "Rm_search_burden_plots"), {
  write_csv_preserving_existing(burden_summary, summary_file)
  burden_summary <- read_sweep_table(summary_file, show_col_types = FALSE)
  wis_summary <- if (use_complete_metadata) {
    summarise_wis_from_complete_metadata(states)
  } else {
    tibble()
  }
  wis_summary_file <- sweep_table_path(file.path(sweep_root, "Rm_search_summary_from_complete_metadata.csv"))
  wis_best_file <- sweep_table_path(file.path(sweep_root, "Rm_search_best_by_state_from_complete_metadata.csv"))
  if (nrow(wis_summary) > 0) write_csv_preserving_existing(wis_summary, wis_summary_file)
  if (file.exists(wis_summary_file)) wis_summary <- read_sweep_table(wis_summary_file, show_col_types = FALSE)
  wis_best <- select_wis_minimizing_r0(wis_summary)
  if (nrow(wis_best) > 0) write_csv_preserving_existing(wis_best, wis_best_file, keys = "geo_region")
  heatmap_file <- plot_r0_burden_heatmap(burden_summary, wis_best)
  message(
    "Wrote R0 burden summary and heat map:\n  ",
    summary_file,
    "\n  ",
    if (nrow(wis_best) > 0) paste0(wis_best_file, "\n  ") else "",
    heatmap_file
  )
  list(summary_file = summary_file, wis_best_file = wis_best_file, heatmap_file = heatmap_file)
  })
}

write_calibrated_json <- function(row) {
  state <- row$geo_region
  source_file <- seed_input_file(state)
  if (!file.exists(source_file)) {
    warning("Skipping calibrated JSON for ", state, ": missing seed input ", source_file)
    return(NA_character_)
  }

  config <- jsonlite::fromJSON(source_file, simplifyVector = FALSE)
  context <- candidate_context(state)
  if (!is.null(context)) {
    config$initial_exposed <- context$rows
    for (manifest in list(context$source_hashes, context$input_hashes)) {
      paths <- vapply(names(manifest), function(path) {
        if (startsWith(path, "pipeline:")) file.path(pipeline_root, substring(path, 10L)) else
          if (grepl("^/", path)) path else file.path(repo_root, path)
      }, character(1))
      if (!identical(unname(tools::md5sum(paths)), unname(unlist(manifest)))) stop("Inputs changed during staged fitting for ", state)
    }
  }
  config$disease_model$parameters$R0 <- formatC(row$disease_R0, format = "f", digits = 5)
  if (is.null(config$metadata_tags)) config$metadata_tags <- list()
  config$metadata_tags$r0_search <- list(
    kind = "all_interventions_state_incident_hosp_feature_search",
    selected_from = sweep_table_path(file.path(sweep_root, "Rm_search_best_by_state.csv")),
    selected_metadata_file = complete_metadata_for_candidate(state, row$disease_R0),
    candidate_R0 = row$disease_R0,
    r0_selection_metric = row$r0_selection_metric %||% r0_selection_metric,
    selection_value = row$selection_value %||% NA_real_,
    scoring_version = R0_SCORING_VERSION,
    search_score = row$search_score,
    mean_wis = row$mean_wis,
    peak_lag_weeks = row$peak_lag_weeks,
    scenario_label = row$scenario_label,
    realization_range = realization_range,
    simulation_days = simulation_days,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
  config$metadata_tags$epydemix_fit <- list(
    method = "full_simulator_all_interventions_state_feature_search",
    note = "This file is written in the Epydemix calibrated JSON layout so Section 6d can consume it after swapping the Section 5b calibrator.",
    R0 = row$disease_R0,
    r0_selection_metric = row$r0_selection_metric %||% r0_selection_metric,
    selection_value = row$selection_value %||% NA_real_,
    fit_target = "validation_state_weekly_incident_hospitalizations",
    simulation_start_date = sim_day_0,
    distance_settings = list(
      scoring_version = R0_SCORING_VERSION,
      search_metrics = r0_search_metrics,
      r0_selection_metric = row$r0_selection_metric %||% r0_selection_metric,
      scenario_label = row$scenario_label,
      realization_range = realization_range,
      simulation_days = simulation_days
    ),
    aggregate_fit_summary = list(
      search_score = row$search_score,
      mean_wis = row$mean_wis,
      median_wis = row$median_wis,
      observed_total = row$observed_total,
      predicted_median_total = row$predicted_median_total,
      total_ratio = row$total_ratio,
      observed_peak_height = row$observed_peak_height,
      predicted_peak_height = row$predicted_peak_height,
      peak_ratio = row$peak_ratio,
      observed_peak_date = as.character(row$observed_peak_date),
      predicted_peak_date = as.character(row$predicted_peak_date),
      peak_lag_weeks = row$peak_lag_weeks
    )
  )
  if (!is.null(context)) {
    config$metadata_tags$epydemix_fit$method <- "full_simulator_staged_r0_exposures"
    config$metadata_tags$epydemix_fit$note <- "Staged R0 and initial-exposure fit in 5c; compatible with Section 6d."
    config$metadata_tags$staged_fit <- list(version = staged_version, run_signature = context$run_signature,
      settings = context$settings, source_hashes = context$source_hashes, input_hashes = context$input_hashes,
      original_initial_exposed = context$original_rows, original_total = context$original_total,
      fitted_total = row$initial_exposed_total, exposure_multiplier = row$exposure_multiplier,
      height_within_tolerance = row$peak_height_within_tolerance, median_peak_week_matches = row$median_peak_week_matches)
  }

  stem <- tools::file_path_sans_ext(basename(source_file))
  out_dir <- file.path(calibrated_output_root, stem)
  out_file <- file.path(out_dir, paste0(stem, "_EPYDEMIX_R0_ONLY.json"))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(config, out_file, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)
  out_file
}

states <- sort_states_by_county_count(normalize_state_dir(states))
message("Adaptive full-simulator R0 search")
message("States: ", paste(states, collapse = ", "))
message("Base R0: ", base_r0, "; initial step: ", initial_step, "; min step: ", min_step)
message("Search criteria: ", paste(r0_search_metrics, collapse = ", "))
message("Final R0 selection metric: ", r0_selection_metric)
message("Sweep output: ", sweep_root)
check_base_inputs(states)

best_by_state_file <- sweep_table_path(file.path(sweep_root, "Rm_search_best_by_state.csv"))
existing_best_by_state <- tibble()
reused_best_by_state <- tibble()
states_to_search <- states
if (reuse_existing && !fit_initial_exposed && file.exists(best_by_state_file)) {
  existing_best_by_state <- read_sweep_table(best_by_state_file, show_col_types = FALSE) %>%
    mutate(geo_region = normalize_state_dir(.data$geo_region))
  for (column in c("r0_selection_metric", "scoring_version", "search_metrics")) {
    if (!column %in% names(existing_best_by_state)) existing_best_by_state[[column]] <- NA_character_
  }
  for (column in c("selection_value", "search_score")) {
    if (!column %in% names(existing_best_by_state)) existing_best_by_state[[column]] <- NA_real_
  }
  # Recovery recomputes requested states from their simulator outputs, rather
  # than trusting potentially partial tables from the interrupted invocation.
  if (recover_existing) {
    existing_best_by_state <- existing_best_by_state %>%
      filter(!.data$geo_region %in% states)
  }
  reused_best_by_state <- existing_best_by_state %>%
    filter(
      .data$geo_region %in% states,
      .data$scenario_label == scenario_label,
      .data$r0_selection_metric == r0_selection_metric,
      .data$scoring_version == R0_SCORING_VERSION,
      .data$search_metrics == paste(r0_search_metrics, collapse = ",")
    ) %>%
    arrange(.data$geo_region, .data$selection_value, .data$mean_wis, .data$search_score, .data$disease_R0) %>%
    group_by(.data$geo_region) %>%
    slice(1) %>%
    ungroup()
  if (nrow(reused_best_by_state)) {
    reusable <- purrr::map2_lgl(reused_best_by_state$geo_region, reused_best_by_state$disease_R0,
      ~ !is.na(complete_metadata_for_candidate(.x, .y)))
    reused_best_by_state <- reused_best_by_state[reusable, ]
  }
  if (nrow(reused_best_by_state) > 0) {
    states_to_search <- setdiff(states, reused_best_by_state$geo_region)
    message(
      "Reusing existing best R0 rows for: ",
      paste(reused_best_by_state$geo_region, collapse = ", ")
    )
  }
}

if (!run_sims && !recover_existing) {
  if (refresh_runtime_heatmap) {
    write_r0_runtime_outputs()
    if (!(refresh_search_window_plots || refresh_diagnostic_plots || refresh_burden_heatmap)) {
      quit(save = "no", status = 0)
    }
  }
  if (refresh_search_window_plots || refresh_diagnostic_plots || refresh_burden_heatmap) {
    trace_file <- sweep_table_path(file.path(sweep_root, "Rm_search_search_trace.csv"))
    if (!file.exists(trace_file)) {
      stop("Cannot refresh WIS outputs because trace file is missing: ", trace_file)
    }
    existing_trace <- read_sweep_table(trace_file, show_col_types = FALSE) %>%
      mutate(geo_region = normalize_state_dir(.data$geo_region)) %>%
      filter(.data$geo_region %in% states, .data$scenario_label == scenario_label)
    if (nrow(existing_trace) == 0) {
      stop("No matching trace rows found for requested states/scenario in: ", trace_file)
    }

    best_lookup <- if ((refresh_search_window_plots || refresh_diagnostic_plots) && file.exists(best_by_state_file)) {
      best_lookup_raw <- read_sweep_table(best_by_state_file, show_col_types = FALSE) %>%
        mutate(geo_region = normalize_state_dir(.data$geo_region)) %>%
        filter(.data$geo_region %in% states, .data$scenario_label == scenario_label)
      if (!"r0_selection_metric" %in% names(best_lookup_raw)) {
        stop("Saved best table has no selection metric; use --recover-existing=true to rebuild it.")
      }
      best_lookup_raw %>%
        filter(.data$r0_selection_metric == r0_selection_metric)
    } else {
      tibble()
    }
    score_lookup <- if (refresh_diagnostic_plots && file.exists(sweep_table_path(file.path(sweep_root, "Rm_search_scores_by_week.csv")))) {
      read_sweep_table(sweep_table_path(file.path(sweep_root, "Rm_search_scores_by_week.csv")), show_col_types = FALSE) %>%
        mutate(geo_region = normalize_state_dir(.data$geo_region)) %>%
        filter(.data$geo_region %in% states, .data$scenario_label == scenario_label)
    } else {
      tibble()
    }

    if (refresh_search_window_plots || refresh_diagnostic_plots) {
      plot_files <- existing_trace %>%
        group_by(.data$geo_region) %>%
        group_split() %>%
        purrr::map(function(state_trace) {
          state_name <- state_trace$geo_region[[1]]
          best <- best_lookup %>%
            filter(.data$geo_region == state_name) %>%
            arrange(.data$selection_value, .data$mean_wis, .data$search_score, .data$disease_R0) %>%
            slice(1)
          if (nrow(best) == 0) {
            best <- select_best_r0(state_trace, r0_selection_metric) %>%
              mutate(r0_selection_metric = r0_selection_metric)
          }
          state_scores <- score_lookup %>%
            filter(.data$geo_region == state_name)
          final_scores <- state_scores %>%
            filter(abs(.data$disease_R0 - best$disease_R0[[1]]) < 1e-8)
          state_result <- list(
            best = best,
            trace = state_trace,
            scores = state_scores,
            final_scores = final_scores,
            final_observed = final_scores %>% select("date", "observed") %>% distinct()
          )
          if (refresh_diagnostic_plots) {
            c(
              final_fit_plot = plot_final_fit_from_scores(state_result),
              featured_candidate_plot = plot_featured_candidate_fit(state_result),
              wis_loss_landscape_plot = plot_wis_loss_landscape(state_result),
              wis_convergence_plot = plot_wis_convergence(state_result),
              wis_search_windows_plot = plot_wis_search_windows(state_result)
            )
          } else {
            c(wis_search_windows_plot = plot_wis_search_windows(state_result))
          }
        }) %>%
        unlist(use.names = FALSE)
      message(
        "Refreshed WIS diagnostic plots from existing saved outputs:\n  ",
        paste(plot_files, collapse = "\n  ")
      )
    }
    if (refresh_burden_heatmap) {
      write_r0_burden_outputs(
        existing_trace,
        use_complete_metadata = refresh_burden_from_complete_metadata
      )
    }
    quit(save = "no", status = 0)
  }

  dry_candidates <- tidyr::expand_grid(
    geo_region = states_to_search,
    disease_R0 = sort(unique(c(clip_r0(base_r0), clip_r0(base_r0 - initial_step), clip_r0(base_r0 + initial_step))))
  ) %>%
    mutate(input_file = purrr::map2_chr(.data$geo_region, .data$disease_R0, write_candidate_input))
  write_csv_preserving_existing(dry_candidates, sweep_table_path(file.path(sweep_root, "Rm_search_candidate_runs.csv")))
  message("Dry run complete. Candidate inputs were written to: ", candidate_input_dir)
  quit(save = "no", status = 0)
}

if (length(states_to_search) > 0) {
  state_results <- list()
  for (state in states_to_search) {
    state_result <- if (fit_initial_exposed) search_state_staged(state) else search_state(state)
    state_results[[state]] <- state_result
    # Save each finished state before plotting or starting the next state.
    # A later error must not discard hours of completed calibration work.
    write_csv_preserving_existing(state_result$trace, sweep_table_path(file.path(sweep_root, "Rm_search_search_trace.csv")))
    write_csv_preserving_existing(state_result$scores, sweep_table_path(file.path(sweep_root, "Rm_search_scores_by_week.csv")))
    write_csv_preserving_existing(state_result$predictions, sweep_table_path(file.path(sweep_root, "Rm_search_quantile_predictions.csv")))
    write_csv_preserving_existing(state_result$best, best_by_state_file,
      keys = c("geo_region", "scenario_label", "r0_selection_metric"))
    if (write_calibrated_jsons) write_calibrated_json(state_result$best)
    immediate_plots <- c(
      final_fit_plot = plot_final_fit(state_result),
      featured_candidate_plot = plot_featured_candidate_fit(state_result),
      wis_loss_landscape_plot = plot_wis_loss_landscape(state_result),
      wis_convergence_plot = plot_wis_convergence(state_result),
      wis_search_windows_plot = plot_wis_search_windows(state_result)
    )
    message(
      "Wrote immediate R0 diagnostic plots for ",
      state,
      ":\n  ",
      paste(immediate_plots, collapse = "\n  ")
    )
  }
} else {
  state_results <- list()
  message("All requested states had reusable best R0 rows; no new simulations are needed.")
}

search_trace <- purrr::map_dfr(state_results, "trace")
scores_by_week <- purrr::map_dfr(state_results, "scores")
quantile_predictions_out <- purrr::map_dfr(state_results, "predictions")
summary_scores <- if (nrow(search_trace) > 0) {
  search_trace %>%
    arrange(.data$geo_region, .data$disease_R0, .data$search_score) %>%
    group_by(.data$geo_region, .data$disease_R0) %>%
    slice(1) %>%
    ungroup() %>%
    arrange(.data$geo_region, .data$search_score, .data$disease_R0)
} else {
  tibble()
}
new_best_by_state <- purrr::map_dfr(state_results, "best")
if (nrow(new_best_by_state) > 0) {
  new_best_by_state <- new_best_by_state %>%
    arrange(.data$geo_region)
}

if (nrow(new_best_by_state) > 0) {
  plot_files <- purrr::map_chr(state_results, plot_final_fit)
  featured_candidate_summaries <- purrr::map_dfr(state_results, featured_candidate_rows)
  featured_plot_files <- purrr::map_chr(state_results, plot_featured_candidate_fit)
  loss_landscape_plot_files <- purrr::map_chr(state_results, plot_wis_loss_landscape)
  convergence_plot_files <- purrr::map_chr(state_results, plot_wis_convergence)
  search_windows_plot_files <- purrr::map_chr(state_results, plot_wis_search_windows)

  new_best_by_state <- new_best_by_state %>%
    mutate(
      final_fit_plot = plot_files[.data$geo_region],
      featured_candidate_plot = featured_plot_files[.data$geo_region],
      wis_loss_landscape_plot = loss_landscape_plot_files[.data$geo_region],
      wis_convergence_plot = convergence_plot_files[.data$geo_region],
      wis_search_windows_plot = search_windows_plot_files[.data$geo_region]
    )
} else {
  featured_candidate_summaries <- tibble()
}

best_by_state <- bind_rows(
  existing_best_by_state,
  reused_best_by_state,
  new_best_by_state
) %>%
  filter(.data$r0_selection_metric == r0_selection_metric,
         .data$geo_region %in% states, .data$scenario_label == scenario_label,
         .data$scoring_version == R0_SCORING_VERSION,
         .data$search_metrics == paste(r0_search_metrics, collapse = ",")) %>%
  arrange(.data$geo_region, .data$selection_value, .data$mean_wis, .data$search_score, .data$disease_R0) %>%
  group_by(.data$geo_region) %>%
  slice(1) %>%
  ungroup() %>%
  arrange(.data$geo_region)

write_csv_preserving_existing(search_trace, sweep_table_path(file.path(sweep_root, "Rm_search_search_trace.csv")))
write_csv_preserving_existing(quantile_predictions_out, sweep_table_path(file.path(sweep_root, "Rm_search_quantile_predictions.csv")))
write_csv_preserving_existing(scores_by_week, sweep_table_path(file.path(sweep_root, "Rm_search_scores_by_week.csv")))
write_csv_preserving_existing(summary_scores, sweep_table_path(file.path(sweep_root, "Rm_search_summary.csv")))
write_csv_preserving_existing(best_by_state, sweep_table_path(file.path(sweep_root, "Rm_search_best_by_state.csv")),
  keys = c("geo_region", "scenario_label", "r0_selection_metric"))
write_csv_preserving_existing(featured_candidate_summaries, sweep_table_path(file.path(sweep_root, "Rm_search_featured_candidate_comparison.csv")))

burden_trace_file <- sweep_table_path(file.path(sweep_root, "Rm_search_search_trace.csv"))
burden_trace <- if (file.exists(burden_trace_file)) {
  read_sweep_table(burden_trace_file, show_col_types = FALSE) %>%
    mutate(geo_region = normalize_state_dir(.data$geo_region)) %>%
    filter(.data$geo_region %in% states, .data$scenario_label == scenario_label)
} else {
  search_trace
}
if (defer_sweep_tables) {
  burden_summary <- summarise_r0_burden_from_trace(burden_trace)
  write_csv_preserving_existing(burden_summary,
    sweep_table_path(file.path(sweep_root, "Rm_search_state_burden_by_r0_per100k.csv")))
} else write_r0_burden_outputs(burden_trace)

if (write_calibrated_jsons) {
  calibrated_files <- purrr::pmap_chr(best_by_state, function(...) {
    write_calibrated_json(tibble::as_tibble(list(...)))
  })
  calibrated_manifest <- best_by_state %>%
    mutate(calibrated_json_file = calibrated_files)
  write_csv_preserving_existing(calibrated_manifest, sweep_table_path(file.path(sweep_root, "Rm_search_calibrated_json_manifest.csv")),
    keys = c("geo_region", "scenario_label", "r0_selection_metric"))
  message("Wrote calibrated JSON manifest: ", sweep_table_path(file.path(sweep_root, "Rm_search_calibrated_json_manifest.csv")))
}

message("Wrote search trace: ", sweep_table_path(file.path(sweep_root, "Rm_search_search_trace.csv")))
message("Wrote WIS scores: ", sweep_table_path(file.path(sweep_root, "Rm_search_scores_by_week.csv")))
message("Wrote best R0 by state: ", sweep_table_path(file.path(sweep_root, "Rm_search_best_by_state.csv")))
message("Wrote featured candidate comparison: ", sweep_table_path(file.path(sweep_root, "Rm_search_featured_candidate_comparison.csv")))
message("Wrote final fit plots under: ", plot_dir)
if (defer_sweep_tables) {
  settings <- list(sim_day_0 = sim_day_0, scenario = scenario_label,
    simulation_days = as.integer(simulation_days), realization_range = as.integer(realization_range),
    selection_metric = r0_selection_metric, search_metrics = r0_search_metrics,
    scoring_version = R0_SCORING_VERSION)
  if (fit_initial_exposed) {
    settings$fit_method <- "staged_simulator"
    settings$staged_version <- staged_version
    settings$run_signature <- candidate_context(states[[1]])$run_signature
  }
  path <- file.path(sweep_root, "checkpoints", paste0(states[[1]], "_Rm_search_settings.rds"))
  temporary <- tempfile(tmpdir = dirname(path))
  saveRDS(settings, temporary)
  if (!file.rename(temporary, path)) stop("Could not publish completed fit settings: ", path)
  message("Saved state checkpoints; combined sweep CSVs will be created in the scenarios phase.")
}
print(best_by_state)
