# Run from the repository root. Creates only a temporary, synthetic JSON batch.
repo <- normalizePath(".")
check_scenario_commands <- function() {
  original_wd <- getwd()
  output_name <- paste0("LS6_CONTAINER_COMMANDS_", Sys.getpid(), "_TEST")
  output <- file.path(repo, output_name)
  stopifnot(!dir.exists(output))
  on.exit({setwd(original_wd); unlink(output, recursive = TRUE)}, add = TRUE)
  scenarios <- c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS")
  states <- c("Delaware", "Nevada")
  dates <- c("2025-10-04", "2025-10-11")
  for (date in dates) {
    inputs <- file.path(output, "TACC_FILES", date)
    dir.create(inputs, recursive = TRUE)
    for (state in states) for (scenario in scenarios) {
      jsonlite::write_json(list(metadata_tags = list(sim_day_0 = date,
        state_dir = state, scenario_label = scenario)),
        file.path(inputs, paste0("INPUT_", state, "_", scenario, ".json")), auto_unbox = TRUE)
    }
  }
  env <- new.env(parent = globalenv())
  sys.source(file.path(repo, "scripts", "0_pipeline_helpers.R"), env)
  env$PIPELINE_OUTPUT_DIR <- output_name
  env$SELECTED_RUN_SCENARIOS <- scenarios
  env$SIM_DAY_0_VALUES <- dates
  env$SIMULATION_DAYS <- 200L
  env$EXECUTION_TARGET <- "ls6"
  env$LS6_CONTAINER_IMAGE <- ""
  setwd(file.path(repo, "scripts"))
  sys.source("6e_create_parallel_commands.R", env)
  commands <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(length(commands) == 20L, all(startsWith(commands, "bash ")),
    all(grepl("../../scripts/ls6_container_exec.sh", commands, fixed = TRUE)),
    !any(grepl("--image", commands, fixed = TRUE)),
    all(grepl("poetry run python3 ../../src/simulator.py", commands, fixed = TRUE)),
    all(table(env$input_metadata$scenario) == 4L))
  launcher_file <- file.path(output, "TACC_FILES", "state_pylauncher.sh")
  launcher <- readLines(launcher_file)
  stopifnot(sum(grepl("^module load tacc-apptainer$", launcher)) == 1L,
    any(grepl("^python3 state_pylauncher.py$", launcher)))
  write("# Preserve user allocation edits", launcher_file, append = TRUE)
  env$LS6_CONTAINER_IMAGE <- "/test/image with spaces.sif"
  sys.source("6e_create_parallel_commands.R", env)
  explicit <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(length(explicit) == 20L,
    all(grepl(shQuote(env$LS6_CONTAINER_IMAGE), explicit, fixed = TRUE)),
    tail(readLines(launcher_file), 1) == "# Preserve user allocation edits")
  # Reusing fitted ALL_INTERVENTIONS batches omits only that scenario; every
  # remaining scenario still uses the container prefix across states/dates.
  env$REUSED_FIT_OUTPUTS <- expand.grid(state = states, sim_day_0 = dates,
    scenario = "ALL_INTERVENTIONS", stringsAsFactors = FALSE)
  sys.source("6e_create_parallel_commands.R", env)
  reused <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(length(reused) == 16L, all(startsWith(reused, "bash ")),
    !"ALL_INTERVENTIONS" %in% env$input_metadata$scenario,
    setequal(env$input_metadata$scenario, setdiff(scenarios, "ALL_INTERVENTIONS")),
    all(table(env$input_metadata$scenario) == 4L))
  # Native execution remains available with exactly the same scenario arguments.
  env$EXECUTION_TARGET <- "local"
  sys.source("6e_create_parallel_commands.R", env)
  native <- readLines(file.path(output, "TACC_FILES", "state_commands.txt"))
  stopifnot(length(native) == 16L, all(startsWith(native, "poetry run python3 ")))
}
check_scenario_commands()
cat("All five scenarios, multiple dates/states, image overrides, fit reuse and local commands passed.\n")
