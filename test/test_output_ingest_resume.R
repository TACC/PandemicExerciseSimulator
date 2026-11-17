# Run from the repository root: Rscript --vanilla test/test_output_ingest_resume.R
# Exercise the real ETL with an interruption during the second batch.
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(arrow))
work <- tempfile("ingest-resume-")
dir.create(work)
steps <- parse("scripts/7a_process_output_to_db.R")
for (batch in c("a", "b")) {
  folder <- file.path(work, "WEB_OUTPUTS", batch)
  dir.create(folder, recursive = TRUE)
  jsonlite::write_json(list(
    scenario_hash = "hash", batch_num = batch,
    created_at_utc = "2026-11-17T00:00:00Z",
    realization_indices = list(count = 1L), geo = list(region = "Texas")
  ), file.path(folder, paste0("metadata_batch-", batch, ".json")), auto_unbox = TRUE)
  write_csv(tibble(sim_id = 1L, time_seconds = 2),
            file.path(folder, paste0("simulation_times_batch-", batch, ".csv")))
  write_csv(tibble(sim_id = 1L, day = 0L, S = 10),
            file.path(folder, paste0("network_batch-", batch, ".csv")))
  write_csv(tibble(fips_id = "48001", sim_id = 1L, day = 0L, S = 10),
            file.path(folder, paste0("node_48001_batch-", batch, ".csv")))
}
run_etl <- function(interrupt = FALSE) {
  env <- new.env(parent = globalenv())
  env$pipeline_output_root <- work
  for (step in steps) {
    # Inject a failure into real execution after all helpers are defined.
    if (is.call(step) && identical(step[[1]], as.name("if")) &&
        grepl("nrow(new_rows) > 0", deparse(step[[2]]), fixed = TRUE)) {
      actual_nodes <- env$ingest_nodes
      env$ingest_nodes <- function(metadata_dir, scenario_hash, batch_num) {
        if (interrupt && batch_num == "b") stop("simulated timeout")
        actual_nodes(metadata_dir, scenario_hash, batch_num)
      }
    }
    eval(step, env)
  }
  env
}
master_path <- file.path(work, "metadata_master.csv")
parquet <- function(batch, type) file.path(work, "sim_data", "hash", batch, paste0(type, ".parquet"))
failed <- tryCatch(run_etl(TRUE), error = identity)
stopifnot(inherits(failed, "error"), grepl("simulated timeout", conditionMessage(failed)))
master <- read_csv(master_path, show_col_types = FALSE)
stopifnot(nrow(master) == 1L, master$batch_num == "a", master$sim_completion == 1,
          master$network_parquet_bytes > 0, master$nodes_parquet_bytes > 0)
network_b_time <- file.info(parquet("b", "network"))$mtime
env <- run_etl()
stopifnot(nrow(read_csv(master_path, show_col_types = FALSE)) == 2L,
          identical(file.info(parquet("b", "network"))$mtime, network_b_time),
          file.exists(file.path(work, "scenario_features.parquet")),
          nrow(read_parquet(parquet("b", "nodes"))) == 1L)
# Simulate a legacy interrupted run with finished Parquets and no master.
unlink(master_path)
legacy_times <- file.info(c(parquet("a", "nodes"), parquet("b", "nodes")))$mtime
env <- run_etl()
stopifnot(identical(file.info(c(parquet("a", "nodes"), parquet("b", "nodes")))$mtime, legacy_times))
# A completed rerun skips batches entirely.
env <- run_etl()
stopifnot(nrow(env$new_rows) == 0L)
# Changed sources and truncated Parquets must be rewritten.
source_node <- file.path(work, "WEB_OUTPUTS", "a", "node_48001_batch-a.csv")
Sys.setFileTime(source_node, Sys.time() + 10)
stopifnot(!env$parquet_is_current(parquet("a", "nodes"), source_node))
writeLines("truncated", parquet("b", "nodes"))
source_b <- file.path(work, "WEB_OUTPUTS", "b", "node_48001_batch-b.csv")
stopifnot(!env$parquet_is_current(parquet("b", "nodes"), source_b))
# A failed atomic replacement preserves the old checkpoint.
before <- readLines(master_path)
tryCatch(env$atomic_output(master_path, function(path) {
  writeLines("partial", path)
  stop("interrupted writer")
}), error = function(e) NULL)
stopifnot(identical(readLines(master_path), before))
unlink(work, recursive = TRUE)
cat("Output ingest resume tests passed\n")
