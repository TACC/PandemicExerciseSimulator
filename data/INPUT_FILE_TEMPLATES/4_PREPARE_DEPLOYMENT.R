#////////
#### Dashboard Deployment Inputs ####
#////////
# Rebuild the deployment folder from existing 7a Parquet data. No fitting,
# simulations, ingestion, or figure generation. This does not upload the app.
# From the repository root:
# Rscript scripts/0_run_full_pipeline_US.R --config=data/INPUT_FILE_TEMPLATES/4_PREPARE_DEPLOYMENT.R
# On LS6, prefix the command with: bash scripts/ls6_container_exec.sh
# Keep this file beside LS6_PIPELINE_INPUTS.R when copying an experiment.

pipeline_shared_inputs <- "LS6_PIPELINE_INPUTS.R"
pipeline_inputs <- list(
  pipeline_phase = "deploy",
  execution_target = "ls6", # Read completed TACC_FILES, including reused fit outputs.

  # SUBSET: edit this vector. ALL STATES: replace it with NULL or character().
  # These choices affect this deployment only; original outputs are retained.
  selected_states = c("Texas", "Oklahoma", "New-Mexico", "Louisiana", "Arkansas", "California"),
  selected_scenarios = c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS"),
  dashboard_max_bundle_bytes = 5e9,

  # Rebuilds deploy/shinyapps/PandemicSimExplorer/ in place, replacing its data.
  # Downloads selected map boundaries from GitHub and preserves the folder's existing Publisher settings.
  deploy_shinyapps = FALSE # Connect Cloud: publish the prepared folder with Posit Publisher.
)
