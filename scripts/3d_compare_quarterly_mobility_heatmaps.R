#////////
#### Script Overview ####
#////////
#' Compare quarterly county mobility matrices
#'
#' Run from the PES scripts directory or source in RStudio:
#'   source("3d_compare_quarterly_mobility_heatmaps.R")
#'
#' The default behavior is to write one interactive HTML for every state.
#'
#' @examples
#' source("3d_compare_quarterly_mobility_heatmaps.R")
#////////
library(tidyverse)
library(lubridate)
library(jsonlite)

state_dir = "all"
reference_year = 2019
comparison_year = 2025

args = commandArgs(trailingOnly = TRUE)
state_arg = args[stringr::str_starts(args, "--state=")]
if (length(state_arg) > 0) {
  state_dir = stringr::str_remove(state_arg[[1]], "--state=")
}

#' Read quarterly OD mobility values for one state-year
#'
#' @param state_dir Character state directory, such as `"Alaska"`.
#' @param year Integer year, such as `2019` or `2025`.
#'
#' @return Tibble with `COUNTY_ORG`, `COUNTY_DEST`, `QUARTER`, and `MOBILITY_MATRIX_VALUE`.
#'
#' @examples
#' read_quarterly_od("Alaska", 2019)
read_quarterly_od = function(state_dir, year) {
  quarterly_file = file.path("../data", state_dir, paste0(state_dir, "_quarterly-", year, "_mobility.csv"))
  monthly_files = list.files(
    "../data/MOBILITY/Advan/within-state_county-mobility",
    pattern = paste0("^", state_dir, "_", year, "-[0-9]{2}_within-state_county-mobility\\.csv$"),
    full.names = TRUE
  )

  if (file.exists(quarterly_file)) {
    quarterly = read_csv(quarterly_file, col_types = cols(.default = col_character()), progress = FALSE)
    value_col = intersect(c("MOBILITY_MATRIX_VALUE", "mean_mobility_matrix_value", "mean_max_norm_prop_flow"), names(quarterly))[[1]]
    org_col = intersect(c("COUNTY_ORG", "geoid_o"), names(quarterly))[[1]]
    dest_col = intersect(c("COUNTY_DEST", "geoid_d"), names(quarterly))[[1]]
    quarter_col = intersect(c("QUARTER", "quarter"), names(quarterly))[[1]]

    return(quarterly %>%
      transmute(
        COUNTY_ORG = .data[[org_col]],
        COUNTY_DEST = .data[[dest_col]],
        QUARTER = paste0("Q", .data[[quarter_col]]),
        MOBILITY_MATRIX_VALUE = as.numeric(.data[[value_col]])
      ))
  }

  if (length(monthly_files) == 0) {
    stop(paste("No quarterly or monthly mobility files found for", state_dir, year))
  }

  map_dfr(monthly_files, read_csv, col_types = cols(.default = col_character()), progress = FALSE) %>%
    mutate(
      YEAR = as.integer(YEAR),
      MONTH = as.integer(MONTH),
      QUARTER = paste0("Q", lubridate::quarter(as.Date(sprintf("%s-%02d-01", YEAR, MONTH)))),
      POPULATION_EXPANDED_DEVICE_COUNTS = as.numeric(POPULATION_EXPANDED_DEVICE_COUNTS)
    ) %>%
    group_by(COUNTY_ORG, COUNTY_DEST, QUARTER) %>%
    summarise(
      QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS = sum(POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    group_by(QUARTER, COUNTY_ORG) %>%
    mutate(
      ORIGIN_ROW_DENOMINATOR = sum(QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      MOBILITY_MATRIX_VALUE = if_else(
        ORIGIN_ROW_DENOMINATOR > 0,
        QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS / ORIGIN_ROW_DENOMINATOR,
        0
      )
    ) %>%
    ungroup() %>%
    dplyr::select(COUNTY_ORG, COUNTY_DEST, QUARTER, MOBILITY_MATRIX_VALUE)
}

#' Write one interactive quarterly mobility comparison heatmap
#'
#' @param state_dir Character state directory, such as `"Texas"`.
#'
#' @return Invisibly returns the output HTML path.
#'
#' @examples
#' write_state_heatmap("Texas")
write_state_heatmap = function(state_dir) {
  reference = read_quarterly_od(state_dir, reference_year)
  comparison = read_quarterly_od(state_dir, comparison_year)
  counties = sort(unique(c(reference$COUNTY_ORG, reference$COUNTY_DEST, comparison$COUNTY_ORG, comparison$COUNTY_DEST)))
  figure_dir = file.path("../figures/quarterly-matrix-comparison")
  dir.create(figure_dir, showWarnings = FALSE, recursive = TRUE)

  plot_df = bind_rows(
    reference %>% mutate(COMPARISON_ROW = as.character(reference_year)),
    comparison %>% mutate(COMPARISON_ROW = as.character(comparison_year)),
    full_join(
      reference,
      comparison,
      by = c("COUNTY_ORG", "COUNTY_DEST", "QUARTER"),
      suffix = c("_reference", "_comparison")
    ) %>%
      transmute(
        COUNTY_ORG,
        COUNTY_DEST,
        QUARTER,
        MOBILITY_MATRIX_VALUE = replace_na(MOBILITY_MATRIX_VALUE_comparison, 0) -
          replace_na(MOBILITY_MATRIX_VALUE_reference, 0),
        COMPARISON_ROW = paste0(comparison_year, " minus ", reference_year)
      )
  ) %>%
    mutate(
      COUNTY_ORG = factor(COUNTY_ORG, levels = counties),
      COUNTY_DEST = factor(COUNTY_DEST, levels = counties),
      QUARTER = factor(QUARTER, levels = paste0("Q", 1:4)),
      COMPARISON_ROW = factor(COMPARISON_ROW, levels = c(as.character(reference_year), as.character(comparison_year), paste0(comparison_year, " minus ", reference_year))),
      hover_text = paste0(
        "Origin county: ", COUNTY_ORG,
        "<br>Destination county: ", COUNTY_DEST,
        "<br>Quarter: ", QUARTER,
        "<br>Panel: ", COMPARISON_ROW,
        "<br>Matrix value: ", scales::number(MOBILITY_MATRIX_VALUE, accuracy = 0.0001)
      )
    )

  out_file = file.path(
    figure_dir,
    paste0(state_dir, "_", reference_year, "_", comparison_year, "_quarterly_mobility_matrix_comparison.html")
  )

  panel_levels = levels(plot_df$COMPARISON_ROW)
  quarter_levels = levels(plot_df$QUARTER)
  y_counties = counties
  show_county_tick_labels = length(counties) <= 25
  heat_df = plot_df %>%
    complete(COMPARISON_ROW, QUARTER, COUNTY_ORG, COUNTY_DEST, fill = list(MOBILITY_MATRIX_VALUE = 0)) %>%
    mutate(hover_text = paste0(
      "Origin county: ", COUNTY_ORG,
      "<br>Destination county: ", COUNTY_DEST,
      "<br>Quarter: ", QUARTER,
      "<br>Panel: ", COMPARISON_ROW,
      "<br>Matrix value: ", scales::number(MOBILITY_MATRIX_VALUE, accuracy = 0.0001)
    ))
  max_abs_value = max(abs(heat_df$MOBILITY_MATRIX_VALUE), na.rm = TRUE)
  if (!is.finite(max_abs_value) || max_abs_value == 0) max_abs_value = 1

  plot_data = list()
  plot_layout = list(
    title = paste0(state_dir, " quarterly county mobility matrix comparison"),
    dragmode = "zoom",
    height = max(900, length(counties) * 12),
    margin = list(l = 130, b = 120, t = 90, r = 70),
    annotations = list()
  )

  axis_domain = function(i, n, gap = 0.025) c((i - 1) / n + gap, i / n - gap)
  trace_i = 0
  for (panel_i in seq_along(panel_levels)) {
    for (quarter_i in seq_along(quarter_levels)) {
      trace_i = trace_i + 1
      df_i = heat_df %>%
        dplyr::filter(COMPARISON_ROW == panel_levels[[panel_i]], QUARTER == quarter_levels[[quarter_i]])
      z_matrix = df_i %>%
        dplyr::select(COUNTY_ORG, COUNTY_DEST, MOBILITY_MATRIX_VALUE) %>%
        pivot_wider(names_from = COUNTY_DEST, values_from = MOBILITY_MATRIX_VALUE, values_fill = 0) %>%
        mutate(COUNTY_ORG = factor(COUNTY_ORG, levels = y_counties)) %>%
        arrange(COUNTY_ORG) %>%
        dplyr::select(all_of(counties)) %>%
        as.matrix()
      text_matrix = df_i %>%
        dplyr::select(COUNTY_ORG, COUNTY_DEST, hover_text) %>%
        pivot_wider(names_from = COUNTY_DEST, values_from = hover_text, values_fill = "") %>%
        mutate(COUNTY_ORG = factor(COUNTY_ORG, levels = y_counties)) %>%
        arrange(COUNTY_ORG) %>%
        dplyr::select(all_of(counties)) %>%
        as.matrix()
      axis_suffix = if (trace_i == 1) "" else as.character(trace_i)
      plot_data[[trace_i]] = list(
        type = "heatmap",
        x = counties,
        y = y_counties,
        z = z_matrix,
        text = text_matrix,
        xaxis = paste0("x", axis_suffix),
        yaxis = paste0("y", axis_suffix),
        hovertemplate = "%{text}<extra></extra>",
        colorscale = list(list(0, "#2166AC"), list(0.5, "white"), list(1, "#B2182B")),
        zmin = -max_abs_value,
        zmax = max_abs_value,
        showscale = trace_i == length(panel_levels) * length(quarter_levels),
        colorbar = list(title = "Value")
      )
      x_domain = axis_domain(quarter_i, length(quarter_levels), gap = 0.015)
      y_domain = 1 - rev(axis_domain(panel_i, length(panel_levels), gap = 0.035))
      plot_layout[[paste0("xaxis", axis_suffix)]] = list(
        domain = x_domain,
        title = "",
        type = "category",
        categoryorder = "array",
        categoryarray = counties,
        tickmode = if (show_county_tick_labels && panel_i == length(panel_levels)) "array" else "auto",
        tickvals = if (show_county_tick_labels && panel_i == length(panel_levels)) counties else NULL,
        ticktext = if (show_county_tick_labels && panel_i == length(panel_levels)) counties else NULL,
        tickangle = -90,
        ticks = if (show_county_tick_labels && panel_i == length(panel_levels)) "outside" else "",
        side = "bottom",
        showticklabels = show_county_tick_labels && panel_i == length(panel_levels),
        automargin = TRUE
      )
      plot_layout[[paste0("yaxis", axis_suffix)]] = list(
        domain = y_domain,
        title = if (quarter_i == 1) "Origin county" else "",
        type = "category",
        categoryorder = "array",
        categoryarray = y_counties,
        autorange = "reversed",
        showticklabels = show_county_tick_labels && quarter_i == 1,
        automargin = TRUE
      )
      if (panel_i == 1) {
        plot_layout$annotations[[length(plot_layout$annotations) + 1]] = list(
          text = quarter_levels[[quarter_i]],
          x = mean(x_domain),
          y = 1.02,
          xref = "paper",
          yref = "paper",
          showarrow = FALSE
        )
      }
      if (quarter_i == 1) {
        plot_layout$annotations[[length(plot_layout$annotations) + 1]] = list(
          text = panel_levels[[panel_i]],
          x = -0.04,
          y = mean(y_domain),
          xref = "paper",
          yref = "paper",
          showarrow = FALSE,
          textangle = -90
        )
      }
    }
  }
  plot_layout$annotations[[length(plot_layout$annotations) + 1]] = list(
    text = "Destination county",
    x = 0.5,
    y = -0.12,
    xref = "paper",
    yref = "paper",
    showarrow = FALSE
  )

  writeLines(c(
    "<!doctype html>",
    "<html>",
    "<head><meta charset='utf-8'><script src='https://cdn.plot.ly/plotly-2.35.2.min.js'></script></head>",
    "<body>",
    "<div id='mobility-heatmap' style='width:100%;height:95vh;'></div>",
    "<script>",
    paste0("const data = ", jsonlite::toJSON(plot_data, auto_unbox = TRUE, digits = 8), ";"),
    paste0("const layout = ", jsonlite::toJSON(plot_layout, auto_unbox = TRUE, digits = 8), ";"),
    "Plotly.newPlot('mobility-heatmap', data, layout, {responsive: true, scrollZoom: true});",
    "</script>",
    "</body>",
    "</html>"
  ), out_file)
  invisible(out_file)
}

states_to_plot = if (tolower(state_dir) == "all") {
  list.dirs("../data", full.names = FALSE, recursive = FALSE) %>%
    setdiff(c("MOBILITY")) %>%
    keep(~ file.exists(file.path("../data", .x, paste0(.x, "_quarterly-", reference_year, "_mobility.csv"))))
} else {
  state_dir
}

walk(states_to_plot, function(state_i) {
  message("Writing quarterly mobility comparison heatmap for ", state_i)
  tryCatch(
    message("Wrote ", write_state_heatmap(state_i)),
    error = function(e) message("Skipping ", state_i, ": ", conditionMessage(e))
  )
})
