# Run from the repository root: Rscript --vanilla test/test_pipeline_inputs.R
# Checks configuration and batch preparation without downloads or simulations.
suppressPackageStartupMessages({library(dplyr); library(tibble)})
repo <- normalizePath(".")
temporary <- tempfile("pipeline-inputs-")
dir.create(temporary)
write_config <- function(values, name = "experiment inputs.R") {
  path <- file.path(temporary, name)
  writeLines(c("pipeline_inputs <-", capture.output(dput(values))), path)
  path
}
setup <- function(file = NULL, args = character()) {
  env <- new.env(parent = globalenv())
  sys.source("scripts/0_pipeline_helpers.R", envir = env)
  env$initialize_pipeline_inputs(file, args, repo, envir = env)
  env
}
expect_error <- function(expr) stopifnot(inherits(tryCatch(force(expr), error = identity), "error"))

defaults <- setup()
stopifnot(defaults$R0_SELECTION_METRIC == "peak_height",
          setequal(defaults$R0_SEARCH_METRICS, c("total", "peak_height", "peak_timing", "wis")),
          identical(defaults$R0_SEARCH_REALIZATION_RANGE, c(0L, 9L)),
          defaults$R0_FIT_LAUNCH == "direct", defaults$MOBILITY_YR == 2025L,
          all(file.exists(c(defaults$NONE_TEMPLATE_FILE, defaults$INTERVENTION_TEMPLATE_FILES))))

config <- write_config(list(output_dir = file.path(temporary, "results"),
  sim_day_0 = c("2025-09-27", "2025-10-04"), selected_states = "New Jersey",
  r0_realization_range = c(0L, 99L), workers = 32L, r0_fit_launch = "pylauncher",
  r0_fit_scenario = "VACCINE"))
inputs <- setup(config)
stopifnot(inputs$R0_WORKERS == "32", inputs$SELECTED_RUN_STATES == "New-Jersey",
          length(inputs$SIM_DAY_0_VALUES) == 2L,
          identical(inputs$R0_SEARCH_REALIZATION_RANGE, c(0L, 99L)),
          inputs$R0_FIT_LAUNCH == "pylauncher", !dir.exists(inputs$PIPELINE_OUTPUT_DIR))
override <- setup(config, c("--workers=8", "--r0-fit-launch=direct",
  "--r0-wis-realization-range=0,24", "--run-web-preview=false"))
stopifnot(override$R0_WORKERS == "8", override$R0_FIT_LAUNCH == "direct",
          identical(override$R0_SEARCH_REALIZATION_RANGE, c(0L, 24L)), !override$RUN_WEB_PREVIEW)
canonical <- setup(config, c("--r0-wis-realization-range=0,24", "--r0-realization-range=0,4"))
stopifnot(identical(canonical$R0_SEARCH_REALIZATION_RANGE, c(0L, 4L)))
expect_error(setup(write_config(list(workers_typo = 32L), "unknown.R")))
expect_error(setup(args = "--worker=32"))
expect_error(setup(args = "--workers"))
expect_error(setup(args = "--run-web-preview=perhaps"))
expect_error(setup(write_config(list(selected_states = "Not-A-State"), "bad-state.R")))
expect_error(setup(write_config(list(r0_realization_range = c(9L, 0L)), "bad-range.R")))
expect_error(setup(write_config(list(r0_fit_scenario = "UNKNOWN"), "bad-scenario.R")))
expect_error(setup(write_config(list(reuse_best_fit_simulations = TRUE), "bad-reuse-range.R")))
expect_error(setup(write_config(list(r0_fit_scenario = "VACCINE", r0_fit_method = "epydemix_all"), "bad-method.R")))

# Empty selections use TACC output for ingestion and bundling, without replacing
# the empty local selection with a default list of preview states.
for (selection in list(NULL, character(), "")) {
  tacc <- setup(write_config(list(selected_states = selection), "tacc.R"))
  stopifnot(length(tacc$SELECTED_RUN_STATES) == 0L,
            length(tacc$DASHBOARD_PREVIEW_STATES) == 0L,
            identical(tacc$DASHBOARD_PREVIEW_OUTPUT_SUBDIRS, "TACC_FILES"),
            identical(tacc$VALIDATION_OUTPUT_SOURCE_REGEX, "TACC_FILES"))
}
stopifnot(identical(defaults$DASHBOARD_PREVIEW_STATES, defaults$SELECTED_RUN_STATES),
          identical(defaults$VALIDATION_OUTPUT_SOURCE_REGEX, "WEB_OUTPUTS"))

# Exercise the real bundle selection expressions against mixed local/TACC rows.
bundle_code <- as.list(parse("scripts/8_prepare_shinyapps_bundle.R"))
bundle_text <- vapply(bundle_code, function(expr) paste(deparse(expr), collapse = " "), character(1))
selection_start <- which(startsWith(bundle_text, "metadata_preview <- metadata %>%"))
selection_end <- which(startsWith(bundle_text, "readr::write_csv(metadata_preview")) - 1L
select_bundle <- function(states) {
  env <- new.env(parent = globalenv())
  env$preview_states <- states
  env$preview_scenarios <- "NONE"
  env$preview_output_subdirs <- "TACC_FILES"
  env$source_data <- temporary
  env$metadata_tag_chr <- function(...) "NONE"
  env$metadata <- tibble::tibble(
    geo_region = c("Delaware", "Nevada", "Connecticut"),
    file_path = c("TACC_FILES/Delaware/metadata.json", "TACC_FILES/Nevada/metadata.json",
                  "WEB_OUTPUTS/Connecticut/metadata.json"),
    metadata_tags_json = "{}", scenario_hash = c("de", "nv", "ct"),
    created_at_utc = "2026-10-19 00:00:00")
  for (expr in bundle_code[selection_start:selection_end]) eval(expr, env)
  env$metadata_preview
}
stopifnot(setequal(select_bundle(character())$geo_region, c("Delaware", "Nevada")),
          identical(select_bundle("Nevada")$geo_region, "Nevada"))

# The refactored fit stage queues the same settings, temporarily includes the
# all-interventions input needed for fitting, and never starts a simulator.
inputs$pipeline_output_root <- file.path(temporary, "results")
inputs$SIM_DAY_0_LABEL <- "2025-10-04"
inputs$SELECTED_RUN_SCENARIOS <- "NONE"
seed_dir <- file.path(inputs$pipeline_output_root, "SEED_INPUT_JSONS", inputs$SIM_DAY_0_LABEL)
dir.create(seed_dir, recursive = TRUE)
states <- c("Delaware", "Nevada")
file.create(file.path(seed_dir, paste0("INPUT_SEIHRD-STOCH_", states, "_SEED_NONE.json")))
inputs$county_count_for_state <- function(state) if (state == "Delaware") 3L else 17L
inputs$run_logged_command <- function(...) stop("Preparation must not execute fits")
sources <- character()
inputs$source <- function(file, local = FALSE, ...) {
  stopifnot(isTRUE(local))
  sources <<- c(sources, file)
  if (file == "6d_create_intervention_inputs.R") {
    stopifnot("VACCINE" %in% get("SELECTED_RUN_SCENARIOS", envir = parent.frame()))
  }
}
stopifnot(identical(inputs$run_pipeline_fits(), invisible(FALSE)),
          identical(inputs$SELECTED_RUN_SCENARIOS, "NONE"), length(sources) == 4L)
batch_dir <- file.path(inputs$pipeline_output_root, "Rm_search", inputs$SIM_DAY_0_LABEL)
commands <- readLines(file.path(batch_dir, "fit_state_commands.txt"))
stopifnot(length(commands) == 2L, all(grepl("--realization-range=0,99", commands, fixed = TRUE)),
          all(grepl("--state-output-subdir=false", commands, fixed = TRUE)),
          all(grepl("--defer-sweep-tables=true", commands, fixed = TRUE)),
          all(grepl("--scenario=VACCINE", commands, fixed = TRUE)),
          all(grepl("--r0-selection-metric=peak_height", commands, fixed = TRUE)),
          all(startsWith(commands, "Rscript ")),
          dir.exists(file.path(batch_dir, "logs")),
          all(grepl(" > logs/[^/]+_fit\\.log 2>&1$", commands)),
          !any(grepl("OMP_NUM_THREADS|SIMULATOR_CPUS_PER_TASK|cd ", commands)),
          !any(grepl(paste0("=", repo), commands, fixed = TRUE)),
          !dir.exists(file.path(batch_dir, "Delaware")),
          identical(readLines(file.path(batch_dir, "fit_state_pylauncher.py")),
            gsub("state_commands.txt", "fit_state_commands.txt",
              readLines(file.path(repo, "data", "INPUT_FILE_TEMPLATES", "state_pylauncher.py")), fixed = TRUE)),
          any(grepl("#SBATCH -J fit_state_Rm", readLines(file.path(batch_dir, "fit_state_pylauncher.sh")), fixed = TRUE)),
          any(grepl("python3 fit_state_pylauncher.py", readLines(file.path(batch_dir, "fit_state_pylauncher.sh")), fixed = TRUE)))

# Container commands preserve state arguments and user allocation edits.
container_batch <- file.path(temporary, "container batch")
original_target <- inputs$EXECUTION_TARGET
inputs$EXECUTION_TARGET <- "ls6"
# Merely selecting LS6 must produce container commands without an image setting.
inputs$write_rm_fit_launcher(rev(states), c("scripts/5c_Rm_search.R",
  "--selected-states=Delaware"), container_batch)
automatic_commands <- readLines(file.path(container_batch, "fit_state_commands.txt"))
stopifnot(all(startsWith(automatic_commands, "bash ")),
  all(grepl("ls6_container_exec.sh", automatic_commands, fixed = TRUE)),
  !any(grepl("--image", automatic_commands, fixed = TRUE)),
  grepl("--selected-states=Delaware", automatic_commands[[1]], fixed = TRUE),
  grepl("--selected-states=Nevada", automatic_commands[[2]], fixed = TRUE))
inputs$LS6_CONTAINER_IMAGE <- file.path(temporary, "image with spaces.sif")
inputs$write_rm_fit_launcher(states, c("scripts/5c_Rm_search.R",
  "--selected-states=Delaware", "--realization-range=0,99"), container_batch)
container_commands <- readLines(file.path(container_batch, "fit_state_commands.txt"))
stopifnot(all(startsWith(container_commands, "bash ")),
  all(grepl("ls6_container_exec.sh", container_commands, fixed = TRUE)),
  all(grepl(shQuote(inputs$LS6_CONTAINER_IMAGE), container_commands, fixed = TRUE)),
  all(grepl("--realization-range=0,99", container_commands, fixed = TRUE)))
container_shell <- file.path(container_batch, "fit_state_pylauncher.sh")
write("# User allocation marker", container_shell, append = TRUE)
inputs$write_rm_fit_launcher(states, c("scripts/5c_Rm_search.R",
  "--selected-states=Delaware"), container_batch)
stopifnot(sum(grepl("^module load tacc-apptainer$", readLines(container_shell))) == 1L,
  tail(readLines(container_shell), 1) == "# User allocation marker")
inputs$LS6_CONTAINER_IMAGE <- ""
inputs$EXECUTION_TARGET <- original_target

# Resuming in direct mode must recognize those fits and avoid running them again.
for (state in states) {
  stem <- paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE")
  directory <- file.path(inputs$pipeline_output_root, "epydemix_fit", inputs$SIM_DAY_0_LABEL, stem)
  dir.create(directory, recursive = TRUE)
  fit <- list(metadata_tags = list(sim_day_0 = inputs$SIM_DAY_0_LABEL, epydemix_fit = list(
    method = "full_simulator_all_interventions_state_feature_search",
    simulation_start_date = inputs$SIM_DAY_0_LABEL,
    distance_settings = list(simulation_days = inputs$SIMULATION_DAYS,
      realization_range = inputs$R0_SEARCH_REALIZATION_RANGE,
      scoring_version = inputs$R0_SCORING_VERSION, search_metrics = inputs$R0_SEARCH_METRICS,
      scenario_label = "VACCINE",
      r0_selection_metric = inputs$R0_SELECTION_METRIC))))
  jsonlite::write_json(fit, file.path(directory, paste0(stem, "_EPYDEMIX_R0_ONLY.json")), auto_unbox = TRUE)
}
# Saved calibrated JSONs alone must not remove states from an LS6 job file.
inputs$R0_FIT_LAUNCH <- "pylauncher"
sources <- character()
stopifnot(identical(inputs$run_pipeline_fits(), invisible(FALSE)))
queued <- readLines(file.path(batch_dir, "fit_state_commands.txt"))
stopifnot(length(queued) == 2L,
  grepl("--selected-states=Delaware", queued[[1]], fixed = TRUE),
  grepl("--selected-states=Nevada", queued[[2]], fixed = TRUE))
inputs$R0_FIT_LAUNCH <- "direct"
inputs$source <- function(...) stop("Matching fits must be reused")
stopifnot(isTRUE(inputs$run_pipeline_fits()))

# Reuse only the completed winning candidate, including after an LS6 path moves.
reuse <- setup(write_config(list(output_dir = file.path(temporary, "reuse"),
  selected_states = NULL, r0_fit_scenario = "VACCINE", reuse_best_fit_simulations = TRUE,
  r0_realization_range = c(0L, 99L)), "reuse.R"))
reuse$pipeline_output_root <- reuse$PIPELINE_OUTPUT_DIR
for (state in states) {
  stem <- paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE")
  directory <- file.path(reuse$pipeline_output_root, "epydemix_fit", "2025-10-04", stem)
  dir.create(directory, recursive = TRUE)
  fit$metadata_tags$epydemix_fit$distance_settings$scenario_label <- "VACCINE"
  fit$metadata_tags$r0_search <- list(selected_metadata_file = "/old/LS6/path/metadata.json")
  fit$disease_model <- list(parameters = list(R0 = "2.60000"))
  fit_path <- file.path(directory, paste0(stem, "_EPYDEMIX_R0_ONLY.json"))
  jsonlite::write_json(fit, fit_path, auto_unbox = TRUE)
  stopifnot(!reuse$wis_calibrated_fit_matches(fit_path, "2025-10-04", 200L, c(0L,99L),
    "peak_height", expected_scenario = "ALL_INTERVENTIONS"))
  for (candidate in c(2.6, 2.7)) {
    batch <- file.path(reuse$pipeline_output_root, "Rm_search", "2025-10-04", state,
      "sim_outputs", as.character(candidate), "batch-1")
    dir.create(batch, recursive = TRUE)
    metadata <- list(metadata_tags = list(state_dir = state, scenario_label = "VACCINE",
      sim_day_0 = "2025-10-04"), cli_args = list(days = 200L), batch_num = "1",
      disease_model = list(parameters = list(R0 = candidate)))
    jsonlite::write_json(metadata, file.path(batch, "metadata_batch-1.json"), auto_unbox = TRUE)
    readr::write_csv(data.frame(sim_id = 0:99), file.path(batch, "simulation_times_batch-1.csv"))
  }
}
reuse$prepare_reused_fit_outputs(envir = reuse)
stopifnot(nrow(reuse$REUSED_FIT_OUTPUTS) == 2L,
          all(grepl("/2.6/", reuse$REUSED_FIT_OUTPUTS$metadata_file, fixed = TRUE)),
          file.exists(file.path(reuse$pipeline_output_root, "reused_fit_outputs.csv")))
stopifnot(all(stringr::str_detect(reuse$REUSED_FIT_OUTPUTS$metadata_file,
  stringr::regex(reuse$VALIDATION_OUTPUT_SOURCE_REGEX))))

# Execute the command writer's real exclusion step: other scenarios still run.
command_code <- as.list(parse("scripts/6e_create_parallel_commands.R"))
command_text <- vapply(command_code, function(expr) paste(deparse(expr), collapse = " "), character(1))
exclusion <- which(startsWith(command_text, "reused_fit_outputs <- get0"))
reuse$input_metadata <- tidyr::crossing(state = states, sim_day_0 = "2025-10-04",
  scenario = c("VACCINE", "NONE", "ALL_INTERVENTIONS"))
eval(command_code[[exclusion]], reuse)
eval(command_code[[exclusion + 1L]], reuse)
stopifnot(nrow(reuse$input_metadata) == 4L, !"VACCINE" %in% reuse$input_metadata$scenario)

# Bundle only the selected sweep batch; exclude all other fitting candidates.
bundle_env <- new.env(parent = globalenv())
bundle_env$preview_states <- character()
bundle_env$preview_scenarios <- c("VACCINE", "NONE")
bundle_env$preview_output_subdirs <- "TACC_FILES"
bundle_env$source_data <- reuse$pipeline_output_root
bundle_env$metadata_tag_chr <- function(value, tag) value
bundle_env$metadata <- tibble::tibble(
  geo_region = rep(states, each = 3),
  metadata_tags_json = rep(c("VACCINE", "VACCINE", "NONE"), 2),
  file_path = unlist(lapply(reuse$REUSED_FIT_OUTPUTS$metadata_file, function(path)
    c(path, sub("/2.6/", "/2.7/", path, fixed = TRUE), "TACC_FILES/none/metadata.json"))),
  scenario_hash = paste0("hash", 1:6), created_at_utc = "2026-10-19 00:00:00")
for (expr in bundle_code[selection_start:selection_end]) eval(expr, bundle_env)
stopifnot(nrow(bundle_env$metadata_preview) == 4L,
          !any(grepl("/2.7/", bundle_env$metadata_preview$file_path, fixed = TRUE)))

# An incomplete chosen batch must fail rather than silently dropping its rerun.
stopifnot(reuse$require_completed_pipeline_fits(states = states))
expect_error(reuse$require_completed_pipeline_fits(states = c(states, "Texas")))
reuse$SELECTED_RUN_SCENARIOS <- "VACCINE"
for (i in seq_len(nrow(reuse$REUSED_FIT_OUTPUTS))) {
  folder <- dirname(reuse$REUSED_FIT_OUTPUTS$metadata_file[[i]])
  file.create(file.path(folder, "network_batch-1.csv"), file.path(folder, "node_001_batch-1.csv"))
  input_dir <- file.path(reuse$pipeline_output_root, "TACC_FILES", "2025-10-04")
  dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(list(disease_model = list(parameters = list(R0 = "2.60000"))),
    file.path(input_dir, paste0("INPUT_", reuse$REUSED_FIT_OUTPUTS$state[[i]], "_VACCINE.json")), auto_unbox = TRUE)
}
stopifnot(reuse$require_completed_scenario_outputs(states = states))

# Combined sweep CSVs appear only after all state checkpoints are ready.
checkpoint_dir <- file.path(reuse$pipeline_output_root, "Rm_search", "2025-10-04", "checkpoints")
dir.create(checkpoint_dir, recursive = TRUE)
settings <- list(sim_day_0 = "2025-10-04", scenario = reuse$R0_FIT_SCENARIO,
  simulation_days = reuse$SIMULATION_DAYS, realization_range = reuse$R0_SEARCH_REALIZATION_RANGE,
  selection_metric = reuse$R0_SELECTION_METRIC, search_metrics = reuse$R0_SEARCH_METRICS,
  scoring_version = reuse$R0_SCORING_VERSION)
tables <- c("search_trace", "scores_by_week", "quantile_predictions", "best_by_state",
  "summary", "featured_candidate_comparison", "calibrated_json_manifest")
for (state in states) {
  saveRDS(settings, file.path(checkpoint_dir, paste0(state, "_Rm_search_settings.rds")))
  for (table in tables) saveRDS(data.frame(geo_region = state, disease_R0 = 2.6),
    file.path(checkpoint_dir, paste0(state, "_Rm_search_", table, ".rds")))
}
missing <- file.path(checkpoint_dir, "Nevada_Rm_search_settings.rds")
file.rename(missing, paste0(missing, ".hold"))
expect_error(reuse$aggregate_rm_search_checkpoints(states = states))
sweep_dir <- dirname(checkpoint_dir)
stopifnot(length(list.files(sweep_dir, pattern = "^Rm_search_.*\\.csv$")) == 0L)
file.rename(paste0(missing, ".hold"), missing)
reuse$aggregate_rm_search_checkpoints(states = states)
stopifnot(length(list.files(sweep_dir, pattern = "^Rm_search_.*\\.csv$")) == 7L,
  nrow(readr::read_csv(file.path(sweep_dir, "Rm_search_best_by_state.csv"), show_col_types = FALSE)) == 2L)
timing <- file.path(dirname(reuse$REUSED_FIT_OUTPUTS$metadata_file[[1]]), "simulation_times_batch-1.csv")
readr::write_csv(data.frame(sim_id = 0:9), timing)
expect_error(reuse$require_completed_scenario_outputs(states = states))
expect_error(reuse$prepare_reused_fit_outputs(envir = reuse))
unlink(temporary, recursive = TRUE)
cat("Pipeline file inputs, CLI precedence, validation, PyLauncher preparation and fit reuse passed.\n")
