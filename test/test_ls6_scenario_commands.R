# Run from the repository root. Creates only a temporary, synthetic JSON batch.
repo <- normalizePath(".")
check_scenario_commands <- function() {
  original_wd <- getwd()
  output_name <- paste0("LS6_CONTAINER_COMMANDS_", Sys.getpid(), "_TEST")
  output <- file.path(repo, output_name)
  stopifnot(!dir.exists(output))
  on.exit({setwd(original_wd); unlink(output, recursive = TRUE)}, add = TRUE)
  inputs <- file.path(output, "TACC_FILES", "2025-10-04")
  dir.create(inputs, recursive = TRUE)
  writeLines('{"metadata_tags":{"sim_day_0":"2025-10-04","state_dir":"Delaware","scenario_label":"NONE"}}',
    file.path(inputs, "INPUT_Delaware_NONE.json"))
  env <- new.env(parent = globalenv())
  sys.source(file.path(repo, "scripts", "0_pipeline_helpers.R"), env)
  env$PIPELINE_OUTPUT_DIR <- output_name
  env$SELECTED_RUN_SCENARIOS <- "NONE"
  env$SIM_DAY_0_VALUES <- "2025-10-04"
  env$SIMULATION_DAYS <- 200L
  env$EXECUTION_TARGET <- "ls6"
  env$LS6_CONTAINER_IMAGE <- ""
  setwd(file.path(repo, "scripts"))
  sys.source("6e_create_parallel_commands.R", env)
  commands <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(length(commands) == 1L, startsWith(commands, "bash "),
    grepl("../../scripts/ls6_container_exec.sh", commands, fixed = TRUE),
    !grepl("--image", commands, fixed = TRUE),
    grepl("poetry run python3 ../../src/simulator.py", commands, fixed = TRUE))
  launcher <- readLines(file.path(output, "TACC_FILES", "state_pylauncher.sh"))
  stopifnot(sum(grepl("^module load tacc-apptainer$", launcher)) == 1L)
  env$LS6_CONTAINER_IMAGE <- "/test/image with spaces.sif"
  sys.source("6e_create_parallel_commands.R", env)
  explicit <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(grepl(shQuote(env$LS6_CONTAINER_IMAGE), explicit, fixed = TRUE))
  # Native execution remains available with exactly the same scenario arguments.
  env$EXECUTION_TARGET <- "local"
  sys.source("6e_create_parallel_commands.R", env)
  native <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(startsWith(native, "poetry run python3 "))
}
check_scenario_commands()
cat("Container and native scenario command generation passed.\n")
