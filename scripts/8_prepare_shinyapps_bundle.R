#////////
#### Deploy Bundle ####
#////////

# Refresh the small shinyapps.io deployment bundle for the dashboard.
# hosted by Posit Cloud https://emjavan-pandemicsimexplorer.share.connect.posit.cloud/

library(readr)
library(dplyr)

cmd_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd_args, value = TRUE)
source_files <- vapply(sys.frames(), function(frame) {
  value <- get0("ofile", envir = frame, inherits = FALSE)
  if (is.null(value)) "" else as.character(value)[[1]]
}, character(1))
# source() keeps the actual file path; --file still names script 0 and may
# be relative to its original working directory, before it entered scripts/.
script_path <- if (any(nzchar(source_files))) {
  tail(source_files[nzchar(source_files)], 1)
} else if (length(file_arg)) sub("^--file=", "", file_arg[[1]]) else ""
script_dir <- if (nzchar(script_path)) dirname(normalizePath(script_path, mustWork = FALSE)) else getwd()

if (dir.exists(file.path(script_dir, "scripts"))) {
  repo_root <- normalizePath(script_dir, mustWork = TRUE)
} else if (dir.exists(file.path(script_dir, "..", "scripts"))) {
  repo_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
} else {
  repo_root <- normalizePath(getwd(), mustWork = TRUE)
}

pipeline_output_dir <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_WKLYFIT_TEST")
preview_states <- get0(
  "DASHBOARD_PREVIEW_STATES",
  ifnotfound = get0(
    "WEB_PREVIEW_STATES",
    ifnotfound = c("District-of-Columbia", "Connecticut", "Massachusetts")
  )
)
preview_scenarios <- get0(
  "DASHBOARD_PREVIEW_SCENARIOS",
  ifnotfound = get0(
    "SELECTED_RUN_SCENARIOS",
    ifnotfound = c("NONE", "VACCINE", "ANTIVIRAL", "NPI", "ALL_INTERVENTIONS")
  )
)
preview_output_subdirs <- get0(
  "DASHBOARD_PREVIEW_OUTPUT_SUBDIRS",
  ifnotfound = get0("DASHBOARD_PREVIEW_OUTPUT_SUBDIR", ifnotfound = c("WEB_OUTPUTS", "TACC_FILES"))
)
deploy_imports <- c(
  "shiny", "plotly", "bslib", "DT", "tidyverse", "duckdb", "arrow",
  "bsicons", "jsonlite", "DBI", "readr", "dplyr", "tidyr", "future", "promises", "cachem", "digest"
)

source_app <- file.path(repo_root, "scripts", "7b_sim_dashboard_app.R")
source_data <- file.path(repo_root, pipeline_output_dir)
bundle_dir <- file.path(repo_root, "deploy", "shinyapps", "PandemicSimExplorer")
bundle_data <- file.path(bundle_dir, "data")
source_master <- file.path(source_data, "metadata_master.csv")
bundle_master <- file.path(bundle_data, "metadata_master.csv")
source_features <- file.path(source_data, "scenario_features.parquet")
bundle_features <- file.path(bundle_data, "scenario_features.parquet")
bundle_deploy <- file.path(bundle_dir, "deploy.R")
bundle_description <- file.path(bundle_dir, "DESCRIPTION")
bundle_readme <- file.path(bundle_dir, "README.md")
bundle_lockfile <- file.path(bundle_dir, "renv.lock")
publisher_config_dir <- file.path(bundle_dir, ".posit", "publish")
existing_publisher_config <- function(directory) {
  # A deployment record binds a config to an existing hosted app. Reuse that
  # binding rather than creating a second publishing configuration on rebuild.
  records <- list.files(file.path(directory, "deployments"), pattern = "\\.toml$", full.names = TRUE)
  bound <- unique(unlist(lapply(records, function(path) {
    lines <- readLines(path, warn = FALSE)
    lines <- lines[grepl("^configuration_name\\s*=", lines)]
    sub("^configuration_name\\s*=\\s*['\"]([^'\"]+)['\"].*$", "\\1", lines)
  })))
  if (length(bound) > 1L) stop("Multiple Publisher deployments found; choose the intended deployment configuration before rebuilding.")
  if (length(bound)) {
    if (!grepl("^[A-Za-z0-9_.-]+$", bound) || !file.exists(file.path(directory, paste0(bound, ".toml")))) {
      stop("The existing Publisher deployment references a missing or invalid configuration: ", bound)
    }
    return(bound)
  }
  configs <- list.files(directory, pattern = "\\.toml$")
  if (length(configs) == 1L) return(sub("\\.toml$", "", configs))
  if (length(configs) > 1L) stop("Multiple unbound Publisher configurations found; select the existing deployment first.")
  "PandemicSimExplorer-3R9A"
}
publisher_config_name <- existing_publisher_config(publisher_config_dir)
publisher_config <- file.path(publisher_config_dir, paste0(publisher_config_name, ".toml"))

write_deploy_scaffold <- function() {
  writeLines(
    c(
      "# Run this after configuring your shinyapps.io account with rsconnect.",
      "",
      "app_files <- list.files(",
      "  \".\",",
      "  all.files = FALSE,",
      "  recursive = TRUE,",
      "  no.. = TRUE",
      ")",
      "app_files <- app_files[!grepl(\"(^|/)\\\\.DS_Store$\", app_files)]",
      "",
      "rsconnect::deployApp(",
      "  appDir = \".\",",
      "  appFiles = app_files,",
      "  appName = \"PandemicSimExplorer\",",
      "  appTitle = \"Pandemic Sim Explorer\"",
      ")"
    ),
    bundle_deploy
  )

  writeLines(
    c(
      "Type: Project",
      "Package: PandemicSimExplorer",
      "Title: Pandemic Simulation Explorer",
      "Version: 0.0.0.9000",
      "Imports:",
      paste0("    ", deploy_imports, collapse = ",\n")
    ),
    bundle_description
  )

  writeLines(
    c(
      "# Pandemic Sim Explorer shinyapps.io Bundle",
      "",
      "This folder is a small deployment bundle for shinyapps.io.",
      "",
      "For Posit Publisher / Connect Cloud, use:",
      "",
      "- `type = \"r-shiny\"`",
      "- `entrypoint = \"app.R\"`",
      "- R version `4.5.0`",
      "",
      "If the publisher configuration says `type = \"quarto-static\"` and",
      "`entrypoint = \"README.md\"`, the hosted page will show this README instead",
      "of running the dashboard.",
      "",
      "## Refreshing Data",
      "",
      "From the repository root:",
      "",
      "```r",
      "source(\"scripts/8_prepare_shinyapps_bundle.R\")",
      "```",
      "",
      "That copies the current dashboard app plus:",
      "",
      "- `<PIPELINE_OUTPUT_DIR>/metadata_master.csv`",
      "- `<PIPELINE_OUTPUT_DIR>/scenario_features.parquet`",
      "- `<PIPELINE_OUTPUT_DIR>/sim_data/`",
      "- `<PIPELINE_OUTPUT_DIR>/validation_fit_data/`",
      "- County boundaries downloaded for the selected states from TACC/PandemicExerciseTool",
      "- Existing county-by-age population inputs, stored in `data/map_population/`",
      "",
      "Preparation checks the entire deployment directory against a 5 GB budget.",
      "Each rebuild replaces the generated data directory with the selected states.",
      "",
      "## Deploying",
      "",
      "From this folder, run:",
      "",
      "```r",
      "source(\"deploy.R\")",
      "```"
    ),
    bundle_readme
  )
}

write_renv_lockfile <- function() {
  if (!requireNamespace("renv", quietly = TRUE)) {
    stop("Package renv is required to write the deploy renv.lock. Install it with install.packages('renv').")
  }

  old_python_enabled <- Sys.getenv("RENV_CONFIG_PYTHON_ENABLED", unset = NA_character_)
  if (is.na(old_python_enabled)) {
    on.exit(Sys.unsetenv("RENV_CONFIG_PYTHON_ENABLED"), add = TRUE)
  } else {
    on.exit(Sys.setenv(RENV_CONFIG_PYTHON_ENABLED = old_python_enabled), add = TRUE)
  }
  Sys.setenv(RENV_CONFIG_PYTHON_ENABLED = "FALSE")

  old_options <- options(renv.consent = TRUE)
  on.exit(options(old_options), add = TRUE)

  message("Snapshotting deploy R dependencies with renv: ", bundle_lockfile)
  renv::snapshot(
    project = bundle_dir,
    lockfile = bundle_lockfile,
    type = "implicit",
    prompt = FALSE,
    force = TRUE,
    packages = deploy_imports,
    repos = c(CRAN = "https://cloud.r-project.org")
  )
  message("Wrote deploy renv lockfile: ", bundle_lockfile)
}

write_publisher_config <- function() {
  dir.create(publisher_config_dir, recursive = TRUE, showWarnings = FALSE)
  if (file.exists(publisher_config)) {
    config_lines <- readLines(publisher_config, warn = FALSE)
    config_lines <- sub("^\\$schema\\s*=", '"$schema" =', config_lines)
    if (!any(grepl('"?/?data/scenario_features\\.parquet"?', config_lines))) {
      metadata_line <- grep('"?/?data/metadata_master\\.csv"?', config_lines)[1]
      if (!is.na(metadata_line)) {
        config_lines <- append(
          config_lines,
          '    "/data/scenario_features.parquet",',
          after = metadata_line
        )
      }
    }
    # Include the complete generated data directory. Narrow file lists from an
    # older deployment can otherwise omit newly added boundaries/populations.
    if (!any(grepl('^\\s*"/data/?",?\\s*$', config_lines))) {
      config_lines <- append(config_lines,
        '    "/data",',
        after = grep('^files = \\[', config_lines)[1])
    }
    writeLines(config_lines, publisher_config)
    message("Updated Posit Publisher config: ", publisher_config)
  } else {
    writeLines(
      c(
        "# Configuration file generated by Posit Publisher.",
        "# Please review and modify as needed. See the documentation for more options:",
        "# https://github.com/posit-dev/publisher/blob/main/docs/configuration.md",
        '"$schema" = "https://cdn.posit.co/publisher/schemas/posit-publishing-schema-v3.json"',
        'type = "r-shiny"',
        'entrypoint = "app.R"',
        'title = "PandemicSimExplorer"',
        "validate = true",
        'product_type = "connect_cloud"',
        "",
        "files = [",
        '    "/data",',
        '    "/app.R",',
        '    "/DESCRIPTION",',
        '    "/README.md",',
        '    "/renv.lock",',
        '    "/deploy.R",',
        '    "/data/metadata_master.csv",',
        '    "/data/scenario_features.parquet",',
        '    "/data/sim_data/**",',
        '    "/data/validation_fit_data/**",',
        '    "/data/dashboard_map_assets/**",',
        '    "/data/map_population/**",',
        paste0('    "/.posit/publish/', publisher_config_name, '.toml",'),
        '    "/.posit/publish/deployments/*.toml"',
        "]",
        "",
        "[r]",
        'version = "4.5.0"'
      ),
      publisher_config
    )
    message("Wrote Posit Publisher config: ", publisher_config)
  }
}

metadata_tag_chr <- function(tags_json, tag) {
  tags <- tryCatch(
    jsonlite::fromJSON(tags_json, simplifyVector = FALSE),
    error = function(e) NULL
  )
  value <- if (is.null(tags)) NULL else tags[[tag]]
  if (is.null(value) || length(value) == 0) NA_character_ else as.character(value[[1]])
}


if (!file.exists(source_master)) {
  stop("No metadata master found at ", source_master, ". Run 7a first.")
}
if (!file.exists(source_features)) {
  stop("No scenario feature parquet found at ", source_features, ". Run 7a first.")
}
metadata <- readr::read_csv(
  source_master,
  col_types = readr::cols(
    validation_json = readr::col_character(),
    validation_fit_data_file = readr::col_character(),
    .default = readr::col_guess()
  ),
  show_col_types = FALSE
)
metadata_preview <- metadata %>%
  dplyr::mutate(
    scenario_label = vapply(.data$metadata_tags_json, metadata_tag_chr, character(1), tag = "scenario_label")
  )

preview_output_subdirs <- as.character(preview_output_subdirs)
preview_output_subdirs <- preview_output_subdirs[nzchar(preview_output_subdirs)]
if (length(preview_output_subdirs) > 0 && "file_path" %in% names(metadata_preview)) {
  reused_fit_outputs <- get0("REUSED_FIT_OUTPUTS", ifnotfound = NULL)
  reuse_manifest <- file.path(source_data, "reused_fit_outputs.csv")
  if (is.null(reused_fit_outputs) && file.exists(reuse_manifest)) {
    reused_fit_outputs <- readr::read_csv(reuse_manifest, show_col_types = FALSE)
  }
  reused_paths <- if (is.null(reused_fit_outputs)) character() else reused_fit_outputs$metadata_file
  metadata_preview <- metadata_preview %>%
    dplyr::filter(.data$file_path %in% reused_paths | Reduce(
      `|`,
      lapply(preview_output_subdirs, grepl, x = .data$file_path, fixed = TRUE)
    ))
  if (length(reused_paths)) {
    metadata_preview <- metadata_preview %>%
      dplyr::filter(!.data$scenario_label %in% reused_fit_outputs$scenario |
        .data$file_path %in% reused_paths)
  }
}

# An empty state selection bundles every state available from the chosen source.
if (length(preview_states) == 0L) {
  preview_states <- sort(unique(metadata_preview$geo_region[!is.na(metadata_preview$geo_region)]))
}
metadata_preview <- metadata_preview %>%
  dplyr::filter(.data$geo_region %in% preview_states)

if (nrow(metadata_preview) == 0) {
  stop(
    "No metadata rows found for preview states: ",
    paste(preview_states, collapse = ", ")
  )
}

scenario_lookup <- tibble::tribble(
  ~scenario_label,
  "NONE",
  "VACCINE",
  "ANTIVIRAL",
  "NPI",
  "ALL_INTERVENTIONS"
)
unknown_preview_scenarios <- setdiff(preview_scenarios, scenario_lookup$scenario_label)
if (length(unknown_preview_scenarios) > 0) {
  stop("Unknown dashboard preview scenario label(s): ", paste(unknown_preview_scenarios, collapse = ", "))
}
expected_scenarios <- tibble::tibble(scenario_label = preview_scenarios)

metadata_preview <- metadata_preview %>%
  dplyr::mutate(created_at_utc = as.POSIXct(.data$created_at_utc, tz = "UTC")) %>%
  dplyr::semi_join(expected_scenarios, by = "scenario_label") %>%
  dplyr::arrange(.data$geo_region, .data$scenario_label, .data$scenario_hash, dplyr::desc(.data$created_at_utc)) %>%
  dplyr::group_by(.data$geo_region, .data$scenario_label, .data$scenario_hash) %>%
  dplyr::slice(1) %>%
  dplyr::ungroup()

if ("validation_fit_data_file" %in% names(metadata_preview)) {
  metadata_preview <- metadata_preview %>%
    dplyr::mutate(
      validation_fit_data_file = as.character(.data$validation_fit_data_file),
      validation_fit_data_file = dplyr::if_else(
        is.na(.data$validation_fit_data_file) | !nzchar(.data$validation_fit_data_file),
        .data$validation_fit_data_file,
        file.path("validation_fit_data", basename(.data$validation_fit_data_file))
      )
    )
}

expected_preview_rows <- tidyr::crossing(
  geo_region = preview_states,
  expected_scenarios
)
missing_preview_rows <- expected_preview_rows %>%
  dplyr::anti_join(
    metadata_preview,
    by = c("geo_region", "scenario_label")
  )
if (nrow(missing_preview_rows) > 0) {
  stop("Missing one or more preview dashboard rows. Run the TACC or local web preview simulator commands and 7a first.")
}

# Check source files and planned size before replacing the previous bundle data.
download_county_map_assets <- function(states, download = utils::download.file) {
  # Stage deployment-only assets outside simulator inputs. Pin the revision so
  # rebuilding a bundle does not silently change its county geometry.
  revision <- "12242450febc494f30616a191f743ca6f1638cd6"
  base_url <- paste0("https://raw.githubusercontent.com/TACC/PandemicExerciseTool/", revision, "/")
  staging <- tempfile("dashboard-map-assets-")
  dir.create(file.path(staging, "map_boundaries"), recursive = TRUE)
  completed <- FALSE
  on.exit(if (!completed) unlink(staging, recursive = TRUE), add = TRUE)
  fetch <- function(remote, local) {
    message("Downloading deployment map asset: ", basename(local))
    status <- tryCatch(download(paste0(base_url, remote), local, mode = "wb", quiet = TRUE),
      error = function(e) stop("Could not download deployment map asset ", remote, ": ", conditionMessage(e)))
    if (!identical(as.integer(status), 0L) || !file.exists(local) || file.info(local)$size == 0) {
      stop("Could not download deployment map asset: ", remote)
    }
  }
  for (state in unique(states)) {
    name <- paste0(state, "_counties_2023.geojson")
    destination <- file.path(staging, "map_boundaries", name)
    fetch(paste0("frontend/assets/map_boundaries/", utils::URLencode(name, reserved = TRUE)), destination)
    geometry <- jsonlite::fromJSON(destination, simplifyVector = FALSE)
    if (!identical(geometry$type, "FeatureCollection") || !length(geometry$features)) {
      stop("Invalid county boundary asset for ", state)
    }
  }
  fetch("LICENSE", file.path(staging, "LICENSE"))
  writeLines(c("# County map boundaries", "",
    paste0("Source: https://github.com/TACC/PandemicExerciseTool/tree/", revision,
           "/frontend/assets/map_boundaries"),
    paste0("Pinned revision: ", revision),
    "Downloaded only for selected deployment states. Source license is in LICENSE.",
    "Population inputs come from the simulator's existing county-by-age CSVs."),
    file.path(staging, "README.md"))
  completed <- TRUE
  staging
}
map_source <- download_county_map_assets(unique(metadata_preview$geo_region))
source_batches <- unique(file.path(source_data, "sim_data", metadata_preview$scenario_hash,
                                  metadata_preview$batch_num))
missing_batches <- source_batches[!dir.exists(source_batches)]
if (length(missing_batches)) stop("Missing preview Parquet directories: ", paste(missing_batches, collapse = ", "))
source_boundaries <- file.path(map_source, "map_boundaries",
  paste0(unique(metadata_preview$geo_region), "_counties_2023.geojson"))
if (any(!file.exists(source_boundaries))) stop("Missing county boundary asset(s): ",
  paste(source_boundaries[!file.exists(source_boundaries)], collapse = ", "))
source_populations <- vapply(seq_len(nrow(metadata_preview)), function(i) {
  recorded <- metadata_preview$data_population[[i]]
  if (is.na(recorded) || !nzchar(recorded)) stop("No population input for ", metadata_preview$geo_region[[i]])
  candidates <- c(recorded, file.path(repo_root, recorded),
    file.path(repo_root, "data", metadata_preview$geo_region[[i]], basename(recorded)))
  source <- candidates[file.exists(candidates)][1]
  if (is.na(source)) stop("Missing existing population input: ", recorded)
  source
}, character(1))
planned_data_files <- unique(c(source_master, source_features, source_boundaries, source_populations,
  file.path(map_source, c("README.md", "LICENSE")),
  unlist(lapply(source_batches, list.files, recursive = TRUE, full.names = TRUE, all.files = TRUE)),
  list.files(file.path(source_data, "validation_fit_data"), recursive = TRUE, full.names = TRUE, all.files = TRUE)))
# Prevent a source path inside the generated data tree from being moved away.
if (any(startsWith(normalizePath(planned_data_files, mustWork = TRUE),
                   paste0(normalizePath(bundle_data, mustWork = FALSE), "/")))) {
  stop("Pipeline source data must be outside the generated deployment data directory.")
}
bundle_limit <- get0("DASHBOARD_MAX_BUNDLE_BYTES", ifnotfound = 5e9)
if (length(bundle_limit) != 1L || !is.finite(bundle_limit) || bundle_limit <= 0) {
  stop("DASHBOARD_MAX_BUNDLE_BYTES must be positive and finite.")
}
existing_files <- list.files(bundle_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
existing_files <- existing_files[!startsWith(existing_files, paste0(bundle_data, "/"))]
# Counting the complete source metadata CSV is a conservative upper estimate.
planned_bytes <- sum(file.info(unique(c(planned_data_files, existing_files, source_app)))$size, na.rm = TRUE)
message("Deployment states: ", paste(sort(unique(metadata_preview$geo_region)), collapse = ", "))
message(sprintf("Estimated deployment directory: %.3f GB / %.3f GB", planned_bytes / 1e9, bundle_limit / 1e9))
if (planned_bytes > bundle_limit) {
  stop(sprintf(paste0("Selected deployment data exceeds the budget: %.3f GB > %.3f GB. ",
    "Choose fewer selected_states in the pipeline input file (or DASHBOARD_PREVIEW_STATES standalone). ",
    "Previous deployment data has not been moved."), planned_bytes / 1e9, bundle_limit / 1e9))
}

dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)
bundle_app <- file.path(bundle_dir, "app.R")
if (!file.exists(source_app)) stop("Dashboard source app not found: ", source_app)
if (!file.copy(source_app, bundle_app, overwrite = TRUE)) {
  stop("Could not copy dashboard app from ", source_app, " to ", bundle_app)
}
app_lines <- readLines(bundle_app, warn = FALSE)
app_lines <- sub(
  '^DASHBOARD_DATA_DIR <- ".*"$',
  'DASHBOARD_DATA_DIR <- "data"',
  app_lines
)
writeLines(app_lines, bundle_app)
write_deploy_scaffold()
write_renv_lockfile()
write_publisher_config()


# Always replace generated data in this same deployment folder. Source pipeline
# outputs and existing .posit publishing settings stay outside this data tree.
if (dir.exists(bundle_data)) {
  unlink(bundle_data, recursive = TRUE)
  if (dir.exists(bundle_data)) stop("Could not replace generated deployment data: ", bundle_data)
}
dir.create(bundle_data, recursive = TRUE, showWarnings = FALSE)

# Bundle only selected states' downloaded boundaries and existing population inputs.
# The recorded paths can refer to TACC; use their matching local data/ files.
map_dest <- file.path(bundle_data, "dashboard_map_assets")
dir.create(file.path(map_dest, "map_boundaries"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(bundle_data, "map_population"), recursive = TRUE, showWarnings = FALSE)
for (state in unique(metadata_preview$geo_region)) {
  name <- paste0(state, "_counties_2023.geojson")
  source <- file.path(map_source, "map_boundaries", name)
  if (!file.exists(source)) stop("Missing county boundary asset: ", source)
  if (!file.copy(source, file.path(map_dest, "map_boundaries", name), overwrite = TRUE)) {
    stop("Could not copy county boundary asset: ", source)
  }
}
file.copy(file.path(map_source, c("README.md", "LICENSE")), map_dest, overwrite = TRUE)
for (i in seq_len(nrow(metadata_preview))) {
  recorded <- metadata_preview$data_population[[i]]
  source <- source_populations[[i]]
  destination <- file.path("map_population", basename(recorded))
  if (!file.copy(source, file.path(bundle_data, destination), overwrite = TRUE)) {
    stop("Could not copy population input: ", source)
  }
  metadata_preview$data_population[[i]] <- destination
}

readr::write_csv(metadata_preview, bundle_master)
if (!file.copy(source_features, bundle_features, overwrite = TRUE)) stop("Could not copy scenario features.")
message("Copied scenario feature parquet: ", bundle_features)

dir.create(file.path(bundle_data, "sim_data"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(bundle_data, "validation_fit_data"), recursive = TRUE, showWarnings = FALSE)
missing_parquet <- character()
for (i in seq_len(nrow(metadata_preview))) {
  source_batch_dir <- file.path(
    source_data,
    "sim_data",
    metadata_preview$scenario_hash[[i]],
    metadata_preview$batch_num[[i]]
  )
  if (!dir.exists(source_batch_dir)) {
    missing_parquet <- c(missing_parquet, source_batch_dir)
    next
  }

  bundle_hash_dir <- file.path(
    bundle_data,
    "sim_data",
    metadata_preview$scenario_hash[[i]]
  )
  dir.create(bundle_hash_dir, recursive = TRUE, showWarnings = FALSE)
  if (!file.copy(source_batch_dir, bundle_hash_dir, recursive = TRUE)) {
    stop("Could not copy selected simulation data: ", source_batch_dir)
  }
}
if (length(missing_parquet) > 0) {
  stop("Missing preview Parquet directories: ", paste(missing_parquet, collapse = ", "))
}
validation_copied <- file.copy(
  list.files(file.path(source_data, "validation_fit_data"), full.names = TRUE),
  file.path(bundle_data, "validation_fit_data"),
  recursive = TRUE,
  overwrite = TRUE
)
if (!all(validation_copied)) stop("Could not copy validation data.")

# Verify the entire finished directory, including hidden files and deployment configuration.
# Use a conservative decimal 5 GB budget; this also fits a 5 GiB upload limit.
bundle_bytes <- sum(file.info(list.files(bundle_dir, recursive = TRUE, full.names = TRUE,
                                         all.files = TRUE, no.. = TRUE))$size, na.rm = TRUE)
if (bundle_bytes > bundle_limit) {
  stop(sprintf(paste0("Deployment directory is %.3f GB; budget is %.3f GB. ",
    "Choose fewer selected_states (or DASHBOARD_PREVIEW_STATES standalone) before deploying. ",
    "Original pipeline outputs do not need to be removed."), bundle_bytes / 1e9, bundle_limit / 1e9))
}
unlink(map_source, recursive = TRUE)
message(sprintf("Entire deployment directory: %.3f GB", bundle_bytes / 1e9))
message(
  "Refreshed shinyapps.io bundle for ",
  paste(preview_states, collapse = ", "),
  " and scenarios ",
  paste(preview_scenarios, collapse = ", "),
  ": ",
  bundle_dir
)
