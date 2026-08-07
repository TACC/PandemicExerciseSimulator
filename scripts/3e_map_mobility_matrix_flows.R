#///////////////////////////////////////////////////////////////////////
#' Map county OD mobility matrix values by state, month, and quarter
#'
#' Run from the PES scripts directory or source in RStudio:
#'   source("3e_map_mobility_matrix_flows.R")
#'
#' Outputs one PNG per state-month and state-quarter using OD matrix values,
#' not population-expanded flow volumes.
#'
#' @examples
#' analysis_year = 2025
#' source("3e_map_mobility_matrix_flows.R")
#///////////////////////////////////////////////////////////////////////

library(tidyverse)
library(lubridate)
library(sf)
library(tigris)

options(tigris_use_cache = TRUE)

analysis_year = 2025
max_lines_per_plot = 5000
top_outflow_county_fraction = 0.10

monthly_state_dir = "../data/MOBILITY/Advan/within-state_county-mobility"
figure_dir = "../figures/mobility-matrix-flow-maps"
dir.create(figure_dir, showWarnings = FALSE, recursive = TRUE)

state_lookup = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%
  transmute(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_DIR = stringr::str_replace_all(state_name, " ", "-")
  ) %>%
  dplyr::filter(as.integer(STATE_FIPS) < 60)

county_geo = tigris::counties(year = 2023, cb = TRUE, class = "sf") %>%
  st_transform(5070) %>%
  dplyr::select(GEOID, geometry)

county_points = county_geo %>%
  st_point_on_surface() %>%
  mutate(
    X = st_coordinates(geometry)[, 1],
    Y = st_coordinates(geometry)[, 2]
  ) %>%
  st_drop_geometry() %>%
  dplyr::select(GEOID, X, Y)

#' Create line geometry from OD county centroid coordinates
#'
#' @param od Tibble with origin and destination centroid coordinate columns.
#'
#' @return sf object with one LINESTRING per OD pair.
#'
#' @examples
#' make_od_lines(tibble::tibble(X_ORG = 0, Y_ORG = 0, X_DEST = 1, Y_DEST = 1))
make_od_lines = function(od) {
  st_as_sf(
    od %>%
      mutate(
        geometry = sprintf("LINESTRING(%f %f, %f %f)", X_ORG, Y_ORG, X_DEST, Y_DEST)
      ),
    wkt = "geometry",
    crs = 5070
  )
}

#' Plot one state OD mobility map
#'
#' @param od Tibble with `COUNTY_ORG`, `COUNTY_DEST`, and `MOBILITY_MATRIX_VALUE`.
#' @param state_dir Character state directory name.
#' @param county_pop Tibble with county `fips` and `total_population`.
#' @param period_label Character period label for title and file name.
#' @param out_file Character output PNG path.
#'
#' @return Invisibly returns output path.
#'
#' @examples
#' plot_state_od_map(monthly_od, "Texas", county_pop, "2025-01", "map.png")
plot_state_od_map = function(od, state_dir, county_pop, period_label, out_file) {
  state_counties = sort(unique(c(od$COUNTY_ORG, od$COUNTY_DEST)))
  state_geo = county_geo %>%
    dplyr::filter(GEOID %in% state_counties) %>%
    left_join(county_pop, by = c("GEOID" = "fips"))
  state_points = county_points %>% dplyr::filter(GEOID %in% state_counties)
  n_top_outflow_counties = max(1, ceiling(length(unique(od$COUNTY_ORG)) * top_outflow_county_fraction))
  top_outflow_counties = od %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST) %>%
    group_by(COUNTY_ORG) %>%
    summarise(outbound_matrix_share = sum(MOBILITY_MATRIX_VALUE, na.rm = TRUE), .groups = "drop") %>%
    slice_max(outbound_matrix_share, n = n_top_outflow_counties, with_ties = FALSE) %>%
    pull(COUNTY_ORG)
  top_outflow_geo = state_geo %>% dplyr::filter(GEOID %in% top_outflow_counties)

  od_lines = od %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST, MOBILITY_MATRIX_VALUE > 0) %>%
    arrange(desc(MOBILITY_MATRIX_VALUE)) %>%
    slice_head(n = max_lines_per_plot) %>%
    left_join(state_points %>% rename(COUNTY_ORG = GEOID, X_ORG = X, Y_ORG = Y), by = "COUNTY_ORG") %>%
    left_join(state_points %>% rename(COUNTY_DEST = GEOID, X_DEST = X, Y_DEST = Y), by = "COUNTY_DEST") %>%
    dplyr::filter(if_all(c(X_ORG, Y_ORG, X_DEST, Y_DEST), ~ !is.na(.x))) %>%
    make_od_lines()

  mobility_map = ggplot() +
    geom_sf(data = state_geo, aes(fill = total_population), color = "grey70", linewidth = 0.2) +
    geom_sf(data = top_outflow_geo, fill = NA, color = "black", linewidth = 0.75) +
    geom_sf(
      data = od_lines,
      aes(linewidth = MOBILITY_MATRIX_VALUE, alpha = MOBILITY_MATRIX_VALUE, color = MOBILITY_MATRIX_VALUE),
      lineend = "round"
    ) +
    scale_fill_gradient(
      low = "#FFF7BC",
      high = "#FEC44F",
      labels = scales::comma,
      name = "Total population\n(matrix assumed equal\nacross age/risk/vax)"
    ) +
    scale_color_gradient(low = "#BDECC1", high = "#006D2C", name = "Matrix value") +
    scale_linewidth(range = c(0.05, 1.1), name = "Matrix value") +
    scale_alpha(range = c(0.12, 0.85), guide = "none") +
    coord_sf(datum = NA) +
    labs(
      title = paste0(state_dir, " county mobility matrix flows"),
      subtitle = period_label,
      caption = paste0(
        "Lines show top ", scales::comma(max_lines_per_plot),
        " off-diagonal OD pairs by matrix value. Black county borders mark top ",
        scales::percent(top_outflow_county_fraction),
        " counties by summed off-diagonal outbound matrix share."
      )
    ) +
    theme_void(base_size = 14) +
    theme(
      plot.title = element_text(face = "bold", hjust = 0.5, size = 18),
      plot.subtitle = element_text(hjust = 0.5, size = 13),
      legend.position = "right"
    )

  ggsave(out_file, mobility_map, width = 12, height = 9, units = "in", dpi = 300, bg = "white")
  invisible(out_file)
}

monthly_files = list.files(
  monthly_state_dir,
  pattern = paste0("_", analysis_year, "-[0-9]{2}_within-state_county-mobility\\.csv$"),
  full.names = TRUE
)
if (length(monthly_files) == 0) {
  stop(paste("No monthly mobility files found in", monthly_state_dir))
}

for (state_dir_i in state_lookup$STATE_DIR) {
  files_i = monthly_files[startsWith(basename(monthly_files), paste0(state_dir_i, "_"))]
  if (length(files_i) == 0) next

  state_fig_dir = file.path(figure_dir, state_dir_i)
  monthly_fig_dir = file.path(state_fig_dir, "monthly")
  quarterly_fig_dir = file.path(state_fig_dir, "quarterly")
  dir.create(monthly_fig_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(quarterly_fig_dir, showWarnings = FALSE, recursive = TRUE)

  message("Writing mobility matrix flow maps for ", state_dir_i)
  county_pop = read_csv(
    file.path("../data", state_dir_i, paste0("county_pop_by_age_", state_dir_i, "_2019-2023ACS.csv")),
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      across(matches("^[0-9]+(-[0-9]+|\\+)$"), as.numeric),
      total_population = rowSums(pick(matches("^[0-9]+(-[0-9]+|\\+)$")), na.rm = TRUE)
    ) %>%
    dplyr::select(fips, total_population)

  monthly = map_dfr(files_i, read_csv, col_types = cols(.default = col_character()), progress = FALSE) %>%
    mutate(
      YEAR = as.integer(YEAR),
      MONTH = as.integer(MONTH),
      MOBILITY_MATRIX_VALUE = as.numeric(MOBILITY_MATRIX_VALUE),
      POPULATION_EXPANDED_DEVICE_COUNTS = as.numeric(POPULATION_EXPANDED_DEVICE_COUNTS),
      QUARTER = paste0("Q", lubridate::quarter(as.Date(sprintf("%s-%02d-01", YEAR, MONTH))))
    )

  monthly %>%
    group_split(YEAR, MONTH) %>%
    walk(function(month_i) {
      period_label = sprintf("%s-%02d", unique(month_i$YEAR), unique(month_i$MONTH))
      plot_state_od_map(
        month_i %>% dplyr::select(COUNTY_ORG, COUNTY_DEST, MOBILITY_MATRIX_VALUE),
        state_dir_i,
        county_pop,
        period_label,
        file.path(monthly_fig_dir, paste0(state_dir_i, "_", period_label, "_mobility-matrix-flow-map.png"))
      )
    })

  monthly %>%
    group_by(COUNTY_ORG, COUNTY_DEST, QUARTER) %>%
    summarise(
      QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS = sum(POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    group_by(QUARTER, COUNTY_ORG) %>%
    mutate(
      QUARTERLY_DENOMINATOR = sum(QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      MOBILITY_MATRIX_VALUE = if_else(
        QUARTERLY_DENOMINATOR > 0,
        QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS / QUARTERLY_DENOMINATOR,
        0
      )
    ) %>%
    ungroup() %>%
    group_split(QUARTER) %>%
    walk(function(quarter_i) {
      period_label = paste0(analysis_year, "-", unique(quarter_i$QUARTER))
      plot_state_od_map(
        quarter_i %>% dplyr::select(COUNTY_ORG, COUNTY_DEST, MOBILITY_MATRIX_VALUE),
        state_dir_i,
        county_pop,
        period_label,
        file.path(quarterly_fig_dir, paste0(state_dir_i, "_", period_label, "_mobility-matrix-flow-map.png"))
      )
    })
}
