#////////
#### Script Overview ####
#////////
# Score completed scenario outputs against validation hospitalization data using
# Hubverse-style quantile scoring. This can be rerun while TACC is still filling
# in the full state grid; it scores only scenarios with metadata, parquet output,
# and validation_fit_data available.
#
# Important: current simulator node outputs store compartment states, not the
# IS -> H transition flow used by Epydemix calibration. Until transition flows
# are written, this script scores weekly positive changes in H as the generated
# incident hospitalization proxy, matching the dashboard convention.
#
# Outputs:
#   <PIPELINE_OUTPUT_DIR>/validation_scores/hubverse_quantile_predictions.csv
#   <PIPELINE_OUTPUT_DIR>/validation_scores/hubverse_wis_scores_by_age_week.csv
#   <PIPELINE_OUTPUT_DIR>/validation_scores/hubverse_wis_summary.csv
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/wis_by_state_scenario.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/wis_by_state_scenario_by_population.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/wis_by_age_scenario.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/wis_by_age_scenario_by_population.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/peak_lag_by_state_scenario.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/wis_vs_input_features.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/state_trajectory_plots/<state>.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/state_compartment_spaghetti/<state>/<scenario>_<compartment>.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/state_compartment_spaghetti/<state>/all_interventions/<compartment>_all_interventions_spaghetti.png
#
# Example:
#   Rscript scripts/9b_score_validation_hubverse_style.R \
#     --output-dir=STATE_WKLYFIT_TEST

suppressPackageStartupMessages({
  library(arrow)
  library(DBI)
  library(dplyr)
  library(duckdb)
  library(ggplot2)
  library(jsonlite)
  library(purrr)
  library(readr)
  library(stringr)
  library(tibble)
  library(tidyr)
})

filter <- dplyr::filter
mutate <- dplyr::mutate
select <- dplyr::select
arrange <- dplyr::arrange
desc <- dplyr::desc
group_by <- dplyr::group_by
ungroup <- dplyr::ungroup
summarise <- dplyr::summarise
transmute <- dplyr::transmute
slice <- dplyr::slice
bind_rows <- dplyr::bind_rows
left_join <- dplyr::left_join
inner_join <- dplyr::inner_join
full_join <- dplyr::full_join
across <- dplyr::across
all_of <- dplyr::all_of
starts_with <- tidyselect::starts_with
pivot_longer <- tidyr::pivot_longer

args <- commandArgs(trailingOnly = TRUE)

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

get_arg_value <- function(prefix, default = NA_character_) {
  hit <- args[startsWith(args, prefix)]
  if (length(hit) == 0) return(default)
  sub(prefix, "", hit[[1]], fixed = TRUE)
}

safe_num <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.nan(out), NA_real_, out)
}

repo_root <- normalizePath(".", mustWork = FALSE)
if (basename(repo_root) == "scripts") {
  repo_root <- normalizePath("..", mustWork = TRUE)
}

pipeline_output_dir <- get_arg_value("--output-dir=", "STATE_HIGHRISK-ANTIVIRAL_R0-WIS_POC")
SEARCH_ROOT <- normalizePath(
  if (grepl("^/", pipeline_output_dir)) pipeline_output_dir else file.path(repo_root, pipeline_output_dir),
  mustWork = FALSE
)
MASTER_CSV <- file.path(SEARCH_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(SEARCH_ROOT, "sim_data")
SCORE_DIR <- file.path(SEARCH_ROOT, "validation_scores")
PLOT_DIR <- file.path(SCORE_DIR, "plots")
STATE_TRAJECTORY_DIR <- file.path(PLOT_DIR, "state_trajectory_plots")
STATE_COMPARTMENT_SPAGHETTI_DIR <- file.path(PLOT_DIR, "state_compartment_spaghetti")
SCENARIO_REGEX <- get_arg_value("--scenario-regex=", "")
OUTPUT_SOURCE_REGEX <- get_arg_value("--output-source-regex=", "WEB_OUTPUTS")
MAX_SCENARIOS <- as.integer(get_arg_value("--max-scenarios=", "0"))

dir.create(SCORE_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(STATE_TRAJECTORY_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(STATE_COMPARTMENT_SPAGHETTI_DIR, recursive = TRUE, showWarnings = FALSE)

AGE_GROUPS <- c("0-4", "5-17", "18-49", "50-64", "65+")
COMPARTMENTS <- c("S", "E", "A", "IA", "IP", "IS", "I", "T", "H", "R", "D")
QUANTILE_LEVELS <- c(0.01, 0.025, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.975, 0.99)
SCENARIO_ORDER <- c("NONE", "VACCINE", "NPI", "ANTIVIRAL", "VACCINE+ANTIVIRAL+NPI")
SCENARIO_DISPLAY <- c(
  "NONE" = "None",
  "VACCINE" = "Vaccine",
  "NPI" = "NPI",
  "ANTIVIRAL" = "Antiviral",
  "VACCINE+ANTIVIRAL+NPI" = "All 3"
)
SCENARIO_COLORS <- c(
  "NONE" = "#91D5DE",
  "VACCINE" = "#2E8289",
  "NPI" = "#B4674E",
  "ANTIVIRAL" = "#EAAE37",
  "VACCINE+ANTIVIRAL+NPI" = "#565F41"
)
high_risk_palette <- c("#f3e79b", "#fac484", "#f8a07e", "#eb7f86", "#ce6693", "#a059a0", "#5c53a5")

resolve_model_path <- function(path, metadata_path = NA_character_) {
  if (is.null(path) || length(path) == 0 || is.na(path) || !nzchar(path)) return(NA_character_)
  if (grepl("^template:", path)) {
    path <- sub("^template:", "", path)
    path <- sub("#.*$", "", path)
  }
  if (grepl("^/", path)) {
    if (file.exists(path)) return(normalizePath(path, mustWork = FALSE))
    basename_fallback <- file.path(SEARCH_ROOT, "validation_fit_data", basename(path))
    if (file.exists(basename_fallback)) return(normalizePath(basename_fallback, mustWork = FALSE))
    return(normalizePath(path, mustWork = FALSE))
  }

  candidates <- character()
  if (!is.na(metadata_path) && nzchar(metadata_path)) {
    candidates <- c(candidates, file.path(dirname(metadata_path), path))
  }
  candidates <- c(candidates, file.path(SEARCH_ROOT, path), file.path(repo_root, path))

  stripped <- path
  while (startsWith(stripped, "../")) stripped <- sub("^\\.\\./", "", stripped)
  candidates <- c(candidates, file.path(repo_root, stripped))

  existing <- candidates[file.exists(candidates)]
  normalizePath(if (length(existing) > 0) existing[[1]] else candidates[[1]], mustWork = FALSE)
}

empty_observed_tbl <- function() {
  tibble(date = as.Date(character()), age_group = character(), observed = numeric())
}

empty_prediction_tbl <- function() {
  tibble(
    scenario_hash = character(),
    batch_num = character(),
    geo_region = character(),
    scenario_label = character(),
    disease_R0 = numeric(),
    vaccine_used = logical(),
    antiviral_used = logical(),
    npi_used = logical(),
    reference_date = as.Date(character()),
    date = as.Date(character()),
    age_group = character(),
    sample_count = integer(),
    quantile = numeric(),
    value = numeric(),
    output_type = character(),
    target = character(),
    generated_measure = character()
  )
}

scenario_label <- function(row) {
  parts <- character()
  if (isTRUE(row$vaccine_used)) parts <- c(parts, "VACCINE")
  if (isTRUE(row$antiviral_used)) parts <- c(parts, "ANTIVIRAL")
  if (isTRUE(row$npi_used)) parts <- c(parts, "NPI")
  if (length(parts) == 0) return("NONE")
  paste(parts, collapse = "+")
}

parse_validation_json <- function(validation_json) {
  if (is.na(validation_json) || !nzchar(validation_json)) return(list())
  tryCatch(jsonlite::fromJSON(validation_json, simplifyVector = TRUE), error = function(e) list())
}

first_complete_mmwr_week_end <- function(start_date) {
  start_date <- as.Date(start_date)
  days_until_saturday <- (6 - as.integer(format(start_date, "%w"))) %% 7
  week_end <- start_date + days_until_saturday
  week_start <- week_end - 6
  if (week_start < start_date) week_end <- week_end + 7
  week_end
}

mmwr_week_end_date <- function(date) {
  date <- as.Date(date)
  date + ((6 - as.integer(format(date, "%w"))) %% 7)
}

parquet_files_for <- function(scenario_hash, type = "nodes") {
  Sys.glob(file.path(PARQUET_ROOT, scenario_hash, "*", paste0(type, ".parquet")))
}

parquet_file_array_sql <- function(con, paths) {
  paste0("[", paste(DBI::dbQuoteString(con, paths), collapse = ", "), "]")
}

slugify <- function(x) {
  str_replace_all(str_to_lower(x), "[^a-z0-9]+", "_") %>%
    str_replace_all("^_|_$", "")
}

compact_axis_label <- function(x) {
  dplyr::case_when(
    is.na(x) ~ NA_character_,
    abs(x) >= 1e9 ~ paste0(format(round(x / 1e9, 1), trim = TRUE, scientific = FALSE), "B"),
    abs(x) >= 1e6 ~ paste0(format(round(x / 1e6, 1), trim = TRUE, scientific = FALSE), "M"),
    abs(x) >= 1e3 ~ paste0(format(round(x / 1e3, 1), trim = TRUE, scientific = FALSE), "K"),
    TRUE ~ format(round(x, 0), trim = TRUE, scientific = FALSE)
  ) %>%
    str_replace("\\.0([KMB])$", "\\1")
}

network_compartment_spaghetti <- function(row) {
  parquet_files <- parquet_files_for(row$scenario_hash, "network")
  if (length(parquet_files) == 0) return(tibble())

  column_names <- names(arrow::read_parquet(parquet_files[[1]], as_data_frame = FALSE))
  available_compartments <- intersect(COMPARTMENTS, column_names)
  if (length(available_compartments) == 0) return(tibble())

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  compartment_exprs <- paste0(
    "COALESCE(",
    as.character(DBI::dbQuoteIdentifier(con, available_compartments)),
    ", 0) AS ",
    as.character(DBI::dbQuoteIdentifier(con, available_compartments))
  )

  query <- paste0(
    "SELECT batch_num, sim_id, day, ",
    paste(compartment_exprs, collapse = ", "),
    " FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
    "ORDER BY batch_num, sim_id, day"
  )

  sim_start_date <- parse_validation_json(row$validation_json)$sim_start_date %||% row$metadata_sim_day_0

  DBI::dbGetQuery(con, query) %>%
    mutate(across(all_of(available_compartments), ~ suppressWarnings(as.numeric(.x)))) %>%
    pivot_longer(
      cols = all_of(available_compartments),
      names_to = "compartment",
      values_to = "value"
    ) %>%
    mutate(
      scenario_hash = row$scenario_hash,
      geo_region = row$geo_region,
      scenario_label = scenario_label(row),
      disease_R0 = row$disease_R0,
      date = as.Date(sim_start_date) + .data$day,
      sim_line_id = paste(.data$scenario_label, .data$batch_num, .data$sim_id, sep = "::"),
      compartment = factor(.data$compartment, levels = COMPARTMENTS),
      .before = 1
    ) %>%
    filter(!is.na(.data$compartment))
}

save_state_compartment_spaghetti_plots <- function(metadata) {
  spaghetti_data <- pmap_dfr(metadata, function(...) {
    row <- list(...)
    message("Compartment spaghetti: ", row$geo_region, " / ", scenario_label(row), " / ", substr(row$scenario_hash, 1, 8))
    tryCatch(
      network_compartment_spaghetti(row),
      error = function(e) {
        warning(sprintf("Compartment spaghetti extraction failed for %s / %s: %s", row$geo_region, row$scenario_hash, e$message))
        tibble()
      }
    )
  }) %>%
    mutate(
      scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER)
    ) %>%
    filter(!is.na(.data$scenario_label), !is.na(.data$value))

  if (nrow(spaghetti_data) == 0) {
    warning("No network compartment trajectories available for spaghetti plots.")
    return(invisible(tibble()))
  }

  median_data <- spaghetti_data %>%
    group_by(.data$geo_region, .data$scenario_label, .data$compartment, .data$date) %>%
    summarise(value = stats::median(.data$value, na.rm = TRUE), .groups = "drop")

  for (state in sort(unique(spaghetti_data$geo_region))) {
    state_data <- spaghetti_data %>%
      filter(.data$geo_region == state)
    state_medians <- median_data %>%
      filter(.data$geo_region == state)
    state_dir <- file.path(STATE_COMPARTMENT_SPAGHETTI_DIR, slugify(state))
    all_interventions_dir <- file.path(state_dir, "all_interventions")
    dir.create(state_dir, recursive = TRUE, showWarnings = FALSE)
    dir.create(all_interventions_dir, recursive = TRUE, showWarnings = FALSE)

    for (compartment_id in levels(droplevels(state_data$compartment))) {
      plot_data <- state_data %>%
        filter(.data$compartment == .env$compartment_id)
      plot_medians <- state_medians %>%
        filter(.data$compartment == .env$compartment_id)

      if (nrow(plot_data) == 0) next

      scenario_breaks <- plot_data %>%
        distinct(.data$scenario_label) %>%
        arrange(.data$scenario_label) %>%
        pull(.data$scenario_label) %>%
        as.character()

      p <- ggplot(plot_data, aes(x = .data$date, y = .data$value, color = .data$scenario_label)) +
        geom_line(aes(group = .data$sim_line_id), linewidth = 0.35, alpha = 0.18) +
        geom_line(
          data = plot_medians,
          aes(group = .data$scenario_label),
          linewidth = 1.45,
          alpha = 0.98
        ) +
        scale_color_manual(
          values = SCENARIO_COLORS[scenario_breaks],
          breaks = scenario_breaks,
          labels = SCENARIO_DISPLAY[scenario_breaks],
          drop = FALSE
        ) +
        scale_y_continuous(labels = compact_axis_label, expand = expansion(mult = c(0.02, 0.08))) +
        labs(
          x = NULL,
          y = paste0(compartment_id, " compartment"),
          title = paste0(state_dir_to_name(state), ": ", compartment_id, " Compartment Trajectories by Intervention"),
          subtitle = "Only scenarios with this compartment are shown; thin lines are simulations, thick lines are medians",
          color = NULL
        ) +
        guides(color = guide_legend(override.aes = list(linewidth = 1.8, alpha = 1))) +
        theme_minimal(base_size = 28) +
        theme(
          panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold", size = 28),
          plot.subtitle = element_text(size = 20),
          axis.text = element_text(size = 30),
          axis.title.y = element_text(size = 34, margin = margin(r = 14)),
          legend.position = "bottom",
          legend.text = element_text(size = 22),
          legend.key.width = grid::unit(1.3, "cm"),
          plot.margin = margin(12, 18, 12, 18)
        )

      state_file <- paste0(slugify(compartment_id), "_all_interventions_spaghetti.png")
      ggsave(
        file.path(all_interventions_dir, state_file),
        p,
        width = 16,
        height = 9,
        units = "in",
        dpi = 300,
        bg = "white"
      )
    }

    for (scenario_id in levels(droplevels(state_data$scenario_label))) {
      scenario_title <- SCENARIO_DISPLAY[[scenario_id]] %||% scenario_id
      scenario_file <- slugify(scenario_id)
      scenario_data <- state_data %>%
        filter(.data$scenario_label == .env$scenario_id)
      scenario_medians <- state_medians %>%
        filter(.data$scenario_label == .env$scenario_id)

      for (compartment_id in levels(droplevels(scenario_data$compartment))) {
        plot_data <- scenario_data %>%
          filter(.data$compartment == .env$compartment_id)
        plot_medians <- scenario_medians %>%
          filter(.data$compartment == .env$compartment_id)

        if (nrow(plot_data) == 0) next

        p <- ggplot(plot_data, aes(x = .data$date, y = .data$value)) +
          geom_line(
            aes(group = .data$sim_line_id),
            color = SCENARIO_COLORS[[scenario_id]],
            linewidth = 0.35,
            alpha = 0.22
          ) +
          geom_line(
            data = plot_medians,
            color = SCENARIO_COLORS[[scenario_id]],
            linewidth = 1.45,
            alpha = 0.98
          ) +
          scale_y_continuous(labels = compact_axis_label, expand = expansion(mult = c(0.02, 0.08))) +
          labs(
            x = NULL,
            y = paste0(compartment_id, " compartment"),
            title = paste0(state_dir_to_name(state), ": ", scenario_title, " ", compartment_id, " Compartment Trajectories"),
            subtitle = "Thin lines are individual simulations; thick line is the scenario median"
          ) +
          theme_minimal(base_size = 28) +
          theme(
            panel.grid.minor = element_blank(),
            plot.title = element_text(face = "bold", size = 28),
            plot.subtitle = element_text(size = 20),
            axis.text = element_text(size = 30),
            axis.title.y = element_text(size = 34, margin = margin(r = 14)),
            plot.margin = margin(12, 18, 12, 18)
          )

        state_file <- paste0(scenario_file, "_", slugify(compartment_id), "_spaghetti.png")
        ggsave(
          file.path(state_dir, state_file),
          p,
          width = 16,
          height = 9,
          units = "in",
          dpi = 300,
          bg = "white"
        )
      }
    }
  }

  invisible(spaghetti_data)
}

h_age_expression <- function(con, column_names, age_index) {
  pattern <- paste0("^H_[HL]_[UV]_age", age_index, "$")
  age_cols <- grep(pattern, column_names, value = TRUE)
  if (length(age_cols) == 0) return("0")
  paste0("COALESCE(", as.character(DBI::dbQuoteIdentifier(con, age_cols)), ", 0)") %>%
    paste(collapse = " + ")
}

observed_by_age <- function(row) {
  validation_file <- resolve_model_path(row$validation_fit_data_file, row$file_path)
  if (is.na(validation_file) || !file.exists(validation_file)) return(empty_observed_tbl())

  readr::read_csv(validation_file, show_col_types = FALSE) %>%
    transmute(
      date = as.Date(.data$date),
      age_group = as.character(.data$age_group),
      observed = safe_num(.data$incident_hospitalizations)
    ) %>%
    filter(.data$age_group %in% AGE_GROUPS)
}

generated_weekly_samples <- function(row) {
  parquet_files <- parquet_files_for(row$scenario_hash, "nodes")
  if (length(parquet_files) == 0) return(tibble())

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  column_names <- names(arrow::read_parquet(parquet_files[[1]], as_data_frame = FALSE))
  h_all_expr <- "SUM(COALESCE(H, 0)) AS all_age"
  h_age_exprs <- map_chr(seq_along(AGE_GROUPS) - 1L, function(age_index) {
    paste0(
      "SUM(",
      h_age_expression(con, column_names, age_index),
      ") AS ",
      DBI::dbQuoteIdentifier(con, paste0("age", age_index))
    )
  })

  query <- paste0(
    "SELECT batch_num, sim_id, day, ",
    paste(c(h_all_expr, h_age_exprs), collapse = ", "),
    " FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
    "GROUP BY batch_num, sim_id, day ",
    "ORDER BY batch_num, sim_id, day"
  )

  sim_start_date <- parse_validation_json(row$validation_json)$sim_start_date %||% row$metadata_sim_day_0
  fit_start_date <- first_complete_mmwr_week_end(sim_start_date)

  DBI::dbGetQuery(con, query) %>%
    pivot_longer(
      cols = c("all_age", starts_with("age")),
      names_to = "age_key",
      values_to = "H"
    ) %>%
    mutate(
      age_index = suppressWarnings(as.integer(sub("^age", "", .data$age_key))),
      age_group = if_else(
        .data$age_key == "all_age",
        "all",
        AGE_GROUPS[.data$age_index + 1L]
      )
    ) %>%
    select(-"age_index") %>%
    arrange(.data$batch_num, .data$sim_id, .data$age_group, .data$day) %>%
    group_by(.data$batch_num, .data$sim_id, .data$age_group) %>%
    mutate(
      generated = pmax(.data$H - dplyr::lag(.data$H, default = dplyr::first(.data$H)), 0),
      calendar_date = as.Date(sim_start_date) + .data$day,
      date = mmwr_week_end_date(.data$calendar_date)
    ) %>%
    ungroup() %>%
    filter(.data$date >= fit_start_date) %>%
    group_by(.data$date, .data$age_group, .data$batch_num, .data$sim_id) %>%
    summarise(generated = sum(.data$generated, na.rm = TRUE), .groups = "drop")
}

quantile_predictions <- function(row) {
  samples <- generated_weekly_samples(row)
  if (nrow(samples) == 0) return(empty_prediction_tbl())

  samples %>%
    group_by(.data$date, .data$age_group) %>%
    summarise(
      quantile = list(QUANTILE_LEVELS),
      value = list(as.numeric(stats::quantile(.data$generated, QUANTILE_LEVELS, na.rm = TRUE, names = FALSE))),
      sample_count = dplyr::n(),
      .groups = "drop"
    ) %>%
    tidyr::unnest(c("quantile", "value")) %>%
    mutate(
      scenario_hash = row$scenario_hash,
      batch_num = "ALL_BATCHES",
      geo_region = row$geo_region,
      scenario_label = scenario_label(row),
      disease_R0 = row$disease_R0,
      vaccine_used = row$vaccine_used,
      antiviral_used = row$antiviral_used,
      npi_used = row$npi_used,
      reference_date = as.Date(row$metadata_sim_day_0),
      output_type = "quantile",
      target = "wk inc flu hosp",
      generated_measure = "positive_h_delta_proxy",
      .before = 1
    )
}

score_wis_manual <- function(predictions, observed, scoring_method = "manual_hubverse_style") {
  pred_wide <- predictions %>%
    select(
      "scenario_hash", "batch_num", "geo_region", "scenario_label", "disease_R0",
      "vaccine_used", "antiviral_used", "npi_used", "reference_date", "date", "age_group",
      "sample_count", "quantile", "value"
    ) %>%
    mutate(q_col = paste0("q", gsub("\\.", "_", as.character(.data$quantile)))) %>%
    select(-"quantile") %>%
    tidyr::pivot_wider(names_from = "q_col", values_from = "value")

  scored <- pred_wide %>%
    left_join(
      observed,
      by = c("scenario_hash", "batch_num", "geo_region", "scenario_label", "date", "age_group")
    ) %>%
    filter(!is.na(.data$observed))

  interval_alphas <- c(0.02, 0.05, 0.10, 0.20, 0.50)
  for (alpha in interval_alphas) {
    lower_col <- paste0("q", gsub("\\.", "_", as.character(alpha / 2)))
    upper_col <- paste0("q", gsub("\\.", "_", as.character(1 - alpha / 2)))
    score_col <- paste0("interval_score_", round((1 - alpha) * 100))
    cover_col <- paste0("interval_coverage_", round((1 - alpha) * 100))
    lower <- scored[[lower_col]]
    upper <- scored[[upper_col]]
    observed_value <- scored[["observed"]]
    scored[[score_col]] <- upper - lower +
      (2 / alpha) * (lower - observed_value) * (observed_value < lower) +
      (2 / alpha) * (observed_value - upper) * (observed_value > upper)
    scored[[cover_col]] <- observed_value >= lower & observed_value <= upper
  }

  interval_score_cols <- paste0("interval_score_", c(98, 95, 90, 80, 50))
  coverage_cols <- paste0("interval_coverage_", c(98, 95, 90, 80, 50))
  alpha_weights <- interval_alphas / 2

  scored %>%
    rowwise() %>%
    mutate(
      ae_median = abs(.data$q0_5 - .data$observed),
      dispersion = sum(alpha_weights * c_across(all_of(interval_score_cols)), na.rm = TRUE) /
        (length(interval_alphas) + 0.5),
      wis = (0.5 * .data$ae_median + sum(alpha_weights * c_across(all_of(interval_score_cols)), na.rm = TRUE)) /
        (length(interval_alphas) + 0.5),
      overprediction = pmax(.data$q0_5 - .data$observed, 0),
      underprediction = pmax(.data$observed - .data$q0_5, 0),
      bias = sign(.data$q0_5 - .data$observed)
    ) %>%
    ungroup() %>%
    select(
      "scenario_hash", "batch_num", "geo_region", "scenario_label", "disease_R0",
      "vaccine_used", "antiviral_used", "npi_used", "date", "age_group",
      "sample_count", "observed", "q0_5", "wis", "ae_median", "dispersion",
      "overprediction", "underprediction", "bias",
      all_of(interval_score_cols), all_of(coverage_cols)
    ) %>%
    mutate(scoring_method = scoring_method, .after = "sample_count")
}

score_wis_hubevals <- function(predictions, observed) {
  pred_wide <- predictions %>%
    select(
      "scenario_hash", "batch_num", "geo_region", "scenario_label", "disease_R0",
      "vaccine_used", "antiviral_used", "npi_used", "reference_date", "date", "age_group",
      "sample_count", "quantile", "value"
    ) %>%
    mutate(q_col = paste0("q", gsub("\\.", "_", as.character(.data$quantile)))) %>%
    select(-"quantile") %>%
    tidyr::pivot_wider(names_from = "q_col", values_from = "value")

  model_keys <- predictions %>%
    distinct(
      .data$scenario_hash, .data$batch_num, .data$geo_region, .data$scenario_label,
      .data$age_group, .data$reference_date
    ) %>%
    mutate(
      model_id = paste(.data$scenario_hash, .data$batch_num, .data$age_group, sep = "-"),
      location = .data$geo_region,
      hub_target = paste("wk inc flu hosp", .data$age_group, sep = " | ")
    )

  model_out_tbl <- predictions %>%
    inner_join(
      model_keys,
      by = c("scenario_hash", "batch_num", "geo_region", "scenario_label", "age_group", "reference_date")
    ) %>%
    mutate(
      target_end_date = .data$date,
      horizon = as.integer(as.numeric(.data$target_end_date - .data$reference_date) / 7),
      output_type = "quantile",
      output_type_id = .data$quantile
    ) %>%
    transmute(
      .data$model_id, .data$reference_date, .data$horizon, .data$target_end_date,
      .data$location, target = .data$hub_target, .data$output_type, .data$output_type_id,
      value = .data$value
    )

  oracle_output <- observed %>%
    inner_join(
      model_keys,
      by = c("scenario_hash", "batch_num", "geo_region", "scenario_label", "age_group")
    ) %>%
    transmute(
      location = .data$location,
      target = .data$hub_target,
      target_end_date = .data$date,
      oracle_value = .data$observed
    ) %>%
    distinct()

  metrics <- c(
    "wis", "overprediction", "underprediction", "dispersion", "bias", "ae_median",
    "interval_coverage_50", "interval_coverage_80", "interval_coverage_90",
    "interval_coverage_95", "interval_coverage_98"
  )
  hub_scores <- hubEvals::score_model_out(
    model_out_tbl = model_out_tbl,
    oracle_output = oracle_output,
    metrics = metrics,
    summarize = FALSE
  ) %>%
    as_tibble() %>%
    transmute(
      model_id = as.character(.data$model_id),
      date = as.Date(.data$target_end_date),
      wis = .data$wis,
      ae_median = .data$ae_median,
      dispersion = .data$dispersion,
      overprediction = .data$overprediction,
      underprediction = .data$underprediction,
      bias = .data$bias,
      interval_coverage_98 = .data$interval_coverage_98,
      interval_coverage_95 = .data$interval_coverage_95,
      interval_coverage_90 = .data$interval_coverage_90,
      interval_coverage_80 = .data$interval_coverage_80,
      interval_coverage_50 = .data$interval_coverage_50
    )

  pred_wide %>%
    left_join(
      model_keys,
      by = c("scenario_hash", "batch_num", "geo_region", "scenario_label", "age_group", "reference_date")
    ) %>%
    left_join(
      observed,
      by = c("scenario_hash", "batch_num", "geo_region", "scenario_label", "date", "age_group")
    ) %>%
    filter(!is.na(.data$observed)) %>%
    left_join(hub_scores, by = c("model_id", "date")) %>%
    mutate(
      interval_score_98 = NA_real_,
      interval_score_95 = NA_real_,
      interval_score_90 = NA_real_,
      interval_score_80 = NA_real_,
      interval_score_50 = NA_real_,
      scoring_method = "hubEvals::score_model_out",
      .after = "sample_count"
    ) %>%
    select(
      "scenario_hash", "batch_num", "geo_region", "scenario_label", "disease_R0",
      "vaccine_used", "antiviral_used", "npi_used", "date", "age_group",
      "sample_count", "scoring_method", "observed", "q0_5", "wis", "ae_median", "dispersion",
      "overprediction", "underprediction", "bias",
      "interval_score_98", "interval_score_95", "interval_score_90", "interval_score_80", "interval_score_50",
      "interval_coverage_98", "interval_coverage_95", "interval_coverage_90", "interval_coverage_80", "interval_coverage_50"
    )
}

score_wis <- function(predictions, observed) {
  if (requireNamespace("hubEvals", quietly = TRUE)) {
    return(score_wis_hubevals(predictions, observed))
  }
  score_wis_manual(predictions, observed)
}

state_input_features <- function(metadata) {
  metadata %>%
    distinct(
      .data$geo_region,
      .data$data_population,
      .data$data_contact,
      .data$data_high_risk_ratios,
      .data$initial_exposed_json,
      .data$file_path
    ) %>%
    pmap_dfr(function(geo_region, data_population, data_contact, data_high_risk_ratios, initial_exposed_json, file_path) {
      pop_file <- resolve_model_path(data_population, file_path)
      contact_file <- resolve_model_path(data_contact, file_path)
      risk_file <- resolve_model_path(data_high_risk_ratios, file_path)
      if (!file.exists(pop_file) || !file.exists(risk_file)) return(tibble())
      pop <- readr::read_csv(pop_file, show_col_types = FALSE)
      pop_age <- pop %>% summarise(across(all_of(AGE_GROUPS), ~ sum(safe_num(.x), na.rm = TRUE)))
      risk <- as.numeric(readr::read_csv(risk_file, col_names = FALSE, show_col_types = FALSE)[[1]])
      names(risk) <- AGE_GROUPS[seq_along(risk)]
      total_pop <- sum(pop_age[AGE_GROUPS], na.rm = TRUE)
      high_risk_pop <- as.numeric(pop_age[AGE_GROUPS]) * risk[AGE_GROUPS]
      contact_matrix <- if (file.exists(contact_file)) {
        as.matrix(readr::read_csv(contact_file, col_names = FALSE, show_col_types = FALSE))
      } else {
        matrix(NA_real_, nrow = length(AGE_GROUPS), ncol = length(AGE_GROUPS))
      }
      contact_matrix <- apply(contact_matrix, 2, safe_num)
      age_pop_vector <- as.numeric(pop_age[AGE_GROUPS])
      row_contact_rates <- rowSums(contact_matrix, na.rm = TRUE)
      total_initial_exposed <- parse_validation_json(initial_exposed_json) %>%
        as_tibble() %>%
        summarise(total = sum(safe_num(.data$infected), na.rm = TRUE)) %>%
        pull(.data$total)
      tibble(
        geo_region = geo_region,
        state_population = total_pop,
        county_count = nrow(pop),
        high_risk_share_all_age_weighted = sum(high_risk_pop, na.rm = TRUE) / total_pop,
        high_risk_population = sum(high_risk_pop, na.rm = TRUE),
        total_initial_exposed = total_initial_exposed,
        mean_daily_contacts = mean(row_contact_rates, na.rm = TRUE),
        population_weighted_daily_contacts = sum(age_pop_vector * row_contact_rates, na.rm = TRUE) / total_pop,
        contact_matrix_spectral_radius = max(Mod(eigen(contact_matrix, only.values = TRUE)$values), na.rm = TRUE),
        high_risk_share_0_4 = risk[["0-4"]],
        high_risk_share_5_17 = risk[["5-17"]],
        high_risk_share_18_49 = risk[["18-49"]],
        high_risk_share_50_64 = risk[["50-64"]],
        high_risk_share_65_plus = risk[["65+"]]
      )
    }) %>%
    distinct(.data$geo_region, .keep_all = TRUE)
}

mean_vaccinated_percent <- function(vaccine_used, vaccine_runtime_json, vaccine_params_json, sim_days) {
  if (!isTRUE(vaccine_used)) return(NA_real_)

  runtime <- parse_validation_json(vaccine_runtime_json)
  params <- parse_validation_json(vaccine_params_json)
  network_population <- safe_num(runtime$network_population %||% NA_real_)
  if (is.na(network_population) || network_population <= 0) return(NA_real_)

  stockpile_by_day <- runtime$network_stockpile_by_day %||% list()
  if (length(stockpile_by_day) > 0) {
    vaccine_days <- suppressWarnings(as.integer(names(stockpile_by_day)))
    vaccine_amounts <- safe_num(unlist(stockpile_by_day, use.names = FALSE))
  } else {
    vaccine_stockpile <- params$vaccine_stockpile %||% tibble()
    if (is.data.frame(vaccine_stockpile) && nrow(vaccine_stockpile) > 0) {
      vaccine_lag_days <- as.integer(safe_num(params$vaccine_eff_lag_days %||% 0))
      vaccine_days <- as.integer(safe_num(vaccine_stockpile$day)) + vaccine_lag_days
      vaccine_days <- pmax(vaccine_days, 0)
      vaccine_amounts <- safe_num(vaccine_stockpile$amount)
    } else {
      vaccine_days <- integer()
      vaccine_amounts <- numeric()
    }
  }

  keep <- !is.na(vaccine_days) & !is.na(vaccine_amounts) & vaccine_amounts > 0
  vaccine_days <- vaccine_days[keep]
  vaccine_amounts <- vaccine_amounts[keep]
  if (length(vaccine_days) == 0) return(NA_real_)

  sim_days <- as.integer(safe_num(sim_days))
  if (is.na(sim_days) || sim_days <= 0) sim_days <- max(vaccine_days, na.rm = TRUE) + 1L
  days <- 0:(sim_days - 1L)
  cumulative_vaccinated <- vapply(
    days,
    function(day) sum(vaccine_amounts[vaccine_days <= day], na.rm = TRUE),
    numeric(1)
  )
  mean(pmin(cumulative_vaccinated / network_population, 1), na.rm = TRUE) * 100
}

scenario_vaccine_features <- function(metadata) {
  metadata %>%
    distinct(
      .data$geo_region,
      .data$scenario_label,
      .data$scenario_hash,
      .data$vaccine_used,
      .data$vaccine_runtime_json,
      .data$vaccine_params_json,
      .data$sim_days
    ) %>%
    mutate(
      mean_percent_pop_vaccinated = pmap_dbl(
        select(., "vaccine_used", "vaccine_runtime_json", "vaccine_params_json", "sim_days"),
        \(vaccine_used, vaccine_runtime_json, vaccine_params_json, sim_days) {
          mean_vaccinated_percent(vaccine_used, vaccine_runtime_json, vaccine_params_json, sim_days)
        }
      ),
      batch_num = "ALL_BATCHES"
    ) %>%
    select("geo_region", "scenario_label", "scenario_hash", "batch_num", "mean_percent_pop_vaccinated")
}

state_dir_to_name <- function(state_dir) {
  stringr::str_replace_all(state_dir, "-", " ")
}

state_dir_to_abbr <- function(state_dir) {
  state_name <- state_dir_to_name(state_dir)
  abbr <- setNames(state.abb, state.name)[state_name]
  abbr[state_name == "District of Columbia"] <- "DC"
  unname(ifelse(is.na(abbr), state_dir, abbr))
}

first_nonmissing <- function(x, default = NA) {
  x <- x[!is.na(x) & nzchar(as.character(x))]
  if (length(x) == 0) default else x[[1]]
}

format_ve_label <- function(x) {
  label_value <- round(safe_num(x) * 100, 0)
  ifelse(is.na(label_value), "NA", as.character(label_value))
}

save_vaccine_coverage_figures <- function(metadata) {
  vaccine_file <- file.path(repo_root, "data", "VACCINATION", "all_US_weekly_vax_adult-ped.csv")
  if (!file.exists(vaccine_file)) {
    warning("Vaccine coverage summary not found: ", vaccine_file)
    return(tibble())
  }

  states_to_plot <- metadata %>%
    distinct(.data$geo_region, .data$metadata_sim_day_0) %>%
    transmute(
      geo_region = .data$geo_region,
      State = state_dir_to_name(.data$geo_region),
      sim_day_0 = as.Date(.data$metadata_sim_day_0)
    ) %>%
    group_by(.data$geo_region, .data$State) %>%
    summarise(
      sim_day_0 = first_nonmissing(.data$sim_day_0[order(.data$sim_day_0)], as.Date(NA)),
      .groups = "drop"
    )

  vaccine_coverage <- readr::read_csv(vaccine_file, show_col_types = FALSE) %>%
    mutate(
      WeekEnd = as.Date(.data$WeekEnd),
      VaxCov = safe_num(.data$VaxCov),
      total_pop = safe_num(.data$total_pop),
      TotalVax = safe_num(.data$TotalVax),
      TotalFullProtect = safe_num(.data$TotalFullProtect),
      WeeklyNewFullProtect = safe_num(.data$WeeklyNewFullProtect),
      VE_Inpatient = safe_num(.data$VE_Inpatient)
    ) %>%
    inner_join(states_to_plot, by = "State") %>%
    arrange(.data$State, .data$AgeGroup, .data$WeekEnd)

  if (nrow(vaccine_coverage) == 0) {
    warning("No vaccine coverage rows matched validation states.")
    return(tibble())
  }

  vaccine_summary <- vaccine_coverage %>%
    group_by(.data$geo_region, .data$State, .data$AgeGroup) %>%
    summarise(
      first_week = min(.data$WeekEnd, na.rm = TRUE),
      last_week = max(.data$WeekEnd, na.rm = TRUE),
      sim_day_0 = first_nonmissing(as.character(.data$sim_day_0)),
      vaccine_effectiveness = first_nonmissing(.data$VE_Inpatient),
      final_coverage = dplyr::last(.data$VaxCov[order(.data$WeekEnd)]),
      final_doses_given = dplyr::last(.data$TotalVax[order(.data$WeekEnd)]),
      final_full_protection_count = dplyr::last(.data$TotalFullProtect[order(.data$WeekEnd)]),
      total_new_full_protection = sum(.data$WeeklyNewFullProtect, na.rm = TRUE),
      .groups = "drop"
    )

  for (state in sort(unique(vaccine_coverage$State))) {
    state_data <- vaccine_coverage %>% filter(.data$State == state)
    state_dir <- state_data$geo_region[[1]]
    state_day0 <- as.Date(first_nonmissing(as.character(state_data$sim_day_0), NA_character_))
    state_dose_long <- state_data %>%
      mutate(AgeGroupVE = paste0(.data$AgeGroup, ", VE=", format_ve_label(.data$VE_Inpatient), "%")) %>%
      pivot_longer(c("TotalVax", "TotalFullProtect"), names_to = "Series", values_to = "Value") %>%
      mutate(
        Series = recode(
          .data$Series,
          TotalVax = "Doses Given",
          TotalFullProtect = "Doses 100% VE"
        )
      )
    age_labels <- state_dose_long %>%
      distinct(.data$AgeGroup, .data$AgeGroupVE) %>%
      arrange(match(.data$AgeGroup, c("Adult", "Pediatric")))
    age_colors <- setNames(
      ifelse(age_labels$AgeGroup == "Adult", "#CD622E", "#4499F5"),
      age_labels$AgeGroupVE
    )
    y_top <- max(state_dose_long$Value, na.rm = TRUE) * 0.8
    if (!is.finite(y_top)) y_top <- 0
    x_min <- min(state_dose_long$WeekEnd, state_day0, na.rm = TRUE) - 14
    x_max <- max(state_dose_long$WeekEnd, state_day0, na.rm = TRUE) + 7

    p <- ggplot(
      state_dose_long,
      aes(
        x = .data$WeekEnd,
        y = .data$Value,
        color = .data$AgeGroupVE,
        linetype = .data$Series,
        group = interaction(.data$AgeGroupVE, .data$Series)
      )
    ) +
      geom_line(linewidth = 1.9) +
      geom_vline(
        xintercept = state_day0,
        linetype = "dotted",
        color = "grey30",
        linewidth = 1.0,
        show.legend = FALSE
      ) +
      annotate(
        "label",
        x = state_day0 + 7,
        y = y_top,
        label = "Sim Day 0",
        hjust = 0,
        vjust = -0.4,
        color = "grey30",
        fontface = "bold",
        size = 8
      ) +
      scale_color_manual(values = age_colors, name = NULL) +
      scale_linetype_manual(
        values = c("Doses Given" = "solid", "Doses 100% VE" = "dashed"),
        name = NULL,
        breaks = c("Doses Given", "Doses 100% VE")
      ) +
      scale_y_continuous(
        labels = scales::label_number(accuracy = 1, scale_cut = scales::cut_short_scale())
      ) +
      scale_x_date(limits = c(x_min, x_max), expand = expansion(mult = c(0.02, 0.03))) +
      coord_cartesian(clip = "off") +
      guides(
        color = guide_legend(order = 1, override.aes = list(linetype = "solid", linewidth = 3.2)),
        linetype = guide_legend(
          order = 2,
          override.aes = list(color = "black", linewidth = 2.4, linetype = c("solid", "dashed"))
        )
      ) +
      labs(
        x = "Week Ending Date",
        y = "2025-26 Influenza Vaccine Doses",
        title = state
      ) +
      theme_bw(base_size = 24) +
      theme(
        plot.title = element_text(size = 42),
        axis.title = element_text(size = 32),
        axis.text = element_text(size = 26),
        legend.text = element_text(size = 22),
        legend.key.width = grid::unit(1.6, "cm"),
        legend.position = "bottom"
      )

    state_file <- paste0(state_dir, "_VE_ts.png")
    ggsave(file.path(VACCINE_PLOT_DIR, state_file), p, width = 16, height = 10, bg = "white", units = "in", dpi = 300)
  }

  vaccine_summary
}

save_high_risk_heatmap <- function(metadata) {
  high_risk_file <- file.path(repo_root, "data", "RISK_RATIOS", "all_US_high-risk-ratios-detailed.csv")
  if (!file.exists(high_risk_file)) {
    warning("High-risk ratio detail file not found: ", high_risk_file)
    return(invisible(NULL))
  }

  states_to_plot <- metadata %>%
    distinct(.data$geo_region) %>%
    transmute(STATE_NAME = state_dir_to_name(.data$geo_region))

  high_risk_age <- readr::read_csv(high_risk_file, show_col_types = FALSE) %>%
    inner_join(states_to_plot, by = "STATE_NAME") %>%
    mutate(
      age_group = factor(.data$age_group, levels = AGE_GROUPS),
      frac_high_risk = safe_num(.data$frac_high_risk)
    )

  if (nrow(high_risk_age) == 0) {
    warning("No high-risk ratio rows matched validation states.")
    return(invisible(NULL))
  }

  p <- ggplot(high_risk_age, aes(x = .data$age_group, y = .data$STATE_NAME, fill = .data$frac_high_risk * 100)) +
    geom_tile(color = "white") +
    geom_text(aes(label = round(.data$frac_high_risk * 100, 0)), color = "black", size = 4.5) +
    scale_y_discrete(limits = function(x) rev(x)) +
    scale_fill_gradientn(
      colors = high_risk_palette,
      name = "% High Risk",
      limits = c(0, 100)
    ) +
    labs(x = NULL, y = NULL) +
    guides(fill = guide_colourbar(barheight = 0.5, barwidth = 20)) +
    theme_classic(base_size = 18) +
    theme(legend.position = "bottom")

  ggsave(file.path(PLOT_DIR, "high_risk_heatmap.png"), p, width = 8, height = 11, bg = "white", units = "in", dpi = 300)
  invisible(high_risk_age)
}

message("Reading metadata: ", MASTER_CSV)
metadata <- readr::read_csv(MASTER_CSV, show_col_types = FALSE) %>%
  mutate(
    scenario_label = pmap_chr(
      select(., "vaccine_used", "antiviral_used", "npi_used", "metadata_notes", "output_dir_path", "file_path"),
      \(vaccine_used, antiviral_used, npi_used, metadata_notes, output_dir_path, file_path) {
        scenario_label(list(
          vaccine_used = vaccine_used,
          antiviral_used = antiviral_used,
          npi_used = npi_used,
          metadata_notes = metadata_notes,
          output_dir_path = output_dir_path,
          file_path = file_path
        ))
      }
    )
  ) %>%
  filter(
    .data$validation_used,
    !is.na(.data$scenario_hash),
    nzchar(.data$scenario_hash),
    file.exists(file.path(PARQUET_ROOT, .data$scenario_hash))
  )

if (nzchar(OUTPUT_SOURCE_REGEX)) {
  metadata <- metadata %>%
    filter(str_detect(
      paste(.data$file_path, .data$output_dir_path, sep = " "),
      regex(OUTPUT_SOURCE_REGEX, ignore_case = TRUE)
    ))
  message("Filtered metadata by output source regex '", OUTPUT_SOURCE_REGEX, "': ", nrow(metadata), " row(s)")
}

if (nzchar(SCENARIO_REGEX)) {
  metadata <- metadata %>%
    filter(str_detect(.data$scenario_label, regex(SCENARIO_REGEX, ignore_case = TRUE)))
}

metadata <- metadata %>%
  arrange(.data$geo_region, .data$scenario_label, desc(.data$created_at_utc)) %>%
  group_by(.data$geo_region, .data$scenario_label, .data$scenario_hash) %>%
  slice(1) %>%
  ungroup()

if (!is.na(MAX_SCENARIOS) && MAX_SCENARIOS > 0) {
  metadata <- head(metadata, MAX_SCENARIOS)
}

message("Scenarios to score: ", nrow(metadata))

save_state_compartment_spaghetti_plots(metadata)

predictions <- pmap_dfr(metadata, function(...) {
  row <- list(...)
  message("Quantiles: ", row$geo_region, " / ", scenario_label(row), " / ", substr(row$scenario_hash, 1, 8))
  tryCatch(
    quantile_predictions(row),
    error = function(e) {
      warning(sprintf("Prediction extraction failed for %s / %s: %s", row$geo_region, row$scenario_hash, e$message))
      tibble()
    }
  )
})

observed <- pmap_dfr(metadata, function(...) {
  row <- list(...)
  observed_by_age(row) %>%
    mutate(
      scenario_hash = row$scenario_hash,
      batch_num = "ALL_BATCHES",
      geo_region = row$geo_region,
      scenario_label = scenario_label(row),
      .before = 1
    )
})
observed_all <- observed %>%
  group_by(.data$scenario_hash, .data$batch_num, .data$geo_region, .data$scenario_label, .data$date) %>%
  summarise(observed = sum(.data$observed, na.rm = TRUE), .groups = "drop") %>%
  mutate(age_group = "all")
observed <- bind_rows(observed, observed_all)

scores <- score_wis(predictions, observed)

summary_scores <- scores %>%
  group_by(
    .data$geo_region,
    .data$scenario_label,
    .data$scenario_hash,
    .data$batch_num,
    .data$age_group
  ) %>%
  summarise(
    disease_R0 = dplyr::first(.data$disease_R0),
    n_weeks = n(),
    mean_wis = mean(.data$wis, na.rm = TRUE),
    median_wis = median(.data$wis, na.rm = TRUE),
    mean_ae_median = mean(.data$ae_median, na.rm = TRUE),
    mean_dispersion = mean(.data$dispersion, na.rm = TRUE),
    mean_overprediction = mean(.data$overprediction, na.rm = TRUE),
    mean_underprediction = mean(.data$underprediction, na.rm = TRUE),
    coverage_50 = mean(.data$interval_coverage_50, na.rm = TRUE),
    coverage_80 = mean(.data$interval_coverage_80, na.rm = TRUE),
    coverage_90 = mean(.data$interval_coverage_90, na.rm = TRUE),
    coverage_95 = mean(.data$interval_coverage_95, na.rm = TRUE),
    coverage_98 = mean(.data$interval_coverage_98, na.rm = TRUE),
    observed_total = sum(.data$observed, na.rm = TRUE),
    predicted_median_total = sum(.data$q0_5, na.rm = TRUE),
    total_ratio = (.data$predicted_median_total + 1) / (.data$observed_total + 1),
    observed_peak_date = .data$date[which.max(.data$observed)][[1]],
    predicted_peak_date = .data$date[which.max(.data$q0_5)][[1]],
    peak_lag_weeks = as.numeric(.data$predicted_peak_date - .data$observed_peak_date) / 7,
    .groups = "drop"
  ) %>%
  left_join(state_input_features(metadata), by = "geo_region") %>%
  left_join(
    scenario_vaccine_features(metadata),
    by = c("geo_region", "scenario_label", "scenario_hash", "batch_num")
  )

state_order <- summary_scores %>%
  distinct(.data$geo_region, .data$county_count) %>%
  arrange(.data$county_count, .data$geo_region) %>%
  pull(.data$geo_region)

state_order_population <- summary_scores %>%
  distinct(.data$geo_region, .data$state_population) %>%
  arrange(.data$state_population, .data$geo_region) %>%
  pull(.data$geo_region)

scenario_display_labeller <- as_labeller(SCENARIO_DISPLAY)
SCENARIO_DISPLAY_NUMBERED <- setNames(
  paste(seq_along(SCENARIO_DISPLAY), SCENARIO_DISPLAY),
  names(SCENARIO_DISPLAY)
)

compact_feature_axis_label <- function(x) {
  finite_x <- x[is.finite(x)]
  if (length(finite_x) > 0 && max(abs(finite_x), na.rm = TRUE) >= 1000) {
    return(scales::label_number(accuracy = 1, scale_cut = scales::cut_short_scale())(x))
  }
  if (length(finite_x) > 0 && any(abs(finite_x - round(finite_x)) > 0.001, na.rm = TRUE)) {
    labels <- scales::label_number(accuracy = 0.1, trim = TRUE)(x)
    return(sub("\\.0$", "", labels))
  }
  scales::label_number(accuracy = 1, trim = TRUE)(x)
}

feature_axis_breaks <- function(limits) {
  limits <- limits[is.finite(limits)]
  if (length(limits) < 2) return(limits)
  panel_range <- range(limits)
  lower <- if (panel_range[[1]] < 0 && panel_range[[2]] > 0) 0 else panel_range[[1]]
  upper <- panel_range[[2]]
  span <- upper - lower
  if (!is.finite(span) || span <= 0) return(lower)
  inner_breaks <- scales::breaks_pretty(n = 3)(c(lower, upper))
  inner_breaks <- inner_breaks[
    inner_breaks > lower + 0.12 * span &
      inner_breaks < upper - 0.12 * span
  ]
  sort(unique(c(lower, inner_breaks, upper)))
}

readr::write_csv(predictions, file.path(SCORE_DIR, "hubverse_quantile_predictions.csv"))
readr::write_csv(scores, file.path(SCORE_DIR, "hubverse_wis_scores_by_age_week.csv"))
readr::write_csv(summary_scores, file.path(SCORE_DIR, "hubverse_wis_summary.csv"))

prepare_plot_summary <- function(order_levels) {
  summary_scores %>%
    filter(.data$age_group == "all") %>%
    mutate(
      geo_region = factor(.data$geo_region, levels = order_levels),
      scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER)
    ) %>%
    filter(!is.na(.data$scenario_label))
}

prepare_age_plot_data <- function(order_levels) {
  summary_scores %>%
    filter(.data$age_group != "all") %>%
    mutate(
      geo_region = factor(.data$geo_region, levels = order_levels),
      scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER)
    ) %>%
    filter(!is.na(.data$scenario_label))
}

collapse_batches_for_feature_plot <- function(plot_data) {
  plot_data %>%
    group_by(.data$geo_region, .data$scenario_label) %>%
    summarise(
      mean_wis = mean(.data$mean_wis, na.rm = TRUE),
      county_count = dplyr::first(.data$county_count),
      disease_R0 = mean(.data$disease_R0, na.rm = TRUE),
      total_initial_exposed = mean(.data$total_initial_exposed, na.rm = TRUE),
      state_population = dplyr::first(.data$state_population),
      population_weighted_daily_contacts = dplyr::first(.data$population_weighted_daily_contacts),
      mean_percent_pop_vaccinated = ifelse(
        all(is.na(.data$mean_percent_pop_vaccinated)),
        0,
        mean(.data$mean_percent_pop_vaccinated, na.rm = TRUE)
      ),
      .groups = "drop"
    )
}

save_state_wis_heatmap <- function(plot_data, filename, title) {
  p <- ggplot(plot_data, aes(x = scenario_label, y = geo_region, fill = mean_wis)) +
    geom_tile(color = "white", linewidth = 0.35) +
    scale_fill_gradientn(colors = high_risk_palette) +
    scale_x_discrete(labels = SCENARIO_DISPLAY, drop = FALSE) +
    labs(x = NULL, y = NULL, fill = "Mean WIS", title = title) +
    theme_minimal(base_size = 18) +
    theme(
      axis.text.x = element_text(angle = 35, hjust = 1, size = 16),
      axis.text.y = element_text(size = 16),
      plot.title = element_text(face = "bold", size = 22),
      legend.title = element_text(size = 17),
      legend.text = element_text(size = 15),
      panel.grid = element_blank()
    )
  ggsave(file.path(PLOT_DIR, filename), p, width = 12, height = 8.5, dpi = 300)
}

save_age_wis_heatmap <- function(age_plot_data, order_levels, filename, title) {
  p <- ggplot(age_plot_data, aes(x = scenario_label, y = geo_region, fill = mean_wis)) +
    geom_tile(color = "white", linewidth = 0.25) +
    facet_wrap(~ age_group, nrow = 1) +
    scale_fill_gradientn(colors = high_risk_palette) +
    scale_x_discrete(labels = SCENARIO_DISPLAY, drop = FALSE) +
    labs(x = NULL, y = NULL, fill = "Mean WIS", title = title) +
    theme_minimal(base_size = 16) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1, size = 14),
      axis.text.y = element_text(size = 14),
      plot.title = element_text(face = "bold", size = 22),
      panel.grid = element_blank(),
      strip.text = element_text(face = "bold", size = 17),
      legend.title = element_text(size = 16),
      legend.text = element_text(size = 14)
    )
  ggsave(
    file.path(PLOT_DIR, filename),
    p,
    width = 18,
    height = max(8, 0.24 * length(order_levels) + 3),
    dpi = 300
  )
}

plot_summary <- prepare_plot_summary(state_order)

if (nrow(plot_summary) > 0) {
  save_state_wis_heatmap(
    plot_summary,
    "wis_by_state_scenario.png",
    "Hubverse-Style WIS by State and Scenario, Ordered by County Count"
  )
  save_state_wis_heatmap(
    prepare_plot_summary(state_order_population),
    "wis_by_state_scenario_by_population.png",
    "Hubverse-Style WIS by State and Scenario, Ordered by Population"
  )
  save_age_wis_heatmap(
    prepare_age_plot_data(state_order),
    state_order,
    "wis_by_age_scenario.png",
    "Age-Specific Hubverse-Style WIS, Ordered by County Count"
  )
  save_age_wis_heatmap(
    prepare_age_plot_data(state_order_population),
    state_order_population,
    "wis_by_age_scenario_by_population.png",
    "Age-Specific Hubverse-Style WIS, Ordered by Population"
  )

  p <- ggplot(plot_summary, aes(x = scenario_label, y = geo_region, fill = peak_lag_weeks)) +
    geom_tile(color = "white", linewidth = 0.35) +
    scale_fill_gradient2(low = "#2166ac", mid = "white", high = "#b2182b", midpoint = 0) +
    scale_x_discrete(labels = SCENARIO_DISPLAY, drop = FALSE) +
    labs(x = NULL, y = NULL, fill = "Weeks", title = "Peak Timing Lag: Predicted Median vs Observed") +
    theme_minimal(base_size = 18) +
    theme(
      axis.text.x = element_text(angle = 35, hjust = 1, size = 16),
      axis.text.y = element_text(size = 16),
      plot.title = element_text(face = "bold", size = 22),
      legend.title = element_text(size = 17),
      legend.text = element_text(size = 15),
      panel.grid = element_blank()
    )
  ggsave(file.path(PLOT_DIR, "peak_lag_by_state_scenario.png"), p, width = 12, height = 8.5, dpi = 300)

  p <- plot_summary %>%
    collapse_batches_for_feature_plot() %>%
    select(
      "geo_region", "scenario_label", "mean_wis", "county_count",
      "disease_R0", "total_initial_exposed", "state_population",
      "population_weighted_daily_contacts", "mean_percent_pop_vaccinated"
    ) %>%
    pivot_longer(
      cols = c(
        "county_count",
        "disease_R0",
        "total_initial_exposed",
        "state_population",
        "population_weighted_daily_contacts",
        "mean_percent_pop_vaccinated"
      ),
      names_to = "feature",
      values_to = "feature_value"
    ) %>%
    mutate(
      feature = factor(
        .data$feature,
        levels = c(
          "county_count",
          "state_population",
          "total_initial_exposed",
          "disease_R0",
          "population_weighted_daily_contacts",
          "mean_percent_pop_vaccinated"
        ),
        labels = c(
          "Total counties",
          "State population",
          "Total initial exposed",
          "R_m",
          "Population-weighted daily contacts",
          "Mean percent of population vaccinated"
        )
      )
	    ) %>%
	    filter(
	      .data$feature != "Mean percent of population vaccinated" |
	        as.character(.data$scenario_label) %in% c("VACCINE", "VACCINE+ANTIVIRAL+NPI")
	    ) %>%
	    ggplot(aes(x = feature_value, y = mean_wis, color = scenario_label)) +
	    geom_smooth(method = "lm", se = FALSE, linewidth = 0.75) +
	    geom_text(
	      aes(label = state_dir_to_abbr(as.character(.data$geo_region))),
	      size = 5,
	      fontface = "bold",
	      show.legend = FALSE
	    ) +
	    scale_x_continuous(
	      breaks = feature_axis_breaks,
	      labels = compact_feature_axis_label,
	      expand = expansion(mult = c(0.025, 0.045))
	    ) +
	    scale_color_manual(values = SCENARIO_COLORS, labels = SCENARIO_DISPLAY_NUMBERED, drop = FALSE) +
	    facet_wrap(~ feature, scales = "free_x", axes = "margins", strip.position = "bottom") +
	    labs(x = NULL, y = "Mean WIS", color = NULL, title = "Score vs Model Input Features") +
	    theme_minimal(base_size = 18) +
	    theme(
	      axis.text.x = element_text(size = 15),
	      axis.text.y = element_text(size = 15),
	      axis.title.y = element_text(size = 18),
	      plot.title = element_text(face = "bold", size = 22),
	      strip.text = element_text(size = 17),
	      strip.placement = "outside",
	      legend.text = element_text(size = 16),
	      panel.spacing.x = grid::unit(3.2, "lines"),
	      panel.spacing.y = grid::unit(2.2, "lines")
	    )
	  ggsave(file.path(PLOT_DIR, "wis_vs_input_features.png"), p, width = 19, height = 9.5, dpi = 300)

  trajectory_data <- predictions %>%
    filter(.data$age_group == "all", .data$quantile %in% c(0.025, 0.5, 0.975)) %>%
    mutate(q_col = paste0("q", gsub("\\.", "_", as.character(.data$quantile)))) %>%
    select(
      "geo_region", "scenario_label", "scenario_hash", "batch_num",
      "disease_R0", "date", "q_col", "value"
    ) %>%
    tidyr::pivot_wider(names_from = "q_col", values_from = "value") %>%
    mutate(scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER)) %>%
    filter(!is.na(.data$scenario_label)) %>%
    left_join(
      plot_summary %>%
        mutate(scenario_label = as.character(.data$scenario_label)) %>%
        transmute(
          geo_region = as.character(.data$geo_region),
          scenario_label,
          scenario_hash = as.character(.data$scenario_hash),
          batch_num = as.character(.data$batch_num),
          scenario_legend = paste0(
            SCENARIO_DISPLAY[scenario_label],
            " (WIS ",
            format(round(.data$mean_wis, 1), nsmall = 1),
            ")"
          )
        ),
      by = c("geo_region", "scenario_label", "scenario_hash", "batch_num")
    )

  observed_state <- observed %>%
    filter(.data$age_group == "all") %>%
    distinct(.data$geo_region, .data$date, .data$observed)

  for (state in sort(unique(trajectory_data$geo_region))) {
    state_trajectory <- trajectory_data %>%
      filter(.data$geo_region == state) %>%
      mutate(
        scenario_label_chr = as.character(.data$scenario_label),
        scenario_key = paste0(.data$scenario_label_chr, "::", substr(.data$scenario_hash, 1, 8)),
        scenario_order = match(.data$scenario_label_chr, SCENARIO_ORDER)
      )
    state_observed <- observed_state %>%
      filter(.data$geo_region == state)
    legend_labels <- state_trajectory %>%
      distinct(.data$scenario_key, .data$scenario_label_chr, .data$scenario_order, .data$scenario_legend) %>%
      arrange(.data$scenario_order, .data$scenario_key)
    legend_breaks <- as.character(legend_labels$scenario_key)
    legend_values <- stats::setNames(
      SCENARIO_COLORS[legend_labels$scenario_label_chr],
      legend_breaks
    )
    names(legend_values) <- legend_breaks
    legend_label_values <- as.character(legend_labels$scenario_legend)
    names(legend_label_values) <- legend_breaks
    state_r0 <- state_trajectory %>%
      distinct(.data$disease_R0) %>%
      pull(.data$disease_R0) %>%
      discard(is.na)
    state_r0_label <- paste0(
      "R_m = ",
      paste(format(round(state_r0, 2), nsmall = 2), collapse = ", ")
    )
    state_r0_label_data <- tibble(
      label = state_r0_label,
      label_x = max(state_trajectory$date, na.rm = TRUE)
    )

    p <- ggplot(state_trajectory, aes(x = date)) +
      geom_ribbon(aes(ymin = q0_025, ymax = q0_975, fill = scenario_key), alpha = 0.16, color = NA) +
      geom_line(aes(y = q0_5, color = scenario_key), linewidth = 0.85) +
      geom_point(
        data = state_observed,
        aes(x = date, y = observed),
        inherit.aes = FALSE,
        color = "#d73027",
        size = 2.8,
        alpha = 0.9
      ) +
      geom_label(
        data = state_r0_label_data,
        aes(x = label_x, y = Inf, label = label),
        inherit.aes = FALSE,
        hjust = 1.05,
        vjust = 1.25,
        size = 5,
        linewidth = 0.2,
        fill = "white"
      ) +
      scale_color_manual(
        values = legend_values,
        breaks = legend_breaks,
        labels = legend_label_values,
        drop = FALSE
      ) +
      scale_fill_manual(
        values = legend_values,
        breaks = legend_breaks,
        labels = legend_label_values,
        drop = FALSE
      ) +
      labs(
        x = NULL,
        y = "Weekly incident hospitalizations",
        title = paste0(state, ": Validation Data vs Scenario Forecasts"),
        subtitle = "Red dots are validation data; ribbons are simulation 2.5%-97.5% quantiles; lines are medians",
        color = NULL,
        fill = NULL
      ) +
      guides(
        fill = "none",
        color = guide_legend(nrow = 2, byrow = TRUE, override.aes = list(linewidth = 1.1, alpha = 1))
      ) +
      theme_minimal(base_size = 28) +
      theme(
        panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold", size = 28),
        plot.subtitle = element_text(size = 20),
        axis.text = element_text(size = 30),
        axis.title.y = element_text(size = 34, margin = margin(r = 14)),
        legend.text = element_text(size = 22),
        legend.position = "bottom",
        legend.box = "vertical",
        legend.key.width = grid::unit(1.3, "cm"),
        plot.margin = margin(12, 18, 12, 18)
      )

    state_file <- paste0(str_replace_all(state, "[^A-Za-z0-9]+", "_"), "_scenario_validation.png")
    ggsave(
      file.path(STATE_TRAJECTORY_DIR, state_file),
      p,
      width = 16,
      height = 9,
      units = "in",
      dpi = 300,
      bg = "white"
    )
  }
}

message("Wrote scores and plots to: ", SCORE_DIR)
