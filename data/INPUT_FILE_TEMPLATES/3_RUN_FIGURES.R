#////////
#### LS6 Results Phase Inputs ####
#////////
#' Require completed simulations, then build Parquet data, figures, and the bundle.
#' Shared experiment settings: LS6_PIPELINE_INPUTS.R in this directory.
#' From the repository root:
#' Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/3_RUN_FIGURES.R

pipeline_shared_inputs <- "LS6_PIPELINE_INPUTS.R"
pipeline_inputs <- list(
  pipeline_phase = "results",
  execution_target = "ls6"
)
