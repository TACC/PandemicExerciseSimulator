# Shared definitions for the full-simulator R0 search and its regression tests.
R0_SCORING_VERSION <- "weekly_positive_H_delta_complete_mmwr_v1"
R0_FEATURE_METRICS <- c("total", "peak_height", "peak_timing")

# Use plotmath rather than a Unicode subscript requiring font fallback.
rm_plot_parse_strings <- function(labels) {
  vapply(labels, function(label) {
    pieces <- strsplit(label, "R_m", fixed = TRUE)[[1]]
    terms <- list(as.name("paste"))
    for (i in seq_along(pieces)) {
      terms <- c(terms, list(pieces[[i]]))
      if (i < length(pieces)) terms <- c(terms, list(quote(R[m])))
    }
    # strsplit omits a final empty piece when the label ends in R_m.
    if (endsWith(label, "R_m")) terms <- c(terms, list(quote(R[m])))
    paste(deparse(as.call(terms), width.cutoff = 500), collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

rm_plot_labels <- function(plot) {
  for (name in c("title", "x", "y", "colour", "color")) {
    label <- plot$labels[[name]]
    if (is.character(label) && length(label) == 1 && grepl("R_m", label, fixed = TRUE)) {
      text <- rm_plot_parse_strings(label)
      if (name == "title") text <- paste0("bold(", text, ")")
      plot$labels[[name]] <- parse(text = text)
    }
  }
  plot
}

parse_r0_search_metrics <- function(value) {
  aliases <- c(mean_wis = "wis", total_hospitalized = "total", peak = "peak_height", timing = "peak_timing")
  metrics <- trimws(unlist(strsplit(value, ",", fixed = TRUE)))
  metrics <- unlist(lapply(metrics, function(metric) {
    if (metric == "all") return(R0_FEATURE_METRICS)
    if (metric %in% names(aliases)) return(unname(aliases[[metric]]))
    metric
  }), use.names = FALSE)
  if (!length(metrics) || any(!metrics %in% c(R0_FEATURE_METRICS, "wis"))) {
    stop("R0 metrics must be total, peak_height, peak_timing, wis, or all (the three features).")
  }
  unique(metrics)
}

r0_metric_values <- function(summary, metric) {
  switch(metric,
    total = abs(summary$predicted_median_total - summary$observed_total),
    peak_height = abs(summary$predicted_peak_height - summary$observed_peak_height),
    peak_timing = abs(summary$peak_lag_weeks),
    wis = summary$mean_wis,
    stop("Unknown R0 metric: ", metric)
  )
}

r0_metric_label <- function(metric) {
  unname(c(total = "Total", peak_height = "Peak Height", peak_timing = "Timing", wis = "WIS")[metric])
}

r0_metric_axis_label <- function(metric) {
  unname(c(total = "Total hospitalization absolute error", peak_height = "Peak-height absolute error",
           peak_timing = "Absolute peak lag (weeks)", wis = "Mean WIS across validation weeks")[metric])
}

r0_search_window_data <- function(trace, metrics, r0_min, r0_max) {
  # Reconstruct each requested path using the same previous-round best that
  # generated its center. Preserve the original horizontal-window presentation.
  iterations <- sort(unique(trace$iteration))
  paths <- lapply(metrics, function(metric) {
    rows <- lapply(iterations, function(iter) {
      current <- trace[trace$iteration == iter, , drop = FALSE]
      earlier <- trace[trace$iteration < iter, , drop = FALSE]
      center <- if (!nrow(earlier)) current$search_center[[1]] else {
        earlier$disease_R0[order(r0_metric_values(earlier, metric), earlier$disease_R0)][[1]]
      }
      step <- current$step[[1]]
      candidates <- round(c(center - step, center, center + step), 4)
      candidates <- candidates[candidates >= r0_min & candidates <= r0_max]
      current <- current[round(current$disease_R0, 4) %in% candidates, , drop = FALSE]
      current <- current[!duplicated(round(current$disease_R0, 4)), , drop = FALSE]
      if (!nrow(current)) return(NULL)
      current$metric <- metric
      current$role_center <- center
      current$metric_value <- r0_metric_values(current, metric)
      best <- order(current$metric_value, current$disease_R0)[[1]]
      current$is_round_best <- seq_len(nrow(current)) == best
      current$is_center <- abs(current$disease_R0 - center) < 1e-8
      current
    })
    path <- dplyr::bind_rows(rows)
    if (!nrow(path)) return(path)
    final <- path[path$iteration == max(path$iteration) & path$is_round_best, , drop = FALSE]
    path$facet_label <- paste0(r0_metric_label(metric), " (best R_m=", sprintf("%.2f", final$disease_R0[[1]]), ")")
    path
  })
  points <- dplyr::bind_rows(paths)
  if (!nrow(points)) return(list(points = points))
  points$facet_label <- factor(points$facet_label, levels = unique(points$facet_label))
  labels <- points %>% dplyr::group_by(.data$facet_label, .data$disease_R0) %>%
    dplyr::filter(.data$iteration == min(.data$iteration)) %>% dplyr::ungroup() %>%
    dplyr::mutate(score_label = ifelse(.data$metric == "peak_timing", sprintf("%.1f", .data$metric_value),
                                     format(round(.data$metric_value), trim = TRUE, scientific = FALSE, big.mark = ",")))
  list(points = points, labels = labels,
       segments = points %>% dplyr::group_by(.data$facet_label, .data$iteration) %>%
         dplyr::summarise(x_low = min(.data$disease_R0), x_high = max(.data$disease_R0), .groups = "drop"),
       centers = points[points$is_center & !points$is_round_best, , drop = FALSE],
       best = points[points$is_round_best, , drop = FALSE],
       final = points %>% dplyr::group_by(.data$facet_label) %>%
         dplyr::filter(.data$iteration == max(.data$iteration), .data$is_round_best) %>% dplyr::ungroup())
}

r0_scoring_window <- function(metadata, simulation_days) {
  start <- as.Date(metadata$metadata_tags$validation$sim_start_date %||% metadata$metadata_tags$sim_day_0)
  if (length(start) != 1 || is.na(start)) stop("Simulation start date is required for R0 scoring.")
  days <- as.integer(metadata$cli_args$days %||% simulation_days)
  if (is.na(days) || days < 7) stop("R0 scoring requires at least one complete MMWR week.")
  # Day 0 is initialization; daily changes represent days 1..days.
  first_day <- start + 1
  first_end <- first_day + ((6 - as.integer(format(first_day, "%w"))) %% 7)
  if (first_end - 6 < first_day) first_end <- first_end + 7
  end <- start + days
  if (first_end > end) stop("No complete MMWR weeks in the simulation window.")
  list(start = first_day, end = end, weeks = seq(first_end, end, by = "7 days"))
}

r0_weekly_incident_samples <- function(daily, metadata, simulation_days) {
  if (!"H" %in% names(daily)) stop("R0 scoring requires the existing daily H series.")
  window <- r0_scoring_window(metadata, simulation_days)
  start <- window$start - 1
  bounds <- as.integer(unlist(metadata$realization_indices[c("min", "max")]))
  if (length(bounds) != 2 || anyNA(bounds) || bounds[2] < bounds[1]) {
    stop("Realization bounds are required for zero-padding extinct simulations.")
  }
  ids <- seq.int(bounds[1], bounds[2])
  if (!all(ids %in% daily$sim_id)) stop("Missing daily output for a completed realization; cannot assume extinction.")
  if (anyNA(daily$H) || any(daily$H < 0)) stop("H must be nonnegative and nonmissing.")
  weekly <- daily %>%
    dplyr::arrange(.data$sim_id, .data$day) %>%
    dplyr::group_by(.data$sim_id) %>%
    dplyr::mutate(generated = pmax(.data$H - dplyr::lag(.data$H, default = dplyr::first(.data$H)), 0)) %>%
    dplyr::ungroup() %>%
    dplyr::filter(.data$day >= 1, .data$day <= as.integer(metadata$cli_args$days %||% simulation_days)) %>%
    dplyr::mutate(calendar_date = start + .data$day,
                  date = .data$calendar_date + ((6 - as.integer(format(.data$calendar_date, "%w"))) %% 7)) %>%
    dplyr::filter(.data$date %in% window$weeks) %>%
    dplyr::group_by(.data$date, .data$sim_id) %>%
    dplyr::summarise(generated = sum(.data$generated), .groups = "drop")
  # A completed realization may end early after extinction; its remaining weeks
  # are zero, not missing observations that should disappear from the fit.
  tidyr::expand_grid(date = window$weeks, sim_id = ids) %>%
    dplyr::left_join(weekly, by = c("date", "sim_id")) %>%
    dplyr::mutate(generated = tidyr::replace_na(.data$generated, 0))
}
