#////////
#### LS6 Results Phase Inputs ####
#////////
#' Require completed simulations, then build Parquet data and figures.
#' Full US ingestion, validation and figure generation can take hours.
#' Use an allocated compute node with sufficient wall time; quiet plotting
#' intervals do not by themselves indicate a stalled job. Preserve outputs and
#' checkpoints on restart; only finished checkpointed work is reused.
#' Prepare the deployment separately with 4_PREPARE_DEPLOYMENT.R.
#' Shared experiment settings: LS6_PIPELINE_INPUTS.R in this directory.
#' The wrapper loads Apptainer and sets the WORK R library on every invocation.
#' From the repository root:
#' bash scripts/ls6_container_exec.sh Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/3_RUN_FIGURES.R

pipeline_shared_inputs <- "LS6_PIPELINE_INPUTS.R"
pipeline_inputs <- list(
  pipeline_phase = "results",
  execution_target = "ls6"
)
