#////////
#### LS6 Scenarios Phase Inputs ####
#////////
#' Require completed fits, then prepare remaining scenario launchers and stop.
#' Shared experiment settings: LS6_PIPELINE_INPUTS.R in this directory.
#' From the repository root:
#' Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/2_RUN_SCENARIOS.R

pipeline_shared_inputs <- "LS6_PIPELINE_INPUTS.R"
pipeline_inputs <- list(
  pipeline_phase = "scenarios",
  execution_target = "ls6"
)
