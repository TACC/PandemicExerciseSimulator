#////////
#### Script Overview ####
#////////
# Post-job ETL: finds all metadata_batch-*.json files under SEARCH_ROOT and
# ingests them into:
#   1. metadata_master.csv  — flat metadata table, deduplication key
#   2. Parquet store        — network + node time series (columnar, compressed)
#   3. MongoDB              — metadata documents for the frontend (optional)
#
# Run after a batch of TACC jobs finishes. Re-running is safe: existing
# (scenario_hash, batch_num) pairs are skipped everywhere.
#
# Design notes:
#   - Disease/travel model parameters are stored as namespaced JSON strings,
#     not individual columns, to avoid name collisions across model types
#     (e.g. sigma has different meanings in SEAITRD vs other models).
#   - Each intervention type gets an explicit _used boolean flag.
#   - Parquet compression (zstd) handles sparse simulation data automatically;
#     columns of zeros cost almost nothing in file size.
#   - For very large sweeps (250+ nodes × 250+ realizations) the node ingest
#     reads all county files in one pass via arrow — no full in-memory load.
#////////
library(jsonlite)
library(tidyverse)
library(arrow)

#### Configuration #############################################################
pipeline_search_root <- get0("pipeline_output_root", ifnotfound = NA_character_)
if (is.na(pipeline_search_root) || !nzchar(pipeline_search_root)) {
  pipeline_output_dir <- get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_WKLYFIT_TEST")
  pipeline_search_root <- if (grepl("^/", pipeline_output_dir)) {
    pipeline_output_dir
  } else {
    file.path(here::here(), "..", pipeline_output_dir)
  }
}
SEARCH_ROOT  <- normalizePath(pipeline_search_root, mustWork = FALSE)
MASTER_CSV   <- file.path(SEARCH_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(SEARCH_ROOT, "sim_data")   # partitioned: <hash>/<batch>/
FEATURES_PARQUET <- file.path(SEARCH_ROOT, "scenario_features.parquet")

# Set TRUE once a local MongoDB instance is running (install.packages("mongolite"))
MONGO_ENABLED    <- FALSE
MONGO_URI        <- "mongodb://localhost:27017"
MONGO_DB         <- "pandemic_sim"
MONGO_COLLECTION <- "batches"

#### Helper Funs ###############################################################
calc_sim_completion <- function(attempt_realization_count, complete_realization_count) {
  dplyr::case_when(
    is.na(attempt_realization_count) ~ NA_real_,
    attempt_realization_count <= 0 ~ NA_real_,
    is.na(complete_realization_count) ~ 0,
    TRUE ~ pmin(complete_realization_count / attempt_realization_count, 1)
  )
}

vec_to_str <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  paste(unlist(x), collapse = "|")
}

to_json_str <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  unclass(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))
}

safe_get <- function(x, ...) {
  tryCatch(purrr::pluck(x, ...), error = function(e) NULL)
}

resolve_search_root_path <- function(path) {
  if (is.null(path) || length(path) == 0 || is.na(path) || !nzchar(path)) {
    return(NA_character_)
  }
  if (grepl("^/", path)) {
    return(normalizePath(path, mustWork = FALSE))
  }
  normalizePath(file.path(SEARCH_ROOT, path), mustWork = FALSE)
}

feature_value_type <- function(x) {
  if (is.null(x)) return("null")
  if (is.logical(x)) return("logical")
  if (is.numeric(x)) return("numeric")
  if (inherits(x, "Date") || inherits(x, "POSIXt")) return("date")
  if (is.character(x)) return("character")
  if (is.list(x)) return("object")
  typeof(x)
}

canonicalize_json_value <- function(x) {
  if (is.data.frame(x)) {
    return(as.data.frame(lapply(x, canonicalize_json_value), stringsAsFactors = FALSE))
  }

  if (is.list(x)) {
    names_x <- names(x)
    if (!is.null(names_x) && any(nzchar(names_x))) {
      x <- x[sort(names_x)]
    }
    return(lapply(x, canonicalize_json_value))
  }

  x
}

feature_value_display <- function(x) {
  if (is.null(x)) return("null")
  if (length(x) == 0) return("[]")
  if (is.atomic(x) && length(x) == 1) return(as.character(x))
  unclass(jsonlite::toJSON(canonicalize_json_value(x), auto_unbox = TRUE, null = "null"))
}

flatten_feature_list <- function(x, prefix = character(0)) {
  if (is.null(x)) {
    return(tibble(
      feature_path = paste(prefix, collapse = "."),
      feature_value = "null",
      feature_type = "null"
    ))
  }

  if (is.list(x) && !is.data.frame(x)) {
    names_x <- names(x)

    if (length(x) == 0) {
      return(tibble(
        feature_path = paste(prefix, collapse = "."),
        feature_value = "[]",
        feature_type = "array"
      ))
    }

    if (is.null(names_x) || all(!nzchar(names_x))) {
      return(tibble(
        feature_path = paste(prefix, collapse = "."),
        feature_value = feature_value_display(x),
        feature_type = "array"
      ))
    }

    return(purrr::imap_dfr(
      x,
      function(value, name) flatten_feature_list(value, c(prefix, name))
    ))
  }

  tibble(
    feature_path = paste(prefix, collapse = "."),
    feature_value = feature_value_display(x),
    feature_type = if (length(x) > 1) "array" else feature_value_type(x)
  )
}

write_scenario_features <- function(master_df) {
  if (is.null(master_df) || nrow(master_df) == 0) {
    arrow::write_parquet(
      tibble(
        scenario_hash = character(),
        geo_region = character(),
        feature_path = character(),
        feature_group = character(),
        feature_value = character(),
        feature_type = character()
      ),
      FEATURES_PARQUET,
      compression = "zstd"
    )
    return(invisible(NULL))
  }

  excluded_roots <- c(
    "batch_num",
    "created_at_utc",
    "file_path",
    "git_info",
    "output_dir_path",
    "realization_indices",
    "scenario_hash"
  )

  scenario_sources <- master_df %>%
    dplyr::filter(!is.na(.data$scenario_hash), nzchar(.data$scenario_hash), file.exists(.data$file_path)) %>%
    dplyr::arrange(dplyr::desc(.data$created_at_utc)) %>%
    dplyr::group_by(.data$scenario_hash) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::select("scenario_hash", "geo_region", "file_path")

  features <- purrr::pmap_dfr(
    scenario_sources,
    function(scenario_hash, geo_region, file_path) {
      tryCatch(
        {
          jsonlite::read_json(file_path) %>%
            flatten_feature_list() %>%
            dplyr::filter(
              nzchar(.data$feature_path),
              !stringr::word(.data$feature_path, 1, sep = stringr::fixed(".")) %in% excluded_roots
            ) %>%
            dplyr::mutate(
              scenario_hash = scenario_hash,
              geo_region = geo_region,
              feature_group = stringr::word(.data$feature_path, 1, sep = stringr::fixed("."))
            ) %>%
            dplyr::select(
              "scenario_hash",
              "geo_region",
              "feature_path",
              "feature_group",
              "feature_value",
              "feature_type"
            )
        },
        error = function(e) {
          warning(sprintf("Failed to flatten scenario features for %s: %s", file_path, e$message))
          tibble()
        }
      )
    }
  )

  arrow::write_parquet(features, FEATURES_PARQUET, compression = "zstd")
  message(sprintf("Scenario feature parquet: %s  (%d row(s))", FEATURES_PARQUET, nrow(features)))
  invisible(features)
}

get_batch_file_sizes <- function(scenario_hash, batch_num) {
  batch_dir <- file.path(PARQUET_ROOT, scenario_hash, batch_num)
  
  network_path <- file.path(batch_dir, "network.parquet")
  nodes_path   <- file.path(batch_dir, "nodes.parquet")
  times_path   <- file.path(batch_dir, "simulation_times.parquet")
  
  network_bytes <- if (file.exists(network_path)) file.info(network_path)$size else NA_real_
  nodes_bytes   <- if (file.exists(nodes_path))   file.info(nodes_path)$size else NA_real_
  times_bytes   <- if (file.exists(times_path))   file.info(times_path)$size else NA_real_
  
  tibble(
    network_parquet_bytes          = network_bytes,
    nodes_parquet_bytes            = nodes_bytes,
    simulation_times_parquet_bytes = times_bytes,
    total_parquet_bytes            = sum(c(network_bytes, nodes_bytes, times_bytes), na.rm = TRUE)
  )
}

format_bytes <- function(x) {
  dplyr::case_when(
    is.na(x) ~ NA_character_,
    x < 1024 ~ paste0(x, " B"),
    x < 1024^2 ~ paste0(round(x / 1024, 1), " KB"),
    x < 1024^3 ~ paste0(round(x / 1024^2, 1), " MB"),
    TRUE ~ paste0(round(x / 1024^3, 2), " GB")
  )
}

# ── Simulation times ──────────────────────────────────────────────────────────
parse_sim_times <- function(metadata_path, batch_num) {
  sim_file <- file.path(
    dirname(metadata_path),
    paste0("simulation_times_batch-", batch_num, ".csv")
  )
  if (!file.exists(sim_file)) {
    return(list(complete_realization_count = NA_integer_,
                mean_run_time_seconds      = NA_real_))
  }
  times <- read_csv(sim_file, show_col_types = FALSE)
  list(
    complete_realization_count = nrow(times),
    mean_run_time_seconds      = mean(times$time_seconds, na.rm = TRUE)
  )
}

# ── Metadata parser ───────────────────────────────────────────────────────────
parse_metadata <- function(path) {
  m <- jsonlite::read_json(path)

  npi_list   <- m$non_pharma_interventions$runtime_attributes$npis %||% list()
  npi_used   <- length(npi_list) > 0
  npi_ids    <- vec_to_str(map_chr(npi_list, ~ .x$identity %||% NA_character_))

  vax        <- m$vaccine_model   %||% list()
  vax_id     <- vax$identity
  av         <- m$antiviral_model %||% list()
  av_id      <- av$identity

  dm         <- m$disease_model %||% list()
  tm         <- m$travel_model  %||% list()
  tags       <- m$metadata_tags %||% list()
  sim_times  <- parse_sim_times(path, m$batch_num %||% "")
  
  attempt_realization_count  <- safe_get(m, "realization_indices", "count") %||% NA_integer_
  complete_realization_count <- sim_times$complete_realization_count
  sim_completion             <- calc_sim_completion(
    attempt_realization_count,
    complete_realization_count
  )
  
  sizes      <- get_batch_file_sizes(
    scenario_hash = m$scenario_hash %||% NA_character_,
    batch_num     = m$batch_num     %||% NA_character_
  )

  tibble(
    file_path                  = path,
    created_at_utc             = as.POSIXct(m$created_at_utc %||% NA_character_, tz = "UTC"),
    scenario_hash              = m$scenario_hash   %||% NA_character_,
    batch_num                  = m$batch_num       %||% NA_character_,
    output_dir_path            = m$output_dir_path %||% NA_character_,
    metadata_creator           = tags$creator   %||% NA_character_,
    metadata_disease           = vec_to_str(tags$disease),
    metadata_sim_day_0         = tags$sim_day_0 %||% NA_character_,
    metadata_notes             = vec_to_str(tags$notes),
    metadata_tags_json         = to_json_str(tags),
    validation_used            = !is.null(tags$validation),
    validation_json            = to_json_str(tags$validation),
    validation_fit_data_file   = resolve_search_root_path(safe_get(tags, "validation", "fit_data_file")),

    realization_min            = safe_get(m, "realization_indices", "min")   %||% NA_integer_,
    realization_max            = safe_get(m, "realization_indices", "max")   %||% NA_integer_,
    attempt_realization_count  = attempt_realization_count,
    complete_realization_count = complete_realization_count,
    sim_completion             = sim_completion,
    mean_run_time_seconds      = sim_times$mean_run_time_seconds,
    
    network_parquet_bytes      = sizes$network_parquet_bytes,
    nodes_parquet_bytes        = sizes$nodes_parquet_bytes,
    sim_times_parquet_bytes    = sizes$simulation_times_parquet_bytes,
    total_parquet_file_size    = format_bytes(sizes$total_parquet_bytes),

    data_population            = safe_get(m, "data", "population")       %||% NA_character_,
    data_contact               = safe_get(m, "data", "contact")          %||% NA_character_,
    data_flow                  = safe_get(m, "data", "flow")             %||% NA_character_,
    data_high_risk_ratios      = safe_get(m, "data", "high_risk_ratios") %||% NA_character_,

    # Model parameters stored as namespaced JSON — no column-level name collisions
    disease_identity           = dm$identity %||% NA_character_,
    disease_params_json        = to_json_str(dm$parameters),
    disease_R0                 = as.numeric(safe_get(m, "disease_model", "parameters", "R0") %||% NA_real_ ),
    disease_runtime_json       = to_json_str(dm$runtime_attributes),
    travel_identity            = tm$identity %||% NA_character_,
    travel_params_json         = to_json_str(tm$parameters),
    travel_runtime_json        = to_json_str(tm$runtime_attributes),

    vaccine_used               = !is.null(vax_id),
    vaccine_identity           = vax_id %||% NA_character_,
    vaccine_params_json        = to_json_str(vax$parameters),
    vaccine_runtime_json       = to_json_str(vax$runtime_attributes),

    antiviral_used             = !is.null(av_id),
    antiviral_identity         = av_id  %||% NA_character_,
    antiviral_params_json      = to_json_str(av$parameters),
    antiviral_runtime_json     = to_json_str(av$runtime_attributes),

    npi_used                   = npi_used,
    npi_count                  = length(npi_list),
    npi_identities             = npi_ids,
    npi_params_json            = to_json_str(npi_list),

    initial_exposed_json      = to_json_str(m$initial_exposed),
    sim_days                   = safe_get(m, "cli_args", "days")     %||% NA_integer_,
    sim_loglevel               = safe_get(m, "cli_args", "loglevel") %||% NA_character_,

    geo_region                 = safe_get(m, "geo", "region")     %||% NA_character_,
    geo_level                  = safe_get(m, "geo", "level")      %||% NA_character_,
    geo_node_count             = safe_get(m, "geo", "node_count") %||% NA_integer_,

    age_num_groups             = safe_get(m, "age_structure", "num_groups") %||% NA_integer_,
    age_labels                 = vec_to_str(safe_get(m, "age_structure", "labels")),

    git_commit                 = safe_get(m, "git_info", "git_commit") %||% NA_character_,
    git_branch                 = safe_get(m, "git_info", "git_branch") %||% NA_character_,
    git_dirty                  = safe_get(m, "git_info", "git_dirty")  %||% NA,

    random_base_seed           = as.character(safe_get(m, "random_seed", "base_seed") %||% NA),
    random_seed_strategy       = safe_get(m, "random_seed", "seed_strategy") %||% NA_character_
  )
}

# ── Parquet ingest: network ───────────────────────────────────────────────────
# Reads network_batch-<batch_num>.csv and writes:
#   sim_data/<scenario_hash>/<batch_num>/network.parquet

ingest_network <- function(metadata_dir, scenario_hash, batch_num) {
  csv_path <- file.path(metadata_dir,
                        paste0("network_batch-", batch_num, ".csv"))
  if (!file.exists(csv_path)) {
    message(sprintf("  [network] no CSV found for batch %s — skipping", batch_num))
    return(invisible(NULL))
  }

  out_dir <- file.path(PARQUET_ROOT, scenario_hash, batch_num)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  read_csv(csv_path, show_col_types = FALSE) %>%
    mutate(scenario_hash = scenario_hash, batch_num = batch_num) %>%
    write_parquet(file.path(out_dir, "network.parquet"), compression = "zstd")

  message(sprintf("  [network] wrote %s", file.path(out_dir, "network.parquet")))
}

# ── Parquet ingest: nodes ─────────────────────────────────────────────────────
# Reads all node_<fips>_batch-<batch_num>.csv files in metadata_dir, binds
# them, and writes:
#   sim_data/<scenario_hash>/<batch_num>/nodes.parquet
#
# Uses arrow::open_dataset for streaming reads — avoids loading all county
# files into R memory at once, which matters at scale (250+ nodes × 250+ sims).

ingest_nodes <- function(metadata_dir, scenario_hash, batch_num) {
  node_files <- list.files(
    metadata_dir,
    pattern    = paste0("^node_.*_batch-", batch_num, "\\.csv$"),
    full.names = TRUE
  )
  if (length(node_files) == 0) {
    message(sprintf("  [nodes]   no node CSVs found for batch %s — skipping", batch_num))
    return(invisible(NULL))
  }

  out_dir  <- file.path(PARQUET_ROOT, scenario_hash, batch_num)
  out_path <- file.path(out_dir, "nodes.parquet")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  arrow::open_csv_dataset(node_files) %>%
    mutate(scenario_hash = scenario_hash, batch_num = batch_num) %>%
    write_parquet(out_path, compression = "zstd")

  message(sprintf("  [nodes]   wrote %s (%d file(s))",
                  out_path, length(node_files)))
}

# ── Parquet ingest: simulation times ──────────────────────────────────────────
# Reads simulation_times_batch-<batch_num>.csv and writes:
#   sim_data/<scenario_hash>/<batch_num>/simulation_times.parquet

ingest_sim_times <- function(metadata_dir, scenario_hash, batch_num) {
  csv_path <- file.path(
    metadata_dir,
    paste0("simulation_times_batch-", batch_num, ".csv")
  )
  
  if (!file.exists(csv_path)) {
    message(sprintf("  [times]   no timing CSV found for batch %s — skipping", batch_num))
    return(invisible(NULL))
  }
  
  out_dir  <- file.path(PARQUET_ROOT, scenario_hash, batch_num)
  out_path <- file.path(out_dir, "simulation_times.parquet")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  
  read_csv(csv_path, show_col_types = FALSE) %>%
    mutate(
      scenario_hash = scenario_hash,
      batch_num = batch_num
    ) %>%
    write_parquet(out_path, compression = "zstd")
  
  message(sprintf("  [times]   wrote %s", out_path))
}

# ── MongoDB write ─────────────────────────────────────────────────────────────
# Upserts the raw metadata document + computed fields into MongoDB.
# Only called when MONGO_ENABLED = TRUE.

write_to_mongo <- function(raw_json_path, row, mongo_col) {
  doc <- jsonlite::read_json(raw_json_path)

  # Append computed fields that the frontend cares about
  doc$vaccine_used               <- row$vaccine_used
  doc$antiviral_used             <- row$antiviral_used
  doc$npi_used                   <- row$npi_used
  doc$npi_count                  <- row$npi_count
  doc$attempt_realization_count  <- row$attempt_realization_count
  doc$complete_realization_count <- row$complete_realization_count
  doc$sim_completion             <- row$sim_completion
  doc$mean_run_time_seconds      <- row$mean_run_time_seconds
  doc$parquet_path               <- file.path(PARQUET_ROOT,
                                              row$scenario_hash,
                                              row$batch_num)

  mongo_col$update(
    query  = sprintf('{"scenario_hash":"%s","batch_num":"%s"}',
                     row$scenario_hash, row$batch_num),
    update = sprintf('{"$set":%s}',
                     jsonlite::toJSON(doc, auto_unbox = TRUE, null = "null")),
    upsert = TRUE
  )
}

# ── Export utility ────────────────────────────────────────────────────────────
# Expands Parquet back to CSVs — call this to reconstruct the original file
# format for a given batch. All zeros (compressed away in Parquet) are
# fully restored in the output.
#
# Usage:
#   export_batch_csv("019d6539-7fd6-719e-9a6f-935ca438ab70", "/tmp/export")

export_batch_csv <- function(batch_num, output_dir,
                             parquet_root = PARQUET_ROOT) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Helper: export one parquet file to CSV via DuckDB
  export_one <- function(type) {
    parquet_glob <- file.path(parquet_root, "*", batch_num, paste0(type, ".parquet"))
    matches <- Sys.glob(parquet_glob)
    if (length(matches) == 0) {
      message(sprintf("  [export] no %s.parquet for batch %s", type, batch_num))
      return(invisible(NULL))
    }
    
    out_csv <- file.path(output_dir, paste0(type, "_batch-", batch_num, ".csv"))
    
    order_clause <- dplyr::case_when(
      type == "nodes" ~ "fips_id, sim_id, day",
      type == "network" ~ "sim_id, day",
      type == "simulation_times" ~ "sim_id",
      TRUE ~ NULL
    )
    
    sql <- if (!is.null(order_clause)) {
      sprintf(
        "COPY (
         SELECT * EXCLUDE (scenario_hash, batch_num)
         FROM read_parquet('%s')
         ORDER BY %s
       ) TO '%s' (HEADER, DELIMITER ',')",
        matches[[1]], order_clause, out_csv
      )
    } else {
      sprintf(
        "COPY (
         SELECT * EXCLUDE (scenario_hash, batch_num)
         FROM read_parquet('%s')
       ) TO '%s' (HEADER, DELIMITER ',')",
        matches[[1]], out_csv
      )
    }
    
    DBI::dbExecute(con, sql)
    message(sprintf("  [export] wrote %s", out_csv))
  }
  
  export_one("network")
  export_one("nodes")
  export_one("simulation_times")
  invisible(output_dir)
}

#### Master CSV schema #########################################################
# Explicit column types prevent read_csv() from inferring the wrong type when
# reading the master CSV back in — e.g. a numeric seed being inferred as
# <double> when parse_metadata() always produces <character>.
MASTER_COL_TYPES <- cols(
  file_path                  = col_character(),
  created_at_utc             = col_datetime(format = ""),
  scenario_hash              = col_character(),
  batch_num                  = col_character(),
  output_dir_path            = col_character(),
  metadata_creator           = col_character(),
  metadata_disease           = col_character(),
  metadata_sim_day_0         = col_character(),
  metadata_notes             = col_character(),
  metadata_tags_json         = col_character(),
  validation_used            = col_logical(),
  validation_json            = col_character(),
  validation_fit_data_file   = col_character(),

  realization_min            = col_integer(),
  realization_max            = col_integer(),
  attempt_realization_count  = col_integer(),
  complete_realization_count = col_integer(),
  sim_completion             = col_double(),
  mean_run_time_seconds      = col_double(),
  
  network_parquet_bytes   = col_double(),
  nodes_parquet_bytes     = col_double(),
  sim_times_parquet_bytes = col_double(),
  total_parquet_file_size = col_character(),

  data_population            = col_character(),
  data_contact               = col_character(),
  data_flow                  = col_character(),
  data_high_risk_ratios      = col_character(),

  disease_identity           = col_character(),
  disease_params_json        = col_character(),
  disease_R0                 = col_double(),
  disease_runtime_json       = col_character(),
  travel_identity            = col_character(),
  travel_params_json         = col_character(),
  travel_runtime_json        = col_character(),

  vaccine_used               = col_logical(),
  vaccine_identity           = col_character(),
  vaccine_params_json        = col_character(),
  vaccine_runtime_json       = col_character(),

  antiviral_used             = col_logical(),
  antiviral_identity         = col_character(),
  antiviral_params_json      = col_character(),
  antiviral_runtime_json     = col_character(),

  npi_used                   = col_logical(),
  npi_count                  = col_integer(),
  npi_identities             = col_character(),
  npi_params_json            = col_character(),

  initial_exposed_json      = col_character(),
  sim_days                   = col_integer(),
  sim_loglevel               = col_character(),

  geo_region                 = col_character(),
  geo_level                  = col_character(),
  geo_node_count             = col_integer(),

  age_num_groups             = col_integer(),
  age_labels                 = col_character(),

  git_commit                 = col_character(),
  git_branch                 = col_character(),
  git_dirty                  = col_logical(),

  random_base_seed           = col_character(),
  random_seed_strategy       = col_character()
)

#### Load existing master ######################################################
if (file.exists(MASTER_CSV)) {
  master <- read_csv(MASTER_CSV, col_types = MASTER_COL_TYPES, show_col_types = FALSE)

  optional_metadata_columns <- c(
    "metadata_creator",
    "metadata_disease",
    "metadata_sim_day_0",
    "metadata_notes",
    "metadata_tags_json",
    "validation_json",
    "validation_fit_data_file"
  )
  for (column in optional_metadata_columns) {
    if (!column %in% names(master)) master[[column]] <- NA_character_
  }
  if (!"validation_used" %in% names(master)) master[["validation_used"]] <- FALSE
  master <- master %>%
    dplyr::select(-dplyr::any_of(c(
      "scenario_name",
      "scenario_group",
      "scenario_description"
    )))
  
  if (!"sim_completion" %in% names(master)) {
    master <- master %>%
      dplyr::mutate(
        sim_completion = calc_sim_completion(
          attempt_realization_count,
          complete_realization_count))}
  
  master <- master %>%
    dplyr::mutate(
      scenario_hash = as.character(scenario_hash),
      batch_num = as.character(batch_num),
      metadata_creator = as.character(metadata_creator),
      metadata_disease = as.character(metadata_disease),
      metadata_sim_day_0 = as.character(metadata_sim_day_0),
      metadata_notes = as.character(metadata_notes),
      metadata_tags_json = as.character(metadata_tags_json),
      validation_json = as.character(validation_json),
      validation_fit_data_file = as.character(validation_fit_data_file),
      random_base_seed = as.character(random_base_seed),
      created_at_utc = as.POSIXct(created_at_utc, tz = "UTC")
    )
  
  existing_keys <- paste(master$scenario_hash, master$batch_num, sep = "::")
  message(sprintf("Loaded existing master: %d row(s)", nrow(master)))
} else {
  master        <- NULL
  existing_keys <- character(0)
  message("No existing master CSV — starting fresh.")
}

#### Find + parse new JSON files ###############################################
json_files <- list.files(
  path       = SEARCH_ROOT,
  pattern    = "^metadata_batch-.*\\.json$",
  recursive  = TRUE,
  full.names = TRUE
)

message(sprintf("Found %d metadata_batch JSON file(s).", length(json_files)))

parsed_rows <- json_files %>%
  map(\(path) tryCatch(
    parse_metadata(path),
    error = \(e) {
      warning(sprintf("Failed: %s — %s", path, e$message))
      NULL
    }
  )) %>%
  compact() %>%
  list_rbind()

if (nrow(parsed_rows) == 0) {
  new_rows <- parsed_rows
} else if (is.null(master) || nrow(master) == 0) {
  new_rows <- parsed_rows
} else {
  master_lookup <- master %>%
    dplyr::select(scenario_hash, batch_num, sim_completion) %>%
    dplyr::rename(existing_sim_completion = sim_completion)
  
  new_rows <- parsed_rows %>%
    dplyr::left_join(master_lookup, by = c("scenario_hash", "batch_num")) %>%
    dplyr::filter(is.na(existing_sim_completion) | existing_sim_completion < 1) %>%
    dplyr::select(-existing_sim_completion)
}

n_skipped <- nrow(parsed_rows) - nrow(new_rows)
message(sprintf(
  "%d row(s) to process (skipping %d already complete in master).",
  nrow(new_rows), n_skipped
))

#### Ingest new rows ###########################################################
if (nrow(new_rows) > 0) {

  # Optional MongoDB connection
  mongo_col <- NULL
  if (MONGO_ENABLED) {
    if (!requireNamespace("mongolite", quietly = TRUE)) {
      warning("MONGO_ENABLED=TRUE but mongolite is not installed. Skipping MongoDB.")
    } else {
      mongo_col <- mongolite::mongo(
        collection = MONGO_COLLECTION, db = MONGO_DB, url = MONGO_URI
      )
    }
  }

  walk(seq_len(nrow(new_rows)), function(i) {
    row  <- new_rows[i, ]
    mdir <- dirname(row$file_path)
    hash <- row$scenario_hash
    bn   <- row$batch_num

    message(sprintf("\nIngesting %s / %s", hash, bn))
    
    #### Run ingest iuns #######################################################
    ingest_network(mdir, hash, bn)
    ingest_nodes(mdir, hash, bn)
    ingest_sim_times(mdir, hash, bn)
    
    sizes <- get_batch_file_sizes(hash, bn)
    
    new_rows[i, c(
      "network_parquet_bytes",
      "nodes_parquet_bytes",
      "sim_times_parquet_bytes",
      "total_parquet_file_size"
    )] <- tibble(
      sizes$network_parquet_bytes,
      sizes$nodes_parquet_bytes,
      sizes$simulation_times_parquet_bytes,
      format_bytes(sizes$total_parquet_bytes)
    )

    if (!is.null(mongo_col)) {
      tryCatch(
        write_to_mongo(row$file_path, row, mongo_col),
        error = \(e) warning(sprintf("  [mongo] failed: %s", e$message))
      )
      message("  [mongo]   upserted")
    }
  })

  #### Write metadata CSV ######################################################
  if (is.null(master) || nrow(master) == 0) {
    updated_master <- new_rows
  } else {
    keys_to_replace <- paste(new_rows$scenario_hash, new_rows$batch_num, sep = "::")
    
    updated_master <- master %>%
      dplyr::filter(!paste(scenario_hash, batch_num, sep = "::") %in% keys_to_replace) %>%
      bind_rows(new_rows)
  }
  
  # Back filling file size since parquets don't exist at time of ingestion and initial master creation
  for (i in seq_len(nrow(updated_master))) {
    sizes <- get_batch_file_sizes(updated_master$scenario_hash[i], updated_master$batch_num[i])
    
    updated_master$network_parquet_bytes[i]   <- sizes$network_parquet_bytes
    updated_master$nodes_parquet_bytes[i]     <- sizes$nodes_parquet_bytes
    updated_master$sim_times_parquet_bytes[i] <- sizes$simulation_times_parquet_bytes
    updated_master$total_parquet_file_size[i] <- format_bytes(sizes$total_parquet_bytes)
  }
  
  write_csv(updated_master, MASTER_CSV)
  message(sprintf("\nMaster CSV: %s  (%d total row(s))", MASTER_CSV, nrow(updated_master)))

} else {
  message("Nothing new to ingest.")
}

current_master <- if (exists("updated_master")) updated_master else master
write_scenario_features(current_master)
