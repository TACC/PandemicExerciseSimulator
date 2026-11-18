# Real extraction/rendering plus interruption, resume and invalidation checks.
# Run: Rscript --vanilla test/test_validation_spaghetti_resume.R
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(arrow))
work <- tempfile("spaghetti-test-")
dir.create(work)
env <- new.env(parent = globalenv())
constants <- c("COMPARTMENTS", "SCENARIO_ORDER", "SCENARIO_COLORS", "SCENARIO_DISPLAY")
for (step in parse("scripts/9b_score_validation_hubverse_style.R")) {
  if (!is.call(step) || !identical(step[[1]], as.name("<-"))) next
  if (as.character(step[[2]]) %in% constants ||
      (is.call(step[[3]]) && identical(step[[3]][[1]], as.name("function")))) eval(step, env)
}
env$PARQUET_ROOT <- file.path(work, "sim_data")
env$STATE_COMPARTMENT_SPAGHETTI_DIR <- file.path(work, "plots")
metadata <- tibble(geo_region = c("Alabama", "Wyoming"), scenario_hash = c("hash-a", "hash-b"),
  validation_json = NA_character_, metadata_sim_day_0 = "2025-10-04",
  disease_R0 = 2, vaccine_used = FALSE, antiviral_used = FALSE, npi_used = FALSE)
for (hash in metadata$scenario_hash) {
  dir.create(file.path(env$PARQUET_ROOT, hash, "batch"), recursive = TRUE)
  write_parquet(tibble(batch_num = "batch", sim_id = rep(1:2, each = 3),
    day = rep(0:2, 2), I = c(1, 2, 3, 2, 3, 4)),
    file.path(env$PARQUET_ROOT, hash, "batch", "network.parquet"))
}
actual <- env$save_one_state_compartment_spaghetti
calls <- character()
# Preserve checkpoint signature across injected interruption and normal resume.
# The wrapper body itself is part of the signature, so change its behavior via a flag.
interrupt <- TRUE
env$save_one_state_compartment_spaghetti <- function(metadata) {
  stopifnot(length(unique(metadata$geo_region)) == 1L)
  calls <<- c(calls, metadata$geo_region[[1]])
  if (interrupt && metadata$geo_region[[1]] == "Wyoming") stop("simulated interruption")
  actual(metadata)
}
err <- tryCatch(env$save_state_compartment_spaghetti_plots(metadata), error = identity)
stopifnot(inherits(err, "error"), conditionMessage(err) == "simulated interruption")
checkpoint <- file.path(env$STATE_COMPARTMENT_SPAGHETTI_DIR, "alabama", ".spaghetti_complete.rds")
saved <- readRDS(checkpoint)
stopifnot(length(saved$outputs) == 2L, all(file.exists(saved$outputs)))
# Verify that real PNGs were rendered, without loading the image.
con <- file(saved$outputs[[1]], "rb"); header <- readBin(con, "raw", 24); close(con)
stopifnot(identical(as.integer(header[1:8]), c(137L,80L,78L,71L,13L,10L,26L,10L)))
interrupt <- FALSE
calls <- character()
env$save_state_compartment_spaghetti_plots(metadata)
stopifnot(identical(calls, "Wyoming"))
calls <- character()
env$save_state_compartment_spaghetti_plots(metadata)
stopifnot(length(calls) == 0L)
# Missing outputs invalidate only that state's checkpoint.
unlink(saved$outputs[[1]])
env$save_state_compartment_spaghetti_plots(metadata)
stopifnot(identical(calls, "Alabama"))
# New batch files invalidate the corresponding state.
calls <- character()
dir.create(file.path(env$PARQUET_ROOT, "hash-b", "new-batch"))
write_parquet(tibble(batch_num = "new-batch", sim_id = 3L, day = 0L, I = 9),
  file.path(env$PARQUET_ROOT, "hash-b", "new-batch", "network.parquet"))
env$save_state_compartment_spaghetti_plots(metadata)
stopifnot(identical(calls, "Wyoming"))
# Empty states do not receive a finished checkpoint.
missing <- metadata[1, ]; missing$scenario_hash <- "missing"; missing$geo_region <- "Missing"
suppressWarnings(env$save_state_compartment_spaghetti_plots(missing))
stopifnot(!file.exists(file.path(env$STATE_COMPARTMENT_SPAGHETTI_DIR, "missing", ".spaghetti_complete.rds")))
unlink(work, recursive = TRUE)
cat("Validation spaghetti resume tests passed\n")
