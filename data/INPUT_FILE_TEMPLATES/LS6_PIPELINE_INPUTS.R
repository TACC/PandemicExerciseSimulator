#////////
#### Shared LS6 Pipeline Inputs ####
#////////
#' Edit scientific settings here once for 1_RUN_FIT.R, 2_RUN_SCENARIOS.R, and
#' 3_RUN_FIGURES.R. Keep these four files together when copying an experiment.
#' The phase files inherit this list; command-line overrides take precedence.
#' Fit candidates and downstream scenarios both use 100 realizations.
#' No local preview simulations run: selected_states is NULL.

pipeline_inputs <- list(
  # Shared LS6 experiment settings used by all three phase files.
  pipeline_phase = "fit",            # "fit", "scenarios", "results", or "deploy".
  execution_target = "ls6",          # LS6 phases prepare launchers instead of running sims.
  # LS6 commands automatically use $WORK/pes_pipeline_r442_py312.sif.
  # Optional override for an image stored elsewhere; local execution stays native.
  ls6_container_image = NULL,
  # Experiment: outputs are created under this directory, relative to the repo.
  output_dir = "LS6_RmSweep_TEST",
  sim_day_0 = "2025-10-04",           # One date, or c("2025-09-27", "2025-10-04").
  simulation_days = 200L,             # Day 0 initializes; simulate days 1..200.
  sim_realization_range = c(0L, 99L), # Inclusive IDs for downstream scenarios.

  # Local preview choices. These do NOT limit fitting or TACC state generation:
  # the pipeline fits all 50 states + DC. Use repository names, with hyphens.
  # Set selected_states = NULL (or character()) to skip local simulations and
  # bundle all available TACC_FILES states for the selected scenarios instead.
  selected_states = NULL,
  # 4_PREPARE_DEPLOYMENT.R overrides this for its deployment-only subset.
  selected_scenarios = c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS"),

  # R_m fitting: simulator_county_threshold uses 5c up to the county threshold;
  # larger states use Epydemix. A threshold of 255 includes all states + DC.
  r0_fit_method = "simulator_county_threshold", # Alternative: "epydemix_all".
  r0_county_threshold = 255L,
  r0_realization_range = c(0L, 99L),    # Inclusive IDs per candidate R_m; 0..99 = 100 sims.
  r0_search_metrics = c("total", "peak_height", "peak_timing", "wis"),
  r0_selection_metric = "peak_height", # R_m exported to ALL downstream scenarios.
  r0_fit_scenario = "ALL_INTERVENTIONS", # Scenario fitted to observed hospitalizations.
  reuse_best_fit_simulations = TRUE, # TRUE keeps the chosen candidate for downstream use.
  # Reuse requires matching fit/downstream realization ranges. Keep the fitting
  # scenario in selected_scenarios to include it in analyses; its rerun is omitted.
  # Each criterion is searched independently; there is no combined objective.
  # "all" means the three features; c("all", "wis") includes all four criteria.
  # Weekly scoring includes only complete Sun-Sat MMWR weeks within the horizon.
  # Peak height is the maximum of the weekly median trajectory, not its first peak.

  # Execution within each candidate. "auto" conservatively caps at four workers.
  execution_mode = "parallel",      # "parallel" or "serial".
  workers = 32L,                    # Requested realization workers; launcher sets available CPUs.
  r0_fit_launch = "direct",         # Explicit phases derive this from execution_target.
  # 1_RUN_FIT.R prepares the fitting launcher; 2_RUN_SCENARIOS.R requires finished
  # fits and prepares the scenario launcher. 3_RUN_FIGURES.R processes results.
  # Set the allocation in fit_state_pylauncher.sh for fitting and
  # state_pylauncher.sh for scenarios before submission.

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

  # Results-phase processing. Fit and scenarios stop before ingestion or figures.
  run_web_preview = TRUE,           # Results builds the bundle; LS6 never runs local sims.
  make_pre_sim_figs = TRUE,         # Section 9a: population, exposures and interventions.
  make_validation_figs = TRUE,      # Section 9b: validation scores; needs saved outputs.
  make_diagnostic_figs = TRUE,      # Section 9c: completion/runtime; needs saved outputs.
  validation_output_source_regex = "TACC_FILES", # Selected fitting outputs are added automatically.
  deploy_shinyapps = FALSE,         # TRUE publishes the bundle to shinyapps.io.
  dashboard_max_bundle_bytes = 5e9, # Entire deployment folder, decimal 5 GB.
  shinyapps_account = "",           # Required only for deployment.
  shinyapps_app_name = "PandemicSimExplorer"
)
