#////////
#### Script Overview ####
#////////
# Summarize simulation completion and runtime diagnostics by state/scenario.
# The data-driven CI estimate uses network-level compartment totals across
# realizations and estimates how many simulations are needed for a 95%
# confidence interval on each compartment mean with a default 5% relative
# half-width target. Terminal compartments (S, R, D) use final-day totals;
# transient compartments use summed totals across the simulation trajectory.
#
# Outputs:
#   <PIPELINE_OUTPUT_DIR>/validation_scores/simulation_completion_runtime_summary.csv
#   <PIPELINE_OUTPUT_DIR>/validation_scores/simulation_compartment_ci_sims_needed.csv
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/sims_needed_for_95ci_by_state_scenario_compartment_heatmap.png
#   <PIPELINE_OUTPUT_DIR>/validation_scores/plots/run_time_by_state_scenario.png
#
# Example:
#   Rscript scripts/9c_score_validation_run_diagnostics.R \
#     --output-dir=STATE_WKLYFIT_TEST

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(ggplot2)
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

repo_root <- normalizePath(".", mustWork = FALSE)
if (basename(repo_root) == "scripts") {
  repo_root <- normalizePath("..", mustWork = TRUE)
}

pipeline_output_dir <- get_arg_value("--output-dir=", "STATE_WKLYFIT_TEST")
SEARCH_ROOT <- normalizePath(
  if (grepl("^/", pipeline_output_dir)) pipeline_output_dir else file.path(repo_root, pipeline_output_dir),
  mustWork = FALSE
)
MASTER_CSV <- file.path(SEARCH_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(SEARCH_ROOT, "sim_data")
SCORE_DIR <- file.path(SEARCH_ROOT, "validation_scores")
PLOT_DIR <- file.path(SCORE_DIR, "plots")
SCENARIO_REGEX <- get_arg_value("--scenario-regex=", "")
OUTPUT_SOURCE_REGEX <- get_arg_value("--output-source-regex=", "WEB_OUTPUTS")
MAX_SCENARIOS <- as.integer(get_arg_value("--max-scenarios=", "0"))
CI_CONFIDENCE <- as.numeric(get_arg_value("--ci-confidence=", "0.95"))
CI_RELATIVE_HALF_WIDTH <- as.numeric(get_arg_value("--ci-relative-half-width=", "0.05"))
CI_MIN_HALF_WIDTH <- as.numeric(get_arg_value("--ci-min-half-width=", "1"))

dir.create(SCORE_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

SCENARIO_ORDER <- c("NONE", "VACCINE", "NPI", "ANTIVIRAL", "VACCINE+ANTIVIRAL+NPI")
SCENARIO_DISPLAY <- c(
  "NONE" = "None",
  "VACCINE" = "Vaccine",
  "NPI" = "NPI",
  "ANTIVIRAL" = "Antiviral",
  "VACCINE+ANTIVIRAL+NPI" = "All 3"
)
SCENARIO_COLORS <- c(
  "NONE" = "#1b9e77",
  "VACCINE" = "#7570b3",
  "NPI" = "#d95f02",
  "ANTIVIRAL" = "#66a61e",
  "VACCINE+ANTIVIRAL+NPI" = "#e7298a"
)
COMPARTMENTS <- c("S", "E", "IA", "IP", "IS", "H", "R", "D")

scenario_label <- function(row) {
  parts <- character()
  if (isTRUE(row$vaccine_used)) parts <- c(parts, "VACCINE")
  if (isTRUE(row$antiviral_used)) parts <- c(parts, "ANTIVIRAL")
  if (isTRUE(row$npi_used)) parts <- c(parts, "NPI")
  if (length(parts) == 0) return("NONE")
  paste(parts, collapse = "+")
}

calc_sim_completion <- function(attempted_sims, completed_sims) {
  dplyr::case_when(
    is.na(attempted_sims) ~ NA_real_,
    attempted_sims <= 0 ~ NA_real_,
    is.na(completed_sims) ~ 0,
    TRUE ~ pmin(completed_sims / attempted_sims, 1)
  )
}

sum_or_na <- function(x) {
  if (all(is.na(x))) return(NA_real_)
  sum(x, na.rm = TRUE)
}

slugify <- function(x) {
  str_replace_all(str_to_lower(x), "[^a-z0-9]+", "_") %>%
    str_replace_all("^_|_$", "")
}

network_parquet_files <- function(scenario_hash) {
  matches <- Sys.glob(file.path(PARQUET_ROOT, scenario_hash, "*", "network.parquet"))
  sort(matches)
}

ci_required_sims <- function(row) {
  network_files <- network_parquet_files(row$scenario_hash)
  if (length(network_files) == 0) {
    return(tibble(
      compartment = COMPARTMENTS,
      compartment_summary_type = NA_character_,
      ci_batch_count = 0L,
      compartment_mean = NA_real_,
      compartment_sd = NA_real_,
      ci_confidence = CI_CONFIDENCE,
      ci_relative_half_width_target = CI_RELATIVE_HALF_WIDTH,
      ci_min_half_width_target = CI_MIN_HALF_WIDTH,
      ci_half_width_target = NA_real_,
      current_ci_half_width = NA_real_,
      current_ci_relative_half_width = NA_real_,
      required_sims_for_ci = NA_integer_,
      additional_sims_for_ci = NA_integer_
    ))
  }

  z_value <- stats::qnorm(1 - (1 - CI_CONFIDENCE) / 2)
  available_compartments <- intersect(COMPARTMENTS, names(arrow::read_parquet(network_files[[1]], as_data_frame = FALSE)))
  if (length(available_compartments) == 0) {
    return(tibble(
      compartment = COMPARTMENTS,
      compartment_summary_type = NA_character_,
      ci_batch_count = length(network_files),
      compartment_mean = NA_real_,
      compartment_sd = NA_real_,
      ci_confidence = CI_CONFIDENCE,
      ci_relative_half_width_target = CI_RELATIVE_HALF_WIDTH,
      ci_min_half_width_target = CI_MIN_HALF_WIDTH,
      ci_half_width_target = NA_real_,
      current_ci_half_width = NA_real_,
      current_ci_relative_half_width = NA_real_,
      required_sims_for_ci = NA_integer_,
      additional_sims_for_ci = NA_integer_
    ))
  }

  terminal_compartments <- intersect(c("S", "R", "D"), available_compartments)
  transient_compartments <- setdiff(available_compartments, terminal_compartments)

  network_data <- purrr::map_dfr(network_files, arrow::read_parquet) %>%
    mutate(across(all_of(available_compartments), ~ suppressWarnings(as.numeric(.x)))) %>%
    group_by(.data$batch_num, .data$sim_id)

  terminal_samples <- if (length(terminal_compartments) > 0) {
    network_data %>%
      filter(.data$day == max(.data$day, na.rm = TRUE)) %>%
      slice(1) %>%
      ungroup() %>%
      select("batch_num", "sim_id", all_of(terminal_compartments)) %>%
      pivot_longer(
        cols = all_of(terminal_compartments),
        names_to = "compartment",
        values_to = "compartment_value"
      ) %>%
      mutate(compartment_summary_type = "final_day_total")
  } else {
    tibble()
  }

  transient_samples <- if (length(transient_compartments) > 0) {
    network_data %>%
      summarise(
        across(all_of(transient_compartments), ~ sum(.x, na.rm = TRUE)),
        .groups = "drop"
      ) %>%
      pivot_longer(
        cols = all_of(transient_compartments),
        names_to = "compartment",
        values_to = "compartment_value"
      ) %>%
      mutate(compartment_summary_type = "trajectory_sum")
  } else {
    tibble()
  }

  bind_rows(terminal_samples, transient_samples) %>%
    group_by(.data$compartment, .data$compartment_summary_type) %>%
    summarise(
      ci_batch_count = dplyr::n_distinct(.data$batch_num),
      completed_sims_for_ci = dplyr::n(),
      compartment_mean = mean(.data$compartment_value, na.rm = TRUE),
      compartment_sd = stats::sd(.data$compartment_value, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      compartment = factor(.data$compartment, levels = COMPARTMENTS),
      ci_confidence = CI_CONFIDENCE,
      ci_relative_half_width_target = CI_RELATIVE_HALF_WIDTH,
      ci_min_half_width_target = CI_MIN_HALF_WIDTH,
      ci_half_width_target = pmax(abs(.data$compartment_mean) * CI_RELATIVE_HALF_WIDTH, CI_MIN_HALF_WIDTH, na.rm = TRUE),
      current_ci_half_width = z_value * .data$compartment_sd / sqrt(.data$completed_sims_for_ci),
      current_ci_relative_half_width = dplyr::if_else(
        .data$compartment_mean == 0,
        NA_real_,
        .data$current_ci_half_width / abs(.data$compartment_mean)
      ),
      required_sims_for_ci = dplyr::case_when(
        .data$completed_sims_for_ci < 2 ~ NA_real_,
        is.na(.data$compartment_sd) | is.na(.data$ci_half_width_target) ~ NA_real_,
        .data$compartment_sd == 0 ~ as.numeric(.data$completed_sims_for_ci),
        TRUE ~ ceiling((z_value * .data$compartment_sd / .data$ci_half_width_target)^2)
      ),
      additional_sims_for_ci = dplyr::if_else(
        is.na(.data$required_sims_for_ci),
        NA_real_,
        pmax(.data$required_sims_for_ci - .data$completed_sims_for_ci, 0)
      ),
      required_sims_for_ci = as.integer(.data$required_sims_for_ci),
      additional_sims_for_ci = as.integer(.data$additional_sims_for_ci)
    ) %>%
    arrange(.data$compartment)
}

message("Reading metadata: ", MASTER_CSV)
metadata_all <- readr::read_csv(MASTER_CSV, show_col_types = FALSE) %>%
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
  filter(!is.na(.data$scenario_hash), nzchar(.data$scenario_hash))

if (nzchar(OUTPUT_SOURCE_REGEX)) {
  metadata_all <- metadata_all %>%
    filter(str_detect(
      paste(.data$file_path, .data$output_dir_path, sep = " "),
      regex(OUTPUT_SOURCE_REGEX, ignore_case = TRUE)
    ))
  message("Filtered metadata by output source regex '", OUTPUT_SOURCE_REGEX, "': ", nrow(metadata_all), " row(s)")
}

if (nzchar(SCENARIO_REGEX)) {
  metadata_all <- metadata_all %>%
    filter(str_detect(.data$scenario_label, regex(SCENARIO_REGEX, ignore_case = TRUE)))
}

ci_metadata <- metadata_all %>%
  arrange(.data$geo_region, .data$scenario_label, desc(.data$created_at_utc)) %>%
  group_by(.data$geo_region, .data$scenario_label, .data$scenario_hash) %>%
  slice(1) %>%
  ungroup()

if (!is.na(MAX_SCENARIOS) && MAX_SCENARIOS > 0) {
  ci_metadata <- head(ci_metadata, MAX_SCENARIOS)
}

selected_hashes <- ci_metadata %>%
  select("geo_region", "scenario_label", "scenario_hash")

runtime_summary <- metadata_all %>%
  dplyr::semi_join(selected_hashes, by = c("geo_region", "scenario_label", "scenario_hash")) %>%
  group_by(.data$geo_region, .data$scenario_label, .data$scenario_hash) %>%
  summarise(
    runtime_batch_count = sum(!is.na(.data$mean_run_time_seconds)),
    attempted_sims = as.integer(sum_or_na(.data$attempt_realization_count)),
    completed_sims = as.integer(sum_or_na(.data$complete_realization_count)),
    mean_run_time_seconds = mean(.data$mean_run_time_seconds, na.rm = TRUE),
    geo_node_count = max(.data$geo_node_count, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    runtime_batch_count = as.integer(.data$runtime_batch_count),
    mean_run_time_seconds = ifelse(is.nan(.data$mean_run_time_seconds), NA_real_, .data$mean_run_time_seconds),
    geo_node_count = ifelse(is.infinite(.data$geo_node_count), NA_real_, .data$geo_node_count)
  )

base_summary <- ci_metadata %>%
  transmute(
    geo_region = .data$geo_region,
    scenario_label = .data$scenario_label,
    scenario_hash = .data$scenario_hash,
    batch_num = .data$batch_num,
    selected_batch_created_at_utc = .data$created_at_utc
  ) %>%
  left_join(
    runtime_summary,
    by = c("geo_region", "scenario_label", "scenario_hash")
  ) %>%
  mutate(
    scheduled_sims_needed = dplyr::case_when(
      is.na(.data$attempted_sims) ~ NA_integer_,
      is.na(.data$completed_sims) ~ .data$attempted_sims,
      TRUE ~ pmax(.data$attempted_sims - .data$completed_sims, 0L)
    ),
    sim_completion = calc_sim_completion(.data$attempted_sims, .data$completed_sims),
    mean_run_time_seconds = .data$mean_run_time_seconds
  ) %>%
  mutate(
    estimated_scheduled_remaining_runtime_hours = .data$scheduled_sims_needed * .data$mean_run_time_seconds / 3600
  )

ci_summary <- pmap_dfr(base_summary, function(...) {
  row <- list(...)
  ci_required_sims(row) %>%
    mutate(
      geo_region = row$geo_region,
      scenario_label = row$scenario_label,
      scenario_hash = row$scenario_hash,
      batch_num = "ALL_BATCHES",
      selected_batch_num = row$batch_num,
      .before = 1
    )
}) %>%
  mutate(
    scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER),
    compartment = factor(.data$compartment, levels = COMPARTMENTS)
  ) %>%
  arrange(.data$scenario_label, .data$compartment, desc(.data$additional_sims_for_ci), .data$geo_region)

run_summary <- base_summary %>%
  left_join(
    ci_summary %>%
      group_by(.data$geo_region, .data$scenario_label, .data$scenario_hash) %>%
      summarise(
        max_additional_sims_for_ci = max(.data$additional_sims_for_ci, na.rm = TRUE),
        .groups = "drop"
      ),
    by = c("geo_region", "scenario_label", "scenario_hash")
  ) %>%
  mutate(
    max_additional_sims_for_ci = ifelse(is.infinite(.data$max_additional_sims_for_ci), NA_real_, .data$max_additional_sims_for_ci),
    estimated_ci_additional_runtime_hours = .data$max_additional_sims_for_ci * .data$mean_run_time_seconds / 3600
  ) %>%
  arrange(.data$scenario_label, desc(.data$max_additional_sims_for_ci), .data$geo_region)

readr::write_csv(run_summary, file.path(SCORE_DIR, "simulation_completion_runtime_summary.csv"))
readr::write_csv(ci_summary, file.path(SCORE_DIR, "simulation_compartment_ci_sims_needed.csv"))

state_order <- base_summary %>%
  group_by(.data$geo_region) %>%
  summarise(geo_node_count = max(.data$geo_node_count, na.rm = TRUE), .groups = "drop") %>%
  mutate(geo_node_count = ifelse(is.infinite(.data$geo_node_count), NA_real_, .data$geo_node_count)) %>%
  arrange(desc(.data$geo_node_count), .data$geo_region) %>%
  pull(.data$geo_region)

scenario_display_labeller <- as_labeller(SCENARIO_DISPLAY)
plot_data <- run_summary %>%
  mutate(
    geo_region = factor(.data$geo_region, levels = rev(state_order)),
    scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER)
  ) %>%
  filter(!is.na(.data$scenario_label))

runtime_data <- plot_data %>%
  filter(!is.na(.data$mean_run_time_seconds))
if (nrow(runtime_data) > 0) {
  p <- ggplot(runtime_data, aes(x = mean_run_time_seconds, y = geo_region, color = scenario_label)) +
    geom_point(size = 2.6, alpha = 0.88, position = position_dodge(width = 0.55)) +
    scale_color_manual(values = SCENARIO_COLORS, labels = SCENARIO_DISPLAY, drop = FALSE) +
    scale_x_continuous(labels = scales::label_number(accuracy = 0.1)) +
    labs(
      x = "Mean runtime per simulation (seconds)",
      y = NULL,
      color = NULL,
      title = "Simulation Runtime by State and Scenario"
    ) +
    theme_minimal(base_size = 10) +
    theme(
      panel.grid.major.y = element_blank(),
      plot.title = element_text(face = "bold"),
      legend.position = "bottom"
    )
  ggsave(
    file.path(PLOT_DIR, "run_time_by_state_scenario.png"),
    p,
    width = 10.5,
    height = max(5.5, 0.35 * length(state_order) + 2),
    dpi = 220
  )
}

ci_plot_data <- ci_summary %>%
  mutate(
    geo_region = factor(.data$geo_region, levels = rev(state_order)),
    scenario_label = factor(.data$scenario_label, levels = SCENARIO_ORDER),
    compartment = factor(.data$compartment, levels = COMPARTMENTS)
  ) %>%
  filter(!is.na(.data$scenario_label), !is.na(.data$additional_sims_for_ci))

if (nrow(ci_plot_data) > 0) {
  label_threshold <- max(ci_plot_data$additional_sims_for_ci, na.rm = TRUE) * 0.45
  ci_plot_data <- ci_plot_data %>%
    mutate(label_color = if_else(.data$additional_sims_for_ci >= label_threshold, "white", "grey15"))

  p <- ggplot(ci_plot_data, aes(x = compartment, y = geo_region, fill = additional_sims_for_ci)) +
    geom_tile(color = "white", linewidth = 0.3) +
    geom_text(aes(label = scales::comma(additional_sims_for_ci), color = label_color), size = 2.5) +
    facet_grid(. ~ scenario_label, labeller = scenario_display_labeller) +
    scale_fill_viridis_c(option = "magma", direction = -1, labels = scales::comma) +
    scale_color_identity() +
    labs(
      x = "Compartment",
      y = NULL,
      fill = "Additional\nsims",
      title = "Additional Simulations Needed for 95% CI by Compartment",
      subtitle = paste0(
        "S/R/D use final-day totals; other compartments use trajectory sums; target half-width ",
        scales::percent(CI_RELATIVE_HALF_WIDTH),
        " of each compartment mean, minimum ",
        scales::comma(CI_MIN_HALF_WIDTH)
      )
    ) +
    theme_minimal(base_size = 9) +
    theme(
      panel.grid = element_blank(),
      plot.title = element_text(face = "bold"),
      axis.text.x = element_text(angle = 45, hjust = 1),
      strip.text = element_text(face = "bold")
    )
  ggsave(
    file.path(PLOT_DIR, "sims_needed_for_95ci_by_state_scenario_compartment_heatmap.png"),
    p,
    width = 16,
    height = max(5.5, 0.34 * length(state_order) + 2),
    dpi = 220
  )
}

message("Wrote simulation completion/runtime diagnostics to: ", SCORE_DIR)
