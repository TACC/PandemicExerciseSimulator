# ////////
#### Script Overview ####
# ////////
#' This is the orchestrastion script for the full 0-9 pipeline:
#'  setup, population, contact matrices, mobility, risk ratios, seed inputs
#'  R_m fitting, and intervention scenarios.
#' TACC commands, optional local simulations, output ingestion, dashboard
#'  preparation, and validation figures are also made.
#'
#' The `scripts/` dir Python and R files control the inputs and output processing,
#'  while `src/` is the Pandemic Exercise Simulator itself entirely in Python.
#'
#' Experiment settings and their explanations are kept separately in:
#'   data/INPUT_FILE_TEMPLATES/RUN_FULL_PIPELINE_INPUTS.R
#' Copy that input-only file for an experiment instead of editing this workflow.
#'
#' RStudio: open scripts.Rproj, set PIPELINE_CONFIG_FILE to your input file,
#' then Source this script. If unset, the example input file is used.
#' Command line from the repository root:
#'   Rscript scripts/0_run_full_pipeline_US.R --config=path/to/experiment.R
#' Add --check-config to validate inputs without running the pipeline.
#'
#' LS6 phase inputs are 1_RUN_FIT.R, 2_RUN_SCENARIOS.R, and 3_RUN_FIGURES.R.
#' Fit and scenarios write launchers and stop; results never runs simulations.
#' RUN_FULL_PIPELINE_INPUTS.R remains the complete local example.
#' The #### section headers below define the RStudio outline independently
#' of the section_banner() calls that print progress to the console.
# ////////

# ////////
#### Section 0 Pipeline Inputs ####
# ////////
.pipeline_invocation_dir <- getwd()
.pipeline_source_files <- vapply(sys.frames(), function(frame) {
  value <- get0("ofile", envir = frame, inherits = FALSE)
  if (is.null(value)) "" else as.character(value)[[1]]
}, character(1))
.pipeline_file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
.pipeline_script <- if (any(nzchar(.pipeline_source_files))) {
  tail(.pipeline_source_files[nzchar(.pipeline_source_files)], 1)
} else if (length(.pipeline_file_arg)) {
  sub("^--file=", "", .pipeline_file_arg[[1]])
} else file.path(getwd(), "0_run_full_pipeline_US.R")
.pipeline_scripts_dir <- dirname(normalizePath(.pipeline_script, mustWork = TRUE))
source(file.path(.pipeline_scripts_dir, "0_pipeline_helpers.R"), local = TRUE)
initialize_pipeline_inputs(
  config_file = get0("PIPELINE_CONFIG_FILE", inherits = FALSE),
  args = commandArgs(trailingOnly = TRUE),
  repo_root = dirname(.pipeline_scripts_dir),
  invocation_dir = .pipeline_invocation_dir
)
if (any(commandArgs(trailingOnly = TRUE) %in% c("--check-config", "--check-config=true"))) {
  cat("Validated pipeline inputs from ", PIPELINE_CONFIG_FILE, "\n", sep = "")
  dput(pipeline_input_values)
  cat("Effective phase: ", PIPELINE_PHASE, "; target: ", EXECUTION_TARGET,
    "; fitting launch: ", R0_FIT_LAUNCH, "\n", sep = "")
} else {
  setwd(.pipeline_scripts_dir)

  # ////////
#### Section 0a Package Setup ####
  # ////////
  load_pipeline_packages()
  initialize_pipeline_runtime()
  on.exit({
    while (sink.number() > 0) sink()
    close(stdout_log_con)
  }, add = TRUE)
  log_pipeline_settings()

  if (PIPELINE_PHASE %in% c("all", "fit")) {
    # ////////
#### Section 0b Ensuring Poetry Dependencies ####
    # ////////
    section_banner("0. Dependencies")
    poetry_install_args <- c("install", "--no-root")
    cat("Ensuring Poetry dependencies are installed:\n")
    cat("  poetry ", paste(shQuote(poetry_install_args), collapse = " "), "\n", sep = "")
    poetry_install_status <- run_logged_command("poetry", poetry_install_args, workdir = repo_root)
    if (!identical(poetry_install_status, 0L)) {
      stop("Poetry dependency installation failed with exit status ", poetry_install_status)
    }

    # ////////
#### Section 1 Population Data ####
    # ////////
    section_banner("1. Population")
    source("1_county_age_pop_totals.R")

    # ////////
#### Section 2 Contact Matrices ####
    # ////////
    section_banner("2. Contact matrices")
    contact_matrix_files <- list.files(
      "../data",
      pattern = "^contact_matrix_.*_Mistry2021_all\\.csv$",
      recursive = TRUE,
      full.names = TRUE
    )
    if (length(contact_matrix_files) >= 51) {
      cat("Contact matrices already exist for ", length(contact_matrix_files), " state/DC directories.\n", sep = "")
    } else {
      cat("Only found ", length(contact_matrix_files), " contact matrices; generating missing contact matrices.\n", sep = "")
      library(reticulate)
      poetry_python = system("poetry env info --path", intern = TRUE)
      poetry_python_bin = file.path(poetry_python, "bin", "python")
      use_python(poetry_python_bin, required = TRUE)
      py_run_file("2_epydemix_contact_matrix_generation.py")
    } # end if contact matrices not made yet

    # ////////
#### Section 3 County Mobility Networks ####
    # ////////
    section_banner("3. Mobility networks")
    source("3a_ct_ak_crosswalks.R")

    if (MOBILITY_YR == "2025") {
      # Uses ACS year defined above as 2020-2024 was most recent mid-2026
      source("3c_advan_county_mobility.R")
    } else if (MOBILITY_YR == "2019") {
      # Uses 2019-2023 ACS to be closer to 2019 population but with new AK+CT counties
      source("3b_county_mobility_timeseries_post2020census.R")
    }

    # ////////
#### Section 4 Influenza High Risk Ratios ####
    # ////////
    section_banner("4. Influenza risk ratios")
    if (!file.exists("../data/Wyoming/state_Wyoming_high-risk-ratios-flu-only.csv")) {
      start_time = Sys.time()
      source("4a_flu_state_high_risk_by_age.R")
      end_time = Sys.time()
      elapsed_time = end_time - start_time
      print(as.numeric(elapsed_time, units = "mins"))
    } else {
      print("State-level high risk ratios already exist")
    } # end if need to make state-level BRFSS/NSCH data

    county_high_risk_detail_file <- "../data/RISK_RATIOS/all_US_county_high-risk-ratios-detailed.csv"
    state_county_high_risk_files <- list.files(
      "../data",
      pattern = "^county_.*_high-risk-ratios-flu-only\\.csv$",
      recursive = TRUE,
      full.names = TRUE
    )
    if (file.exists(county_high_risk_detail_file) && length(state_county_high_risk_files) >= 51) {
      print("County-level high risk ratios already exist")
    } else {
      source("4b_flu_county_high_risk_by_age.R")
    }

  }

  if (PIPELINE_PHASE == "scenarios") {
    require_completed_pipeline_fits()
    if (EXECUTION_TARGET == "ls6") aggregate_rm_sweep_checkpoints()
  }

  if (PIPELINE_PHASE != "results") {
    for (SIM_DAY_0 in SIM_DAY_0_VALUES) {
      SIM_DAY_0 <- as.Date(SIM_DAY_0)
      SIM_DAY_0_LABEL <- as.character(SIM_DAY_0)
      section_banner(paste0("Running Date-Dependent Pipeline For ", SIM_DAY_0_LABEL))

      if (PIPELINE_PHASE %in% c("all", "fit")) {
        # ////////
#### Section 5a Seed None Inputs ####
        # ////////
        section_banner("5a. Seed inputs")
        prepare_pipeline_seeds()

        # ////////
#### Section 5b/5c R_m Fits ####
        # ////////
        section_banner("5b/5c. R_m fitting")
        if (!run_pipeline_fits()) next
      }
      if (PIPELINE_PHASE == "fit") next

      # ////////
#### Section 6 Intervention Inputs ####
      # ////////
      section_banner("6. Intervention inputs")
      # ////////
#### Section 6a Vaccine Coverage ####
      # ////////
      source("6a_vaccine_coverage_by_state.R")
      # ////////
#### Section 6b Antiviral Stockpiles ####
      # ////////
      source("6b_outpatient_antiviral_coverage_by_state.R")
      # ////////
#### Section 6c Weekend NPI Schedule ####
      # ////////
      source("6c_weekend_npi_schedule.R")
      # ////////
#### Section 6d Intervention Scenario Inputs ####
      # ////////
      source("6d_create_intervention_inputs.R")

    }

  }

  if (R0_FIT_LAUNCH == "pylauncher") {
    message("Fitting launchers prepared. Submit each date's fit_state_pylauncher.sh; after completion, run 2_RUN_SCENARIOS.R.")
  } else if (PIPELINE_PHASE == "fit") {
    message("Local fitting complete. Run the scenarios phase next.")
  }
  if (PIPELINE_PHASE %in% c("all", "scenarios") && R0_FIT_LAUNCH != "pylauncher") {
    # ////////
#### Section 6e Parallel Command Generation ####
    # ////////
    section_banner("6e. TACC scenario commands")
    prepare_reused_fit_outputs()
    source("6e_create_parallel_commands.R")

    # ////////
#### Section 6f Selected Local Scenarios ####
    # ////////
    if (EXECUTION_TARGET == "local" && length(SELECTED_RUN_STATES) > 0L &&
      (RUN_WEB_PREVIEW || PIPELINE_PHASE == "scenarios")) {
      section_banner("6f. Local preview")
      source("6f_run_selected_scenarios.R")
    }

    if (PIPELINE_PHASE == "scenarios") {
      message(if (EXECUTION_TARGET == "ls6")
        "Scenario launcher prepared under TACC_FILES. Submit state_pylauncher.sh; after completion, run 3_RUN_FIGURES.R."
      else "Local scenarios complete. Run the results phase next.")
    }
  }

  if (PIPELINE_PHASE == "results" ||
    (PIPELINE_PHASE == "all" && R0_FIT_LAUNCH != "pylauncher")) {
    if (PIPELINE_PHASE == "results") {
      require_completed_pipeline_fits()
      prepare_reused_fit_outputs()
      require_completed_scenario_outputs()
    }
    if (RUN_WEB_PREVIEW || PIPELINE_PHASE == "results") {
      # ////////
#### Section 7 Output Ingestion ####
      # ////////
      section_banner("7. Output ingestion")
      source("7a_process_output_to_db.R")

      # ////////
#### Section 8 Dashboard Bundle ####
      # ////////
      section_banner("8. Dashboard bundle")
      source("8_prepare_shinyapps_bundle.R")

      # ////////
#### Section 8b shinyapps.io Deployment ####
      # ////////
      if (DEPLOY_SHINYAPPS) {
        section_banner("Section 8b Deploying shinyapps.io Bundle")
        if (!requireNamespace("rsconnect", quietly = TRUE)) {
          stop("Package rsconnect is required for shinyapps.io deployment. Install it with install.packages('rsconnect').")
        }
        if (!nzchar(SHINYAPPS_ACCOUNT)) {
          stop("Set --shinyapps-account=<account-name> when --deploy-shinyapps=true.")
        }

        shinyapps_bundle_dir <- normalizePath(
          file.path(repo_root, "deploy", "shinyapps", "PandemicSimExplorer"),
          mustWork = TRUE
        )
        message("Deploying shinyapps.io bundle:")
        message("  appDir = ", shinyapps_bundle_dir)
        message("  account = ", SHINYAPPS_ACCOUNT)
        message("  appName = ", SHINYAPPS_APP_NAME)
        rsconnect::deployApp(
          appDir = shinyapps_bundle_dir,
          appName = SHINYAPPS_APP_NAME,
          account = SHINYAPPS_ACCOUNT
        )
      } else {
        message("Prepared shinyapps.io bundle but did not deploy.")
        message("To deploy later, run:")
        message(
          "  rsconnect::deployApp(appDir = 'deploy/shinyapps/PandemicSimExplorer', ",
          "appName = '", SHINYAPPS_APP_NAME, "', account = '<your-shinyapps-account>')"
        )
      }
    }

    # ////////
#### Section 9 Figures And Validation ####
    # ////////
    # ////////
#### Section 9a Pre Simulation Input Plots ####
    # ////////
    if (MAKE_PRE_SIM_FIGS) {
      section_banner("Section 9a Running Pre-Simulation Input Plots")
      pre_sim_fig_args <- c(
        file.path(repo_root, "scripts", "9a_pre_sim_input_plots.R"),
        paste0("--output-dir=", PIPELINE_OUTPUT_DIR),
        paste0("--selected-states=", paste(SELECTED_RUN_STATES, collapse = ",")),
        paste0("--year=", MOBILITY_YR),
        paste0("--acs-year-range=", ACS_YEAR_RANGE)
      )
      pre_sim_fig_status <- run_logged_command("Rscript", pre_sim_fig_args, workdir = repo_root)
      if (!identical(pre_sim_fig_status, 0L)) {
        stop("Pre-simulation input plotting failed with exit status ", pre_sim_fig_status)
      }
    }

    # ////////
#### Section 9b Post Simulation Validation Scoring Plots ####
    # ////////
    if (MAKE_VALIDATION_FIGS) {
      section_banner("Section 9b Running Hubverse-Style Validation Scoring")
      score_args <- c(
        file.path(repo_root, "scripts", "9b_score_validation_hubverse_style.R"),
        paste0("--output-dir=", PIPELINE_OUTPUT_DIR),
        paste0("--output-source-regex=", VALIDATION_OUTPUT_SOURCE_REGEX)
      )
      score_status <- run_logged_command("Rscript", score_args, workdir = repo_root)
      if (!identical(score_status, 0L)) {
        stop("Hubverse-style validation scoring failed with exit status ", score_status)
      }
    }

    # ////////
#### Section 9c Completion And Runtime Diagnostics ####
    # ////////
    if (MAKE_DIAGNOSTIC_FIGS) {
      section_banner("Section 9c Running Completion And Runtime Diagnostics")
      run_diagnostic_args <- c(
        file.path(repo_root, "scripts", "9c_score_validation_run_diagnostics.R"),
        paste0("--output-dir=", PIPELINE_OUTPUT_DIR),
        paste0("--output-source-regex=", VALIDATION_OUTPUT_SOURCE_REGEX)
      )
      run_diagnostic_status <- run_logged_command("Rscript", run_diagnostic_args, workdir = repo_root)
      if (!identical(run_diagnostic_status, 0L)) {
        stop("Completion/runtime diagnostics failed with exit status ", run_diagnostic_status)
      }
    }
  }
}
