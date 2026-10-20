# Run from the repository root: Rscript --vanilla test/test_pipeline_phases.R
# Exercises actual orchestration branches with external work replaced by spies.
repo <- normalizePath(".")
temporary <- tempfile("pipeline-phases-")
dir.create(temporary)
helpers <- file.path(repo, "scripts", "0_pipeline_helpers.R")
main <- file.path(repo, "scripts", "0_run_full_pipeline_US.R")
templates <- file.path(repo, "data", "INPUT_FILE_TEMPLATES")
expect_error <- function(expr) stopifnot(inherits(tryCatch(force(expr), error = identity), "error"))
setup <- function(config, args = character()) {
  env <- new.env(parent = globalenv())
  sys.source(helpers, env)
  env$initialize_pipeline_inputs(config, args, repo, envir = env)
  env
}
phases <- c("1_RUN_FIT.R" = "fit", "2_RUN_SCENARIOS.R" = "scenarios", "3_RUN_FIGURES.R" = "results")
for (name in names(phases)) {
  env <- setup(file.path(templates, name))
  stopifnot(env$PIPELINE_PHASE == phases[[name]], env$EXECUTION_TARGET == "ls6",
    length(env$SELECTED_RUN_STATES) == 0L, env$REUSE_BEST_FIT_SIMULATIONS,
    identical(env$SIM_REALIZATION_RANGE, c(0L, 99L)),
    identical(env$SIM_REALIZATION_RANGE, env$R0_SEARCH_REALIZATION_RANGE),
    env$R0_WORKERS == "32", !env$DEPLOY_SHINYAPPS,
    env$R0_FIT_LAUNCH == if (name == "1_RUN_FIT.R") "pylauncher" else "direct")
}
local <- setup(file.path(templates, "RUN_FULL_PIPELINE_INPUTS.R"))
stopifnot(local$PIPELINE_PHASE == "all", local$EXECUTION_TARGET == "local",
  length(local$SELECTED_RUN_STATES) > 0L)
override <- setup(file.path(templates, "1_RUN_FIT.R"), c("--execution-target=local", "--workers=2"))
stopifnot(override$R0_FIT_LAUNCH == "direct", override$R0_WORKERS == "2")
expect_error(setup(file.path(templates, "1_RUN_FIT.R"), "--pipeline-phase=unknown"))
expect_error(setup(file.path(templates, "1_RUN_FIT.R"), "--execution-target=unknown"))

# Relative shared-file paths must work outside the repository and retain NULLs.
for (name in c("LS6_PIPELINE_INPUTS.R", names(phases))) {
  file.copy(file.path(templates, name), temporary)
}
copied <- setup(file.path(temporary, "2_RUN_SCENARIOS.R"), "--simulation-days=150")
stopifnot(copied$SIMULATION_DAYS == 150L, length(copied$SELECTED_RUN_STATES) == 0L)
writeLines(c('pipeline_shared_inputs <- "cycle.R"', 'pipeline_inputs <- list(pipeline_phase = "fit")'),
  file.path(temporary, "cycle.R"))
expect_error(setup(file.path(temporary, "cycle.R")))

run_phase <- function(name, target = "ls6", fail_fits = FALSE, fail_outputs = FALSE) {
  original_wd <- getwd()
  on.exit(setwd(original_wd), add = TRUE)
  events <- character()
  record <- function(value) events <<- c(events, value)
  env <- new.env(parent = globalenv())
  env$commandArgs <- function(trailingOnly = FALSE) if (trailingOnly) {
    c(paste0("--config=", file.path(templates, name)), paste0("--execution-target=", target),
      if (target == "local") "--selected-states=Delaware")
  } else paste0("--file=", main)
  env$list.files <- function(path, pattern = NULL, ...) {
    if (!is.null(pattern) && (grepl("contact_matrix", pattern, fixed = TRUE) ||
        grepl("high-risk-ratios", pattern, fixed = TRUE))) return(rep("cached", 51))
    base::list.files(path, pattern = pattern, ...)
  }
  env$source <- function(file, local = FALSE, ...) {
    if (basename(file) == "0_pipeline_helpers.R") {
      sys.source(helpers, env)
      env$load_pipeline_packages <- function() invisible(NULL)
      env$initialize_pipeline_runtime <- function() {
        env$pipeline_output_root <- temporary
        env$stdout_log_con <- file(tempfile(tmpdir = temporary), "w")
      }
      env$log_pipeline_settings <- function() invisible(NULL)
      env$section_banner <- function(...) invisible(NULL)
      env$run_logged_command <- function(command, args, ...) {
        record(paste0("command:", command)); 0L
      }
      env$prepare_pipeline_seeds <- function() record("seeds")
      env$run_pipeline_fits <- function() {
        record("fit"); invisible(env$R0_FIT_LAUNCH != "pylauncher")
      }
      env$prepare_reused_fit_outputs <- function() record("reuse")
      env$aggregate_rm_sweep_checkpoints <- function() record("aggregate")
      env$require_completed_pipeline_fits <- function() {
        record("check-fits")
        if (fail_fits) stop("Incomplete fits")
      }
      env$require_completed_scenario_outputs <- function() {
        record("check-outputs")
        if (fail_outputs) stop("Incomplete outputs")
      }
    } else record(basename(file))
    invisible(NULL)
  }
  error <- tryCatch({eval(parse(main), env); NULL}, error = identity)
  list(events = events, error = error)
}
fit <- run_phase("1_RUN_FIT.R")
stopifnot(is.null(fit$error), all(c("seeds", "fit") %in% fit$events),
  !any(c("6e_create_parallel_commands.R", "7a_process_output_to_db.R") %in% fit$events))
scenarios <- run_phase("2_RUN_SCENARIOS.R")
stopifnot(is.null(scenarios$error),
  all(c("check-fits", "aggregate", "6d_create_intervention_inputs.R", "6e_create_parallel_commands.R") %in% scenarios$events),
  !any(c("fit", "seeds", "command:poetry", "1_county_age_pop_totals.R",
    "6f_run_selected_scenarios.R", "7a_process_output_to_db.R") %in% scenarios$events))
results <- run_phase("3_RUN_FIGURES.R")
stopifnot(is.null(results$error),
  all(c("check-fits", "check-outputs", "7a_process_output_to_db.R", "8_prepare_shinyapps_bundle.R") %in% results$events),
  !any(c("fit", "seeds", "aggregate", "command:poetry", "6d_create_intervention_inputs.R",
    "6e_create_parallel_commands.R", "6f_run_selected_scenarios.R") %in% results$events))
blocked <- run_phase("2_RUN_SCENARIOS.R", fail_fits = TRUE)
stopifnot(inherits(blocked$error, "error"), !"6d_create_intervention_inputs.R" %in% blocked$events)
blocked <- run_phase("3_RUN_FIGURES.R", fail_outputs = TRUE)
stopifnot(inherits(blocked$error, "error"), !"7a_process_output_to_db.R" %in% blocked$events)
local_fit <- run_phase("1_RUN_FIT.R", "local")
local_scenarios <- run_phase("2_RUN_SCENARIOS.R", "local")
stopifnot(is.null(local_fit$error), is.null(local_scenarios$error),
  "fit" %in% local_fit$events, "6f_run_selected_scenarios.R" %in% local_scenarios$events)
local_all <- run_phase("RUN_FULL_PIPELINE_INPUTS.R", "local")
stopifnot(is.null(local_all$error), all(c("seeds", "fit", "6e_create_parallel_commands.R",
  "6f_run_selected_scenarios.R", "7a_process_output_to_db.R", "8_prepare_shinyapps_bundle.R") %in% local_all$events))
unlink(temporary, recursive = TRUE)
cat("Shared LS6 inputs, CLI overrides, phase boundaries, local execution and prerequisite stops passed.\n")
