# Run: Rscript --vanilla test/test_r0_total_search.R
suppressPackageStartupMessages({library(dplyr); library(tidyr); library(purrr); library(tibble)})
`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
source("scripts/5c_Rm_search_helpers.R")

stopifnot(identical(parse_r0_search_metrics("all"), c("total", "peak_height", "peak_timing")),
          identical(parse_r0_search_metrics("all,wis"), c("total", "peak_height", "peak_timing", "wis")))
stopifnot(inherits(tryCatch(parse_r0_search_metrics("objective"), error = identity), "error"))

metadata <- list(metadata_tags = list(sim_day_0 = "2025-10-04"), cli_args = list(days = 200),
                 realization_indices = list(min = 0, max = 1))
window <- r0_scoring_window(metadata, 200)
stopifnot(window$end == as.Date("2026-04-22"), max(window$weeks) == as.Date("2026-04-18"))
daily <- tidyr::expand_grid(sim_id = 0:1, day = 0:210) %>%
  mutate(H = 10 + .data$day)
weekly <- r0_weekly_incident_samples(daily, metadata, 200)
stopifnot(nrow(weekly) == 2 * length(window$weeks), all(weekly$generated == 7),
          max(weekly$date) <= window$end)
# Retain the original positive H-delta calculation; day 0 and all days beyond
# the horizon, including the trailing incomplete week, must not contribute.
totals <- weekly %>% group_by(sim_id) %>% summarise(total = sum(generated))
stopifnot(all(totals$total == 7 * length(window$weeks)))
early <- daily %>% filter((sim_id == 0 & day <= 7) | (sim_id == 1 & day <= 1)) %>%
  mutate(H = if_else(sim_id == 1, 0, H))
padded <- r0_weekly_incident_samples(early, metadata, 200)
stopifnot(nrow(padded) == nrow(weekly), all(padded$generated[padded$sim_id == 1] == 0),
          all(padded$generated[padded$date > min(window$weeks)] == 0))
stopifnot(inherits(tryCatch(r0_weekly_incident_samples(select(daily, -H), metadata, 200),
                         error = identity), "error"))
stopifnot(all(r0_weekly_incident_samples(mutate(daily, H = 10), metadata, 200)$generated == 0))
stopifnot(inherits(tryCatch(r0_weekly_incident_samples(filter(daily, sim_id == 0), metadata, 200),
                         error = identity), "error"))

# Extract functions without launching the pipeline or simulations.
expressions <- as.list(parse(file = "scripts/5c_Rm_search.R"))
load_function <- function(name, env = .GlobalEnv) {
  assignment <- Filter(function(expr) is.call(expr) && identical(expr[[1]], as.name("<-")) &&
                         identical(expr[[2]], as.name(name)), expressions)
  stopifnot(length(assignment) == 1L)
  eval(assignment[[1]], env)
}
for (name in c("select_best_r0", "search_state", "read_sweep_table", "sweep_table_path", "read_observed_state_weekly", "with_sweep_file_lock", "write_csv_preserving_existing")) load_function(name)

table <- tibble(disease_R0 = c(1.5, 2, 2.5), predicted_median_total = c(80, 100, 150), observed_total = 100,
                predicted_peak_height = c(10, 20, 30), observed_peak_height = 10,
                peak_lag_weeks = c(2, 1, 0), mean_wis = c(1, 10, 20))
stopifnot(select_best_r0(table, "total")$disease_R0 == 2,
          select_best_r0(table, "peak_height")$disease_R0 == 1.5,
          select_best_r0(table, "peak_timing")$disease_R0 == 2.5,
          select_best_r0(table, "wis")$disease_R0 == 1.5)

normalize_state_dir <- identity
r0_min <- 1.01; r0_max <- 3.5; base_r0 <- 2.2; initial_step <- 0.4
min_step <- 0.05; step_shrink <- 0.5; max_iterations <- 10
clip_r0 <- function(r0) pmin(pmax(r0, r0_min), r0_max)
r0_key <- function(r0) sprintf("%.4f", r0)
evaluate_candidate <- function(state, r0) {
  summary <- tibble(geo_region = state, disease_R0 = r0,
                    predicted_median_total = 100 + 100 * (r0 - 2.8)^2, observed_total = 100,
                    predicted_peak_height = 10 + 10 * (r0 - 2)^2, observed_peak_height = 10,
                    peak_lag_weeks = r0 - 3.2, mean_wis = (r0 - 1.4)^2)
  summary$search_score <- r0_metric_values(summary, r0_selection_metric)
  list(summary = summary, scores = tibble(), predictions = tibble(), samples = tibble(), observed = tibble())
}
r0_selection_metric <- "total"; r0_search_metrics <- "total"
total_only <- search_state("Test")
stopifnot(abs(total_only$best$disease_R0 - 2.8) < 1e-8,
          min(total_only$trace$disease_R0) >= 1.8)
r0_search_metrics <- parse_r0_search_metrics("all")
all_features <- search_state("Test")
for (metric in r0_search_metrics) {
  expected <- c(total = 2.8, peak_height = 2, peak_timing = 3.2)[[metric]]
  stopifnot(abs(select_best_r0(all_features$trace, metric)$disease_R0 - expected) < 1e-8)
}

# Extra observed weeks and a huge peak beyond day 200 cannot enter scoring/plots.
temporary <- tempfile(); dir.create(temporary)
validation_file <- file.path(temporary, "observed.csv")
readr::write_csv(tibble(date = c(window$weeks, as.Date("2026-04-25")),
                        incident_hospitalizations = c(rep(5, length(window$weeks)), 1e9)), validation_file)
metadata$metadata_tags$validation <- list(fit_data_file = validation_file)
metadata_file <- file.path(temporary, "metadata.json")
jsonlite::write_json(metadata, metadata_file, auto_unbox = TRUE)
resolve_validation_file <- function(metadata) validation_file
metadata_state <- function(metadata) "Test"
safe_num <- as.numeric
simulation_days <- 200
observed <- read_observed_state_weekly(metadata_file)
stopifnot(sum(observed$observed) == 5 * length(window$weeks), max(observed$date) == max(window$weeks))

summary_file <- file.path(temporary, "summary.csv")
saved <- tibble(geo_region = "Test", disease_R0 = 2.2, search_score = 1/3)
write_csv_preserving_existing(saved, summary_file)
saved$search_score <- saved$search_score + 1e-15
write_csv_preserving_existing(saved, summary_file)
stopifnot(nrow(readr::read_csv(summary_file, show_col_types = FALSE)) == 1)

# Concurrent state jobs must preserve all candidate rows and replace each
# state's best row even when its selected R_m changes.
shared_candidates <- file.path(temporary, "parallel-candidates.csv")
shared_best <- file.path(temporary, "parallel-best.csv")
jobs <- parallel::mclapply(1:4, function(worker) {
  for (candidate in 1:5) {
    row <- tibble(geo_region = paste0("State", worker), disease_R0 = candidate)
    write_csv_preserving_existing(row, shared_candidates)
    write_csv_preserving_existing(row, shared_best, keys = "geo_region")
  }
  TRUE
}, mc.cores = 4L)
stopifnot(all(vapply(jobs, isTRUE, logical(1))),
  nrow(readr::read_csv(shared_candidates, show_col_types = FALSE)) == 20L,
  nrow(readr::read_csv(shared_best, show_col_types = FALSE)) == 4L,
  all(readr::read_csv(shared_best, show_col_types = FALSE)$disease_R0 == 5),
  !any(grepl("\\.lock$", list.files(temporary))))

# LS6 checkpoint writes never create combined CSVs during fitting.
defer_sweep_tables <- TRUE
sweep_root <- temporary
states <- "Private-State"
combined <- file.path(sweep_root, "Rm_search_search_trace.csv")
private <- sweep_table_path(combined)
write_csv_preserving_existing(saved, private)
stopifnot(endsWith(private, "Private-State_Rm_search_search_trace.rds"),
  file.exists(private), !file.exists(combined), nrow(read_sweep_table(private)) == 1L)
defer_sweep_tables <- FALSE

# The orchestrator must reject fits produced by the old scoring definition or
# a different requested search set, even when the simulation date is identical.
pipeline_expressions <- as.list(parse(file = "scripts/0_pipeline_helpers.R"))
matcher <- Filter(function(expr) is.call(expr) && identical(expr[[1]], as.name("<-")) &&
                    identical(expr[[2]], as.name("wis_calibrated_fit_matches")), pipeline_expressions)
stopifnot(length(matcher) == 1L)
eval(matcher[[1]])
R0_SEARCH_METRICS <- c("total", "peak_height", "peak_timing", "wis")
fit <- list(metadata_tags = list(sim_day_0 = "2025-10-04", epydemix_fit = list(
  method = "full_simulator_all_interventions_state_feature_search", simulation_start_date = "2025-10-04",
  distance_settings = list(simulation_days = 200, realization_range = c(0, 9),
    r0_selection_metric = "total", scoring_version = R0_SCORING_VERSION, search_metrics = R0_SEARCH_METRICS))))
fit_file <- file.path(temporary, "fit.json")
jsonlite::write_json(fit, fit_file, auto_unbox = TRUE)
stopifnot(wis_calibrated_fit_matches(fit_file, "2025-10-04", 200, c(0,9), "total"))
fit$metadata_tags$epydemix_fit$distance_settings$scoring_version <- "old"
jsonlite::write_json(fit, fit_file, auto_unbox = TRUE)
stopifnot(!wis_calibrated_fit_matches(fit_file, "2025-10-04", 200, c(0,9), "total"))
cat("R0 metrics, adaptive paths, unchanged H-delta series, extinction padding and day-200 windows passed.\n")

# Plot reconstruction follows only requested metric paths and the evaluated
# candidates in each round; it must not add hypothetical search points.
windows <- r0_search_window_data(total_only$trace, "total", r0_min, r0_max)
stopifnot(length(unique(windows$points$facet_label)) == 1L,
          nrow(windows$best) == length(unique(total_only$trace$iteration)),
          nrow(windows$final) == 1L,
          abs(windows$final$disease_R0 - 2.8) < 1e-8)
for (iter in unique(windows$points$iteration)) {
  shown <- windows$points[windows$points$iteration == iter, ]
  actual <- total_only$trace[total_only$trace$iteration == iter, ]
  stopifnot(all(shown$disease_R0 %in% actual$disease_R0),
            sum(shown$is_round_best) == 1L)
}
feature_windows <- r0_search_window_data(all_features$trace,
  c("total", "peak_height", "peak_timing"), r0_min, r0_max)
stopifnot(length(unique(feature_windows$points$facet_label)) == 3L,
          nrow(feature_windows$final) == 3L)
cat("Search-window plot paths and requested facet counts passed.\n")
