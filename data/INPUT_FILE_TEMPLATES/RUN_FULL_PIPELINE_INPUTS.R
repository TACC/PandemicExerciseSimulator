#' Inputs for scripts/0_run_full_pipeline_US.R. 
#' Make a copy this file for your own experiment.
#' This file defines settings only; sourcing it does not run the pipeline.
#' 
#' From the repository root:
#' `Rscript scripts/0_run_full_pipeline_US.R 
#'   --config=data/INPUT_FILE_TEMPLATES/RUN_FULL_PIPELINE_INPUTS.R`
#' Any command-line option overrides the matching value below.
#' Paths below are relative to the repository root unless absolute.

pipeline_inputs <- list(
  # Local example: run the complete pipeline, including selected preview states.
  pipeline_phase = "all",            # "all", "fit", "scenarios", or "results".
  execution_target = "local",        # "local" runs sims; "ls6" writes launchers.
  ls6_container_image = NULL,         # Optional LS6 image override; default is $WORK/pes_pipeline_r442_py312.sif.
  # Experiment: outputs are created under this directory, relative to the repo.
  output_dir = "LOCAL_PIPELINE_TEST",
  sim_day_0 = "2025-10-04",           # One date, or c("2025-09-27", "2025-10-04").
  simulation_days = 200L,             # Day 0 initializes; simulate days 1..200.
  sim_realization_range = c(0L, 99L), # Inclusive IDs for downstream scenarios.

  # Local preview choices. These do NOT limit fitting or TACC state generation:
  # the pipeline fits all 50 states + DC. Use repository names, with hyphens.
  # Set selected_states = NULL (or character()) to skip local simulations and
  # bundle all available TACC_FILES states for the selected scenarios instead.
  selected_states = c("District-of-Columbia", "Connecticut"),
  selected_scenarios = c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS"),

  # R_m fitting: simulator_county_threshold uses 5c up to the county threshold;
  # larger states use Epydemix. A threshold of 255 includes all states + DC.
  r0_fit_method = "simulator_county_threshold", # Alternative: "epydemix_all".
  r0_county_threshold = 255L,
  r0_realization_range = c(0L, 9L),    # Inclusive IDs per candidate R_m; 0..99 = 100 sims.
  r0_search_metrics = c("total", "peak_height", "peak_timing", "wis"),
  r0_selection_metric = "peak_height", # R_m exported to ALL downstream scenarios.
  r0_fit_scenario = "ALL_INTERVENTIONS", # Scenario fitted to observed hospitalizations.
  reuse_best_fit_simulations = FALSE, # TRUE keeps the chosen candidate for downstream use.
  # Reuse requires matching fit/downstream realization ranges. Keep the fitting
  # scenario in selected_scenarios to include it in analyses; its rerun is omitted.
  # Each criterion is searched independently; there is no combined objective.
  # "all" means the three features; c("all", "wis") includes all four criteria.
  # Weekly scoring includes only complete Sun-Sat MMWR weeks within the horizon.
  # Peak height is the maximum of the weekly median trajectory, not its first peak.

  # Execution within each candidate. "auto" conservatively caps at four workers.
  execution_mode = "parallel",      # "parallel" or "serial".
  workers = "auto",                 # "auto" or a positive integer, e.g. 32L.
  r0_fit_launch = "direct",         # "direct" runs fits during 0.
  # "pylauncher" prepares inputs + state_commands.txt + state_pylauncher.{sh,py}
  # under <output_dir>/Rm_search/<date>/, then stops before running fits.
  # LS6 100-sim example: r0_realization_range=c(0L,99L), workers=32L,
  # r0_fit_launch="pylauncher". Set the allocation in the generated .sh and submit it.
  # After fitting, rerun with r0_fit_launch="direct" to reuse fits and continue.

  # Epydemix settings, used only for states handled by the 5b fitting method.
  epydemix_fit_target = "hosp_increase", # Alternative: "hosp_incident".
  epydemix_peak_height_weight = 0.3,
  epydemix_nsim = 1000L,

  # Scenario mechanics live in the simulator JSON templates, not scenario names.
  # Each template is independent: ALL_INTERVENTIONS does not merge the others.
  input_template_dir = "data/INPUT_FILE_TEMPLATES",
  none_template = NULL,             # NULL uses the standard file in that directory.
  vaccine_template = NULL,
  antiviral_template = NULL,
  npi_template = NULL,
  all_interventions_template = NULL,

  # 2025 mobility uses Advan; 2019 uses SafeGraph.
  acs_year_range = "2020-2024",
  mobility_year = 2025L,

  # Preview, figures, and dashboard publication. PyLauncher preparation stops
  # before these stages. These settings apply when running/resuming directly.
  run_web_preview = TRUE,           # Run ETL/bundle; local sims only with selected states.
  make_pre_sim_figs = TRUE,         # Section 9a: population, exposures and interventions.
  make_validation_figs = TRUE,      # Section 9b: validation scores; needs saved outputs.
  make_diagnostic_figs = TRUE,      # Section 9c: completion/runtime; needs saved outputs.
  validation_output_source_regex = "WEB_OUTPUTS", # Match output directories to score.
  deploy_shinyapps = FALSE,         # TRUE publishes the bundle to shinyapps.io.
  shinyapps_account = "",           # Required only for deployment.
  shinyapps_app_name = "PandemicSimExplorer"
)
