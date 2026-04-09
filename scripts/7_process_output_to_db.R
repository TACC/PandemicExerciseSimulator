# 7_process_output_to_db.R
#
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
#     (e.g. sigma has different meanings in SEATIRD vs other models).
#   - Each intervention type gets an explicit _used boolean flag.
#   - Parquet compression (zstd) handles sparse simulation data automatically;
#     columns of zeros cost almost nothing in file size.
#   - For very large sweeps (250+ nodes × 250+ realizations) the node ingest
#     reads all county files in one pass via arrow — no full in-memory load.

library(jsonlite)
library(tidyverse)
library(arrow)

#### Configuration #############################################################
SEARCH_ROOT  <- normalizePath(file.path(here::here(), ".."))
MASTER_CSV   <- file.path(SEARCH_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(SEARCH_ROOT, "sim_data")   # partitioned: <hash>/<batch>/

# Set TRUE once a local MongoDB instance is running (install.packages("mongolite"))
MONGO_ENABLED    <- FALSE
MONGO_URI        <- "mongodb://localhost:27017"
MONGO_DB         <- "pandemic_sim"
MONGO_COLLECTION <- "batches"

#### Helper Funs ###############################################################
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

  npi_list   <- m$non_pharma_interventions %||% list()
  npi_used   <- length(npi_list) > 0
  npi_ids    <- vec_to_str(map_chr(npi_list, ~ .x$identity %||% NA_character_))

  vax        <- m$vaccine_model   %||% list()
  vax_id     <- vax$identity
  av         <- m$antiviral_model %||% list()
  av_id      <- av$identity

  dm         <- m$disease_model %||% list()
  tm         <- m$travel_model  %||% list()
  sim_times  <- parse_sim_times(path, m$batch_num %||% "")

  tibble(
    file_path                  = path,
    created_at_utc             = as.POSIXct(m$created_at_utc %||% NA_character_, tz = "UTC"),
    scenario_hash              = m$scenario_hash   %||% NA_character_,
    batch_num                  = m$batch_num       %||% NA_character_,
    output_dir_path            = m$output_dir_path %||% NA_character_,

    realization_min            = safe_get(m, "realization_indices", "min")   %||% NA_integer_,
    realization_max            = safe_get(m, "realization_indices", "max")   %||% NA_integer_,
    attempt_realization_count  = safe_get(m, "realization_indices", "count") %||% NA_integer_,
    complete_realization_count = sim_times$complete_realization_count,
    mean_run_time_seconds      = sim_times$mean_run_time_seconds,

    data_population            = safe_get(m, "data", "population")       %||% NA_character_,
    data_contact               = safe_get(m, "data", "contact")          %||% NA_character_,
    data_flow                  = safe_get(m, "data", "flow")             %||% NA_character_,
    data_high_risk_ratios      = safe_get(m, "data", "high_risk_ratios") %||% NA_character_,

    # Model parameters stored as namespaced JSON — no column-level name collisions
    disease_identity           = dm$identity %||% NA_character_,
    disease_params_json        = to_json_str(dm$parameters),
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

    initial_infected_json      = to_json_str(m$initial_infected),
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
    parquet_glob <- file.path(parquet_root, "*", batch_num,
                              paste0(type, ".parquet"))
    matches <- Sys.glob(parquet_glob)
    if (length(matches) == 0) {
      message(sprintf("  [export] no %s.parquet for batch %s", type, batch_num))
      return(invisible(NULL))
    }
    out_csv <- file.path(output_dir,
                         paste0(type, "_batch-", batch_num, ".csv"))
    DBI::dbExecute(con, sprintf(
      "COPY (
         SELECT * EXCLUDE (scenario_hash, batch_num)
         FROM read_parquet('%s')
         ORDER BY %s
       ) TO '%s' (HEADER, DELIMITER ',')",
      matches[[1]],
      if (type == "nodes") "fips_id, sim_id, day" else "sim_id, day",
      out_csv
    ))
    message(sprintf("  [export] wrote %s", out_csv))
  }

  export_one("network")
  export_one("nodes")
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

  realization_min            = col_integer(),
  realization_max            = col_integer(),
  attempt_realization_count  = col_integer(),
  complete_realization_count = col_integer(),
  mean_run_time_seconds      = col_double(),

  data_population            = col_character(),
  data_contact               = col_character(),
  data_flow                  = col_character(),
  data_high_risk_ratios      = col_character(),

  disease_identity           = col_character(),
  disease_params_json        = col_character(),
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

  initial_infected_json      = col_character(),
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
  master        <- read_csv(MASTER_CSV, col_types = MASTER_COL_TYPES)
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

new_rows <- json_files %>%
  map(\(path) tryCatch(parse_metadata(path),
                       error = \(e) { warning(sprintf("Failed: %s — %s", path, e$message)); NULL })) %>%
  compact() %>%
  list_rbind() %>%
  dplyr::filter(!paste(scenario_hash, batch_num, sep = "::") %in% existing_keys)

n_skipped <- length(json_files) - nrow(new_rows)
message(sprintf("%d new row(s) to add (skipping %d already in master).",
                nrow(new_rows), n_skipped))

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

    ingest_network(mdir, hash, bn)
    ingest_nodes(mdir, hash, bn)

    if (!is.null(mongo_col)) {
      tryCatch(
        write_to_mongo(row$file_path, row, mongo_col),
        error = \(e) warning(sprintf("  [mongo] failed: %s", e$message))
      )
      message("  [mongo]   upserted")
    }
  })

  # ── Write metadata CSV ───────────────────────────────────────────────────────
  updated_master <- bind_rows(master, new_rows)
  write_csv(updated_master, MASTER_CSV)
  message(sprintf("\nMaster CSV: %s  (%d total row(s))", MASTER_CSV, nrow(updated_master)))

} else {
  message("Nothing new to ingest.")
}
