# No downloads or simulations: verify all-state launchers, staged cache gates,
# exact exposure-aware batch reuse, checkpoints and the 6d handoff.
suppressPackageStartupMessages(library(tidyverse))
repo <- normalizePath(".")
temporary <- tempfile("staged-pipeline-")
dir.create(temporary)
env <- new.env(parent = globalenv())
sys.source("scripts/0_pipeline_helpers.R", env)
config_file <- file.path(temporary, "inputs.R")
writeLines(c('pipeline_shared_inputs <- ',
  encodeString(file.path(repo, "data/INPUT_FILE_TEMPLATES/LS6_PIPELINE_INPUTS.R"), quote='"'),
  'pipeline_inputs <- list(output_dir = ', encodeString(temporary, quote='"'),
  ', selected_scenarios = "NONE")'), config_file)
env$initialize_pipeline_inputs(config_file, character(), repo, envir=env)
env$pipeline_output_root <- temporary
env$SIM_DAY_0_LABEL <- "2025-10-04"
states <- gsub(" ", "-", c(state.name, "District of Columbia"))
seed_dir <- file.path(temporary, "SEED_INPUT_JSONS", env$SIM_DAY_0_LABEL)
dir.create(seed_dir, recursive=TRUE)
for (state in states) writeLines("{}", file.path(seed_dir, paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE.json")))
env$county_count_for_state <- function(state) match(state, states)
env$run_logged_command <- function(...) stop("Launcher generation must not run fitting")
sources <- character()
env$source <- function(file, local=FALSE, ...) {
  sources <<- c(sources, file)
  if (file == "6d_create_intervention_inputs.R") stopifnot("ALL_INTERVENTIONS" %in% get("SELECTED_RUN_SCENARIOS", parent.frame()),
    identical(get("USE_CALIBRATED_INPUTS", parent.frame()), FALSE))
}
stopifnot(identical(env$run_pipeline_fits(), invisible(FALSE)), length(sources)==4L,
  identical(env$SELECTED_RUN_SCENARIOS, "NONE"))
commands <- readLines(file.path(temporary, "Rm_search/2025-10-04/fit_state_commands.txt"))
stopifnot(length(commands)==51L, all(grepl("5c_Rm_search.R", commands, fixed=TRUE)),
  all(grepl("--fit-initial-exposed=true", commands, fixed=TRUE)),
  all(grepl("ls6_container_exec.sh", commands, fixed=TRUE)),
  all(grepl("--base-r0=1.2", commands, fixed=TRUE)),
  all(grepl("--screening-realizations=25", commands, fixed=TRUE)),
  all(grepl("--realization-range=0,99", commands, fixed=TRUE)),
  all(grepl("--r0-search-metrics=peak_height", commands, fixed=TRUE)),
  all(grepl("--state-output-subdir=false", commands, fixed=TRUE)),
  setequal(sub(".*--selected-states=([^ ]+).*", "\\1", commands), states))
env$FIT_STATES <- c("District-of-Columbia","Delaware","Rhode-Island")
stopifnot(identical(env$pipeline_fit_states(),env$FIT_STATES),identical(env$run_pipeline_fits(),invisible(FALSE)))
scoped <- readLines(file.path(temporary,"Rm_search/2025-10-04/fit_state_commands.txt"))
stopifnot(length(scoped)==3L,setequal(sub(".*--selected-states=([^ ]+).*","\\1",scoped),env$FIT_STATES))
env$FIT_STATES <- character()

expect_error <- function(expr) stopifnot(inherits(tryCatch(force(expr), error=identity), "error"))
for (flag in c("--r0-screening-realizations=0", "--r0-exposure-multipliers=0,1",
  "--r0-base=0.9", "--r0-peak-height-tolerance=1", "--r0-refine-step=0",
  "--r0-search-metrics=all")) expect_error(env$initialize_pipeline_inputs(config_file, flag, repo, envir=new.env(parent=globalenv())))

state <- "Delaware"
stem <- paste0("INPUT_SEIHRD-STOCH_", state, "_SEED_NONE")
directory <- file.path(temporary, "epydemix_fit/2025-10-04", stem)
dir.create(directory, recursive=TRUE)
fit_path <- file.path(directory, paste0(stem, "_EPYDEMIX_R0_ONLY.json"))
source_fixture <- file.path(temporary, "source.py")
writeLines("original", source_fixture)
source_hash <- as.character(tools::md5sum(source_fixture))
seed <- file.path(seed_dir, paste0(stem, ".json"))
input_hash <- as.character(tools::md5sum(seed))
fit <- list(initial_exposed=list(list(county="10001", age_group="0", infected="10")),
  disease_model=list(parameters=list(R0="2.00000")),
  metadata_tags=list(sim_day_0="2025-10-04", epydemix_fit=list(method="full_simulator_staged_r0_exposures",
    simulation_start_date="2025-10-04", distance_settings=list(scenario_label="ALL_INTERVENTIONS",
      simulation_days=200L, realization_range=c(0L,99L), scoring_version=env$R0_SCORING_VERSION,
      search_metrics="peak_height", r0_selection_metric="peak_height")),
    staged_fit=list(version="staged_r0_exposures_v4", run_signature="signature", fitted_total=10, original_total=20,
      exposure_multiplier=.5, height_within_tolerance=TRUE, median_peak_week_matches=TRUE,
      settings=list(version="staged_r0_exposures_v4", base_r0=1.2, refine_step=.025, screening_realizations=25,
        height_tolerance=.15, exposure_multipliers=env$R0_EXPOSURE_MULTIPLIERS),
      source_hashes=setNames(list(source_hash), source_fixture),
      input_hashes=setNames(list(input_hash), paste0("pipeline:SEED_INPUT_JSONS/2025-10-04/", stem, ".json")))))
save_fit <- function() jsonlite::write_json(fit, fit_path, auto_unbox=TRUE, digits=NA)
save_fit()
matches <- function() env$wis_calibrated_fit_matches(fit_path, "2025-10-04", 200L, c(0L,99L), "peak_height")
stopifnot(matches())
writeLines("changed", source_fixture); stopifnot(!matches()); writeLines("original", source_fixture)
writeLines("changed", seed); stopifnot(!matches()); writeLines("{}", seed)
fit$metadata_tags$epydemix_fit$method <- "full_simulator_all_interventions_state_feature_search"
save_fit(); stopifnot(!matches())
fit$metadata_tags$epydemix_fit$method <- "full_simulator_staged_r0_exposures"
fit$initial_exposed[[1]]$infected <- "20"; save_fit(); stopifnot(!matches())
fit$initial_exposed[[1]]$infected <- "10"; save_fit(); stopifnot(matches())

# The nominally selected metadata has the same R0 but the WRONG E0. It must
# not win, including when the correct metadata is found by relocated fallback.
for (count in c(20,10)) {
  folder <- file.path(temporary, "Rm_search/2025-10-04/Delaware", paste0("E", count))
  dir.create(folder, recursive=TRUE)
  metadata <- list(metadata_tags=list(state_dir=state, scenario_label="ALL_INTERVENTIONS", sim_day_0="2025-10-04",
    staged_fit=list(run_signature="signature")), disease_model=list(parameters=list(R0="2.00000")),
    initial_exposed=list(list(county="10001", age_group="0", infected=as.character(count))), cli_args=list(days=200L), batch_num="1")
  jsonlite::write_json(metadata, file.path(folder, "metadata_batch-1.json"), auto_unbox=TRUE)
  readr::write_csv(data.frame(sim_id=0:99), file.path(folder, "simulation_times_batch-1.csv"))
}
fit$metadata_tags$r0_search <- list(selected_metadata_file=file.path(temporary, "Rm_search/2025-10-04/Delaware/E20/metadata_batch-1.json"))
save_fit()
env$SELECTED_RUN_SCENARIOS <- "ALL_INTERVENTIONS"
env$prepare_reused_fit_outputs(envir=env)
stopifnot(nrow(env$REUSED_FIT_OUTPUTS)==1L, grepl("/E10/", env$REUSED_FIT_OUTPUTS$metadata_file, fixed=TRUE))
stopifnot(env$require_completed_pipeline_fits(states=state))

checkpoint_dir <- file.path(temporary, "Rm_search/2025-10-04/checkpoints")
dir.create(checkpoint_dir)
settings <- list(sim_day_0="2025-10-04", scenario="ALL_INTERVENTIONS", simulation_days=200L,
  realization_range=c(0L,99L), selection_metric="peak_height", search_metrics="peak_height",
  scoring_version=env$R0_SCORING_VERSION, fit_method="staged_simulator",
  staged_version="staged_r0_exposures_v4",run_signature="signature")
saveRDS(settings, file.path(checkpoint_dir, "Delaware_Rm_search_settings.rds"))
tables <- c("search_trace", "scores_by_week", "quantile_predictions", "best_by_state", "summary", "featured_candidate_comparison", "calibrated_json_manifest")
for (table in tables) saveRDS(data.frame(geo_region=state, disease_R0=2, initial_exposed_total=10),
  file.path(checkpoint_dir, paste0("Delaware_Rm_search_", table, ".rds")))
env$aggregate_rm_search_checkpoints(states=state)
saveRDS(data.frame(geo_region=state, disease_R0=2, initial_exposed_total=20), file.path(checkpoint_dir, "Delaware_Rm_search_best_by_state.rds"))
expect_error(env$aggregate_rm_search_checkpoints(states=state))

# Evaluate the actual 6d copy functions: every scenario receives both fitted
# parameters without changing its clinical parameters or intervention blocks.
code <- as.list(parse("scripts/6d_create_intervention_inputs.R"))
for (name in c("copy_if_present", "copy_calibrated_fields")) {
  expr <- code[vapply(code, function(x) is.call(x) && identical(x[[1]], as.name("<-")) && identical(x[[2]], as.name(name)), logical(1))]
  eval(expr[[1]], env)
}
paths <- c(env$NONE_TEMPLATE_FILE, env$INTERVENTION_TEMPLATE_FILES)
for (path in paths) {
  original <- jsonlite::read_json(path)
  generated <- env$copy_calibrated_fields(original, fit)
  stopifnot(identical(generated$initial_exposed, fit$initial_exposed), generated$disease_model$parameters$R0=="2.00000")
  original$disease_model$parameters$R0 <- generated$disease_model$parameters$R0
  original$initial_exposed <- generated$initial_exposed
  original$metadata_tags$staged_fit <- fit$metadata_tags$staged_fit
  stopifnot(identical(original, generated))
}
plot_code <- as.list(parse("scripts/9a_pre_sim_input_plots.R"))
name <- "read_staged_initial_exposed_by_county"
expr <- plot_code[vapply(plot_code, function(x) is.call(x) && identical(x[[1]], as.name("<-")) && identical(x[[2]], as.name(name)), logical(1))]
eval(expr[[1]], env)
env$search_root <- temporary
env$sim_day_0_label <- "2025-10-04"
stopifnot(sum(env$read_staged_initial_exposed_by_county()$initial_exposed)==10)
fit$metadata_tags$staged_fit <- NULL
save_fit()
stopifnot(nrow(env$read_staged_initial_exposed_by_county())==0L)
unlink(temporary, recursive=TRUE)
cat("51-state staged launchers, stale-fit gates, exact exposure reuse, checkpoints and five-scenario handoff passed.\n")
