#////////
#### Script Overview ####
#////////
#' Check state-age initial exposed estimates for candidate simulation start dates.
#'
#' This is a diagnostic companion to `5a_derive_initial_exposures.R`. It uses the
#' same Flu Hub age-stratified weekly incident hospitalization data and the same
#' low-risk exposed-to-hospitalization probability, but reports sensitivity to how
#' the weekly Hub count is placed within its Sun-Sat MMWR week.
#'
#' Example:
#'   Rscript scripts/5a_check_initial_exposed_sensitivity.R \
#'     --sim-start-date=2025-10-01,2025-10-04 \
#'     --states=Delaware,California \
#'     --output=STATE_INIT_TEST/initial_exposed_sensitivity_oct1_oct4.csv
#////////
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
  library(stringr)
  library(jsonlite)
  library(tigris)
  library(ggplot2)
})

SIM_START_DATES <- c("2025-10-01", "2025-10-04")
HOSPITALIZATION_FILE <- file.path("data", "FLU_HUB", "time-series_2026-07-13.csv")
TEMPLATE_FILE <- file.path("data", "INPUT_FILE_TEMPLATES", "INPUT_SEIHRD-STOCH_STATE_NONE_H3N2.json")
LOWRISK_HOSP_RATE_FILE <- NA_character_
OUTPUT_FILE <- file.path("STATE_INIT_TEST", "initial_exposed_sensitivity.csv")
STATE_FILTER <- NA_character_
MIN_TIMING_WEIGHT <- 0.25
MIN_STATE_EXPOSED_PER_ACTIVE_AGE <- 1L
PRINT_TOP_N <- 25L
PLOT_RESULTS <- TRUE

age_order <- c("0-4", "5-17", "18-49", "50-64", "65+")

cmd_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd_args, value = TRUE)
script_path <- if (length(file_arg) > 0) sub("^--file=", "", file_arg[[1]]) else ""
script_dir <- if (nzchar(script_path)) dirname(normalizePath(script_path, mustWork = FALSE)) else getwd()

if (dir.exists(file.path(script_dir, "data"))) {
  repo_root <- normalizePath(script_dir, mustWork = TRUE)
} else if (dir.exists(file.path(script_dir, "..", "data"))) {
  repo_root <- normalizePath(file.path(script_dir, ".."), mustWork = TRUE)
} else {
  stop("Could not find repository root from working directory or script location.")
}

trailing_args <- commandArgs(trailingOnly = TRUE)
get_arg_value <- function(prefix, default) {
  match <- trailing_args[startsWith(trailing_args, prefix)]
  if (length(match) == 0) {
    return(default)
  }
  sub(prefix, "", match[[1]], fixed = TRUE)
}

split_arg <- function(x) {
  x |>
    stringr::str_split(",", simplify = FALSE) |>
    unlist(use.names = FALSE) |>
    stringr::str_trim() |>
    (\(v) v[nzchar(v)])()
}

abs_path <- function(path) {
  if (grepl("^/", path)) {
    normalizePath(path, mustWork = FALSE)
  } else {
    normalizePath(file.path(repo_root, path), mustWork = FALSE)
  }
}

sim_start_dates <- as.Date(split_arg(get_arg_value("--sim-start-date=", paste(SIM_START_DATES, collapse = ","))))
hospitalization_file <- abs_path(get_arg_value("--hosp-file=", HOSPITALIZATION_FILE))
template_file <- abs_path(get_arg_value("--template=", TEMPLATE_FILE))
lowrisk_hosp_rate_file <- get_arg_value("--lowrisk-hosp-rate-file=", LOWRISK_HOSP_RATE_FILE)
lowrisk_hosp_rate_file <- if (!is.na(lowrisk_hosp_rate_file) && nzchar(lowrisk_hosp_rate_file)) {
  abs_path(lowrisk_hosp_rate_file)
} else {
  NA_character_
}
output_file <- abs_path(get_arg_value("--output=", OUTPUT_FILE))
state_filter <- split_arg(get_arg_value("--states=", STATE_FILTER))
print_top_n <- as.integer(get_arg_value("--print-top=", as.character(PRINT_TOP_N)))
plot_results <- tolower(get_arg_value("--plot=", as.character(PLOT_RESULTS))) %in% c("true", "t", "1", "yes", "y")

json_numeric_vector <- function(x, expected_length = length(age_order), label = deparse(substitute(x))) {
  out <- as.numeric(unlist(x, use.names = FALSE))
  if (length(out) != expected_length || anyNA(out)) {
    stop("Template parameter ", label, " must contain ", expected_length, " numeric values.")
  }
  stats::setNames(out, age_order)
}

json_numeric_scalar <- function(x, label = deparse(substitute(x))) {
  out <- as.numeric(unlist(x, use.names = FALSE)[[1]])
  if (length(out) != 1 || is.na(out)) {
    stop("Template parameter ", label, " must be numeric.")
  }
  out
}

read_labeled_age_rate_csv <- function(path, value_col, expected_ages = age_order) {
  rates <- readr::read_csv(path, show_col_types = FALSE) |>
    dplyr::mutate(
      age_group = as.character(.data$age_group),
      age_group_index = as.integer(.data$age_group_index),
      value = as.numeric(.data[[value_col]])
    ) |>
    dplyr::arrange(.data$age_group_index)

  if (!identical(rates$age_group, expected_ages)) {
    stop("Age groups in ", path, " must match model age order: ", paste(expected_ages, collapse = ", "))
  }
  stats::setNames(rates$value, rates$age_group)
}

first_complete_mmwr_week_end <- function(start_date) {
  start_date <- as.Date(start_date)
  days_until_saturday <- (6L - as.POSIXlt(start_date)$wday) %% 7L
  week_end <- start_date + days_until_saturday
  week_start <- week_end - 6L
  if (week_start < start_date) {
    week_end <- week_end + 7L
  }
  week_end
}

timing_weight <- function(days_from_start, exposed_to_hosp_days) {
  MIN_TIMING_WEIGHT + (1 - MIN_TIMING_WEIGHT) * exp(-days_from_start / exposed_to_hosp_days)
}

estimate_for_row <- function(sim_start_date,
                             week_end,
                             weekly_inc_hosp,
                             exposed_to_hosp_probability,
                             exposed_to_hosp_days,
                             method) {
  week_start <- week_end - 6L
  week_days <- seq.Date(week_start, week_end, by = "day")

  if (method == "current_5a_week_end_point") {
    admission_dates <- week_end
    admissions <- weekly_inc_hosp
  } else if (method == "all_prior_sunday") {
    admission_dates <- week_start
    admissions <- weekly_inc_hosp
  } else if (method == "all_saturday_week_end") {
    admission_dates <- week_end
    admissions <- weekly_inc_hosp
  } else if (method == "uniform_full_mmwr_week") {
    admission_dates <- week_days
    admissions <- rep(weekly_inc_hosp / 7, length(week_days))
  } else if (method == "uniform_on_or_after_start") {
    admission_dates <- week_days[week_days >= sim_start_date]
    admissions <- rep(weekly_inc_hosp / 7, length(admission_dates))
  } else {
    stop("Unknown timing method: ", method)
  }

  if (length(admission_dates) == 0 || sum(admissions, na.rm = TRUE) <= 0) {
    return(tibble(
      method = method,
      admission_days_used = 0L,
      admissions_used = 0,
      mean_days_from_start = NA_real_,
      timing_weighted_admissions = 0,
      raw_initial_exposed = 0,
      initial_exposed = 0L
    ))
  }

  days_from_start <- as.numeric(admission_dates - sim_start_date)
  weights <- timing_weight(days_from_start, exposed_to_hosp_days)
  raw_initial_exposed <- sum(admissions * weights, na.rm = TRUE) / exposed_to_hosp_probability

  tibble(
    method = method,
    admission_days_used = length(admission_dates),
    admissions_used = sum(admissions, na.rm = TRUE),
    mean_days_from_start = stats::weighted.mean(days_from_start, admissions),
    timing_weighted_admissions = sum(admissions * weights, na.rm = TRUE),
    raw_initial_exposed = raw_initial_exposed,
    initial_exposed = max(
      round(raw_initial_exposed),
      ifelse(weekly_inc_hosp > 0, MIN_STATE_EXPOSED_PER_ACTIVE_AGE, 0L)
    )
  )
}

template <- jsonlite::fromJSON(template_file, simplifyVector = FALSE)
disease_parameters <- template$disease_model$parameters
prop_E_to_IA <- json_numeric_vector(disease_parameters$prop_E_to_IA, label = "prop_E_to_IA")
prop_IS_to_H_lowrisk <- if (!is.na(lowrisk_hosp_rate_file) && nzchar(lowrisk_hosp_rate_file)) {
  read_labeled_age_rate_csv(lowrisk_hosp_rate_file, value_col = "prop_IS_to_H_lowrisk")
} else {
  json_numeric_vector(disease_parameters$prop_IS_to_H_lowrisk, label = "prop_IS_to_H_lowrisk")
}
exposed_to_hosp_probability <- (1 - prop_E_to_IA) * prop_IS_to_H_lowrisk
exposed_to_hosp_days <- json_numeric_scalar(disease_parameters$E_to_IPandIA_days, "E_to_IPandIA_days") +
  json_numeric_scalar(disease_parameters$IP_to_IS_days, "IP_to_IS_days") +
  json_numeric_scalar(disease_parameters$IS_to_H_days, "IS_to_H_days")

state_lookup <- tigris::fips_codes |>
  dplyr::distinct(
    state_abbr = .data$state,
    state_name = .data$state_name,
    location = stringr::str_pad(as.character(.data$state_code), width = 2, pad = "0")
  ) |>
  dplyr::filter(as.integer(.data$location) < 60) |>
  dplyr::mutate(state_dir = stringr::str_replace_all(.data$state_name, " ", "-")) |>
  dplyr::arrange(.data$state_name)

if (length(state_filter) > 0 && !all(is.na(state_filter))) {
  state_filter_norm <- stringr::str_to_lower(stringr::str_replace_all(state_filter, " ", "-"))
  state_lookup <- state_lookup |>
    dplyr::filter(
      stringr::str_to_lower(.data$state_abbr) %in% state_filter_norm |
        stringr::str_to_lower(.data$state_dir) %in% state_filter_norm |
        stringr::str_to_lower(stringr::str_replace_all(.data$state_name, " ", "-")) %in% state_filter_norm
    )
}
if (nrow(state_lookup) == 0) {
  stop("No states matched --states filter.")
}

flu_ts <- readr::read_csv(hospitalization_file, show_col_types = FALSE) |>
  dplyr::mutate(
    date = as.Date(.data$date),
    location = stringr::str_pad(as.character(.data$location), width = 2, pad = "0"),
    observation = as.numeric(.data$observation),
    age_group = dplyr::recode(as.character(.data$age_group), "65-130" = "65+")
  ) |>
  dplyr::filter(.data$target == "inc hosp") |>
  dplyr::filter(.data$location != "US") |>
  dplyr::filter(.data$age_group %in% age_order) |>
  dplyr::inner_join(state_lookup, by = "location") |>
  dplyr::mutate(age_group = factor(.data$age_group, levels = age_order)) |>
  dplyr::arrange(.data$state_name, .data$age_group, .data$date)

non_saturday_dates <- flu_ts |>
  dplyr::filter(as.POSIXlt(.data$date)$wday != 6L) |>
  dplyr::distinct(.data$date)
if (nrow(non_saturday_dates) > 0) {
  stop(
    "Expected Flu Hub inc hosp records to be MMWR week-ending Saturdays; found: ",
    paste(head(non_saturday_dates$date, 3), collapse = ", ")
  )
}

methods <- c(
  "current_5a_week_end_point",
  "all_prior_sunday",
  "all_saturday_week_end",
  "uniform_full_mmwr_week",
  "uniform_on_or_after_start"
)

estimates <- purrr::map_dfr(sim_start_dates, function(sim_start_date) {
  first_complete_end <- first_complete_mmwr_week_end(sim_start_date)

  current_first <- flu_ts |>
    dplyr::filter(.data$date >= sim_start_date, .data$observation > 0) |>
    dplyr::group_by(.data$state_abbr, .data$state_name, .data$state_dir, .data$location, .data$age_group) |>
    dplyr::slice_min(.data$date, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::mutate(first_week_rule = "first_week_on_or_after_start")

  complete_first <- flu_ts |>
    dplyr::filter(.data$date >= first_complete_end, .data$observation > 0) |>
    dplyr::group_by(.data$state_abbr, .data$state_name, .data$state_dir, .data$location, .data$age_group) |>
    dplyr::slice_min(.data$date, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::mutate(first_week_rule = "first_complete_mmwr_week")

  dplyr::bind_rows(current_first, complete_first) |>
    dplyr::mutate(
      sim_start_date = sim_start_date,
      first_complete_mmwr_week_end = first_complete_end,
      week_end = .data$date,
      week_start = .data$week_end - 6L,
      weekly_inc_hosp = .data$observation,
      age_group_chr = as.character(.data$age_group),
      exposed_to_hosp_probability = unname(exposed_to_hosp_probability[.data$age_group_chr]),
      exposed_to_hosp_days = exposed_to_hosp_days
    ) |>
    tidyr::nest(input = c(
      "sim_start_date",
      "week_end",
      "weekly_inc_hosp",
      "exposed_to_hosp_probability",
      "exposed_to_hosp_days"
    )) |>
    dplyr::mutate(
      estimates = purrr::map(.data$input, function(input_row) {
        purrr::map_dfr(methods, function(method) {
          estimate_for_row(
            sim_start_date = input_row$sim_start_date[[1]],
            week_end = input_row$week_end[[1]],
            weekly_inc_hosp = input_row$weekly_inc_hosp[[1]],
            exposed_to_hosp_probability = input_row$exposed_to_hosp_probability[[1]],
            exposed_to_hosp_days = input_row$exposed_to_hosp_days[[1]],
            method = method
          )
        })
      })
    ) |>
    tidyr::unnest(cols = c("input", "estimates")) |>
    dplyr::filter(
      .data$first_week_rule == "first_week_on_or_after_start" |
        .data$method == "current_5a_week_end_point"
    )
})

estimates <- estimates |>
  dplyr::select(
    "sim_start_date",
    "first_week_rule",
    "first_complete_mmwr_week_end",
    "state_abbr",
    "state_name",
    "state_dir",
    "location",
    "age_group",
    "week_start",
    "week_end",
    "weekly_inc_hosp",
    "method",
    "admission_days_used",
    "admissions_used",
    "mean_days_from_start",
    "exposed_to_hosp_probability",
    "exposed_to_hosp_days",
    "timing_weighted_admissions",
    "raw_initial_exposed",
    "initial_exposed"
  ) |>
  dplyr::arrange(.data$sim_start_date, .data$state_name, .data$age_group, .data$first_week_rule, .data$method)

dir.create(dirname(output_file), showWarnings = FALSE, recursive = TRUE)
readr::write_csv(estimates, output_file)
message("Wrote state-age initial exposed sensitivity estimates to: ", output_file)

summary_by_date <- estimates |>
  dplyr::group_by(.data$sim_start_date, .data$first_week_rule, .data$method) |>
  dplyr::summarise(total_initial_exposed = sum(.data$initial_exposed, na.rm = TRUE), .groups = "drop") |>
  dplyr::arrange(.data$sim_start_date, .data$first_week_rule, .data$method)

message("\nTotal initial exposed by sim start date and timing method:")
print(summary_by_date, n = Inf)

plot_method_labels <- c(
  current_5a_week_end_point = "Current 5a\nSaturday point",
  all_prior_sunday = "All prior\nSunday",
  all_saturday_week_end = "All\nSaturday",
  uniform_full_mmwr_week = "Uniform\nSun-Sat",
  uniform_on_or_after_start = "Uniform\non/after start"
)

summary_plot <- summary_by_date |>
  dplyr::mutate(
    sim_start_date = factor(as.character(.data$sim_start_date), levels = as.character(sort(unique(.data$sim_start_date)))),
    method = factor(.data$method, levels = names(plot_method_labels), labels = plot_method_labels),
    first_week_rule = dplyr::recode(
      .data$first_week_rule,
      first_week_on_or_after_start = "First nonzero week on/after start",
      first_complete_mmwr_week = "First complete MMWR week"
    )
  ) |>
  ggplot2::ggplot(ggplot2::aes(
    x = .data$method,
    y = .data$total_initial_exposed,
    fill = .data$sim_start_date
  )) +
  ggplot2::geom_col(position = ggplot2::position_dodge(width = 0.75), width = 0.68) +
  ggplot2::facet_wrap(ggplot2::vars(.data$first_week_rule), scales = "free_x") +
  ggplot2::scale_y_continuous(labels = scales::comma) +
  ggplot2::labs(
    title = "Initial Exposed Sensitivity To Simulation Start Date",
    subtitle = "State-age totals inferred from first nonzero weekly Hub incident hospitalizations",
    x = NULL,
    y = "Initial exposed",
    fill = "Sim start"
  ) +
  ggplot2::theme_minimal(base_size = 12) +
  ggplot2::theme(
    legend.position = "top",
    panel.grid.major.x = ggplot2::element_blank(),
    axis.text.x = ggplot2::element_text(size = 9)
  )

if (plot_results) {
  print(summary_plot)
}

if (length(sim_start_dates) >= 2) {
  reference_date <- min(sim_start_dates)
  comparison <- estimates |>
    dplyr::filter(.data$first_week_rule == "first_week_on_or_after_start") |>
    dplyr::select(
      "sim_start_date",
      "state_name",
      "age_group",
      "method",
      "initial_exposed"
    ) |>
    tidyr::pivot_wider(
      names_from = "sim_start_date",
      values_from = "initial_exposed",
      names_prefix = "start_"
    )

  date_cols <- grep("^start_", names(comparison), value = TRUE)
  reference_col <- paste0("start_", reference_date)
  if (reference_col %in% date_cols) {
    comparison_dates <- setdiff(date_cols, reference_col)
    if (length(comparison_dates) > 0) {
      comparison$max_abs_difference_from_reference <- do.call(
        pmax,
        c(
          lapply(comparison_dates, function(col) abs(comparison[[col]] - comparison[[reference_col]])),
          list(na.rm = TRUE)
        )
      )
    } else {
      comparison$max_abs_difference_from_reference <- 0
    }
    comparison <- comparison |>
      dplyr::arrange(dplyr::desc(.data$max_abs_difference_from_reference))

    message("\nLargest state-age differences from earliest supplied date (", reference_date, "):")
    print(head(comparison, print_top_n), n = print_top_n)

    plot_date_cols <- setdiff(date_cols, reference_col)
    if (plot_results && length(plot_date_cols) > 0) {
      diff_plot_data <- comparison |>
        dplyr::select(
          "state_name",
          "age_group",
          "method",
          dplyr::all_of(reference_col),
          dplyr::all_of(plot_date_cols)
        ) |>
        tidyr::pivot_longer(
          cols = dplyr::all_of(plot_date_cols),
          names_to = "comparison_start",
          values_to = "comparison_initial_exposed"
        ) |>
        dplyr::mutate(
          reference_initial_exposed = .data[[reference_col]],
          difference = .data$comparison_initial_exposed - .data$reference_initial_exposed,
          comparison_start = sub("^start_", "", .data$comparison_start),
          method = factor(.data$method, levels = names(plot_method_labels), labels = plot_method_labels),
          state_age = paste(.data$state_name, .data$age_group, sep = " / ")
        ) |>
        dplyr::group_by(.data$state_age) |>
        dplyr::mutate(max_abs_difference = max(abs(.data$difference), na.rm = TRUE)) |>
        dplyr::ungroup() |>
        dplyr::slice_max(.data$max_abs_difference, n = print_top_n, with_ties = FALSE) |>
        dplyr::mutate(state_age = stats::reorder(.data$state_age, .data$difference))

      diff_plot <- diff_plot_data |>
        ggplot2::ggplot(ggplot2::aes(
          x = .data$difference,
          y = .data$state_age,
          fill = .data$difference
        )) +
        ggplot2::geom_col(width = 0.72) +
        ggplot2::geom_vline(xintercept = 0, color = "grey35", linewidth = 0.4) +
        ggplot2::facet_grid(
          rows = ggplot2::vars(.data$comparison_start),
          cols = ggplot2::vars(.data$method),
          scales = "free_x"
        ) +
        ggplot2::scale_x_continuous(labels = scales::comma) +
        ggplot2::scale_fill_gradient2(
          low = "#31688e",
          mid = "#f7f7f7",
          high = "#b35806",
          midpoint = 0,
          guide = "none"
        ) +
        ggplot2::labs(
          title = "Largest State-Age Initial Exposed Differences",
          subtitle = paste("Difference from reference sim start", reference_date),
          x = "Initial exposed difference",
          y = NULL
        ) +
        ggplot2::theme_minimal(base_size = 11) +
        ggplot2::theme(
          panel.grid.major.y = ggplot2::element_blank(),
          strip.text.x = ggplot2::element_text(size = 8),
          axis.text.y = ggplot2::element_text(size = 8)
        )

      print(diff_plot)
    }
  }
}
