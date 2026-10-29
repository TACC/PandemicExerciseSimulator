#////////
#### LS6 Fit Phase Inputs ####
#////////
#' Prepare state R_m fitting launchers, then stop. Submit the generated launcher.
#' Shared experiment settings: LS6_PIPELINE_INPUTS.R in this directory.
#' The wrapper loads Apptainer and sets the WORK R library on every invocation.
#' From the repository root:
#' bash scripts/ls6_container_exec.sh Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/1_RUN_FIT.R

pipeline_shared_inputs <- "LS6_PIPELINE_INPUTS.R"
pipeline_inputs <- list(
  pipeline_phase = "fit",
  execution_target = "ls6"
)
