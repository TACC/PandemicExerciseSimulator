#////////
#### Script Overview ####
#////////
#' Create pre-simulation input-data figures
#'
#' Run from the PES scripts directory or source in RStudio:
#'   source("9a_pre_sim_input_plots.R")
#'
#' Outputs mobility flow maps plus input-data diagnostic figures under:
#'   figures/
#'
#' @examples
#' analysis_year = 2025
#' source("9a_pre_sim_input_plots.R")
#////////
library(tidyverse)
library(lubridate)
library(jsonlite)
library(sf)
library(tigris)
library(ggrepel)

options(tigris_use_cache = TRUE)

args <- commandArgs(trailingOnly = TRUE)
get_arg_value <- function(prefix, default = NA_character_) {
  hit <- args[startsWith(args, prefix)]
  if (length(hit) == 0) return(default)
  sub(prefix, "", hit[[1]], fixed = TRUE)
}
split_arg_9a <- function(value, default) {
  if (is.null(value) || length(value) == 0 || !nzchar(value)) return(default)
  pieces <- trimws(unlist(strsplit(value, ",", fixed = TRUE)))
  pieces[nzchar(pieces)]
}

repo_root <- normalizePath(".", mustWork = FALSE)
if (basename(repo_root) == "scripts") {
  repo_root <- normalizePath("..", mustWork = TRUE)
}

analysis_year = as.integer(get_arg_value("--year=", as.character(get0("analysis_year", ifnotfound = 2025))))
pipeline_output_dir <- get_arg_value("--output-dir=", get0("PIPELINE_OUTPUT_DIR", ifnotfound = "STATE_H-INCREASE_ALL-ANTIVIAL_TEST"))
acs_year_range <- get_arg_value("--acs-year-range=", get0("ACS_YEAR_RANGE", ifnotfound = "2020-2024"))
sim_day_0_label <- get_arg_value("--sim-day-0-label=", get0("SIM_DAY_0_LABEL", ifnotfound = ""))
selected_states <- split_arg_9a(get_arg_value("--selected-states=", ""), character())
min_line_matrix_value = 0.1
top_outflow_county_fraction = 0.10
top_outflow_links_per_county = 5
high_risk_palette = c("#f3e79b", "#fac484", "#f8a07e", "#eb7f86", "#ce6693", "#a059a0", "#5c53a5")
initial_exposed_palette = c("#ffffcc", "#ffeda0", "#fed976", "#feb24c", "#fd8d3c", "#f03b20", "#bd0026")
contact_matrix_palette = high_risk_palette
#c("#07000d", "#2d1047", "#5c126e", "#9b1d64", "#d34a4a", "#f98e2b", "#fff176")
mobility_fill_palette = c("#FFF7BC", "#FEC44F")

search_root <- normalizePath(
  if (grepl("^/", pipeline_output_dir)) pipeline_output_dir else file.path(repo_root, pipeline_output_dir),
  mustWork = FALSE
)
master_csv = file.path(search_root, "metadata_master.csv")
derived_initial_exposed_dir = file.path(search_root, "DERIVED_INITIAL_EXPOSED")
input_figure_root = file.path(repo_root, "figures")
figure_dir = file.path(input_figure_root, "mobility-matrix-flow-maps")
outflow_figure_dir = file.path(input_figure_root, "mobility-matrix-flow-maps-by-outflow")
inflow_figure_dir = file.path(input_figure_root, "mobility-matrix-flow-maps-by-inflow")
initial_exposed_figure_dir = file.path(input_figure_root, "initial-exposed-by-county")
vaccine_figure_dir = file.path(input_figure_root, "vaccine-coverage-by-state")
high_risk_county_figure_dir = file.path(input_figure_root, "high-risk-county-maps")
comorbidity_figure_dir = file.path(input_figure_root, "comorbidity-heatmaps")
contact_matrix_figure_dir = file.path(input_figure_root, "age-specific-contact-matrices")
dir.create(figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(outflow_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(inflow_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(initial_exposed_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(vaccine_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(high_risk_county_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(comorbidity_figure_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(contact_matrix_figure_dir, showWarnings = FALSE, recursive = TRUE)

all_state_lookup = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%
  transmute(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_ABBR = state,
    STATE_DIR = stringr::str_replace_all(state_name, " ", "-")
  ) %>%
  dplyr::filter(as.integer(STATE_FIPS) < 60)

state_lookup = all_state_lookup
if (length(selected_states) > 0) {
  state_lookup <- state_lookup %>%
    dplyr::filter(.data$STATE_DIR %in% selected_states)
}

safe_num <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.nan(out), NA_real_, out)
}

parse_json_9a <- function(value) {
  if (is.na(value) || !nzchar(value)) return(tibble())
  tryCatch(jsonlite::fromJSON(value) %>% as_tibble(), error = function(e) tibble())
}

state_dir_to_name <- function(state_dir) {
  stringr::str_replace_all(state_dir, "-", " ")
}

first_nonmissing <- function(x, default = NA) {
  x <- x[!is.na(x) & nzchar(as.character(x))]
  if (length(x) == 0) default else x[[1]]
}

format_ve_label <- function(x) {
  label_value <- round(safe_num(x) * 100, 0)
  ifelse(is.na(label_value), "NA", as.character(label_value))
}

format_count_label <- function(x) {
  scales::label_number(accuracy = 1, scale_cut = scales::cut_short_scale())(x)
}

format_initial_exposed_percent_label <- function(x) {
  scales::label_number(accuracy = 0.001, suffix = "%", trim = TRUE)(x)
}

initial_exposed_midpoint_breaks <- function(x) {
  finite_x <- x[is.finite(x)]
  if (length(finite_x) == 0) return(NULL)

  min_x <- min(finite_x)
  max_x <- max(finite_x)
  sort(unique(c(
    min_x,
    (min_x + max_x) / 2,
    max_x
  )))
}

county_geo = tigris::counties(year = 2023, cb = TRUE, class = "sf") %>%
  dplyr::filter(as.integer(stringr::str_sub(.data$GEOID, 1, 2)) < 60) %>%
  st_transform(5070) %>%
  dplyr::select(GEOID, geometry)

county_geo_shifted = tigris::counties(year = 2023, cb = TRUE, class = "sf") %>%
  dplyr::filter(as.integer(stringr::str_sub(.data$GEOID, 1, 2)) < 60) %>%
  tigris::shift_geometry() %>%
  st_transform(5070) %>%
  dplyr::select(GEOID, geometry)

state_geo_shifted = county_geo_shifted %>%
  mutate(STATEFP = stringr::str_sub(.data$GEOID, 1, 2)) %>%
  group_by(.data$STATEFP) %>%
  summarise(geometry = st_union(.data$geometry), .groups = "drop")

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

read_county_pop = function(state_dir) {
  pop_file = file.path(
    repo_root,
    "data",
    state_dir,
    paste0("county_pop_by_age_", state_dir, "_", acs_year_range, "ACS.csv")
  )
  if (!file.exists(pop_file)) {
    warning("No county population file found for ", state_dir, ": ", pop_file)
    return(tibble(fips = character(), total_population = numeric()))
  }

  read_csv(
    pop_file,
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      fips = as.character(.data$fips),
      across(matches("^[0-9]+(-[0-9]+|\\+)$"), as.numeric),
      total_population = rowSums(pick(matches("^[0-9]+(-[0-9]+|\\+)$")), na.rm = TRUE)
    ) %>%
    dplyr::select(fips, total_population)
}

read_quarterly_matrix_od = function(state_dir, quarter, county_ids) {
  matrix_file = file.path(
    repo_root,
    "data",
    state_dir,
    paste0(state_dir, "_Q", quarter, "-", analysis_year, "_mobility-matrix.csv")
  )
  if (!file.exists(matrix_file)) return(tibble())

  matrix_values = as.matrix(
    readr::read_csv(
      matrix_file,
      col_names = FALSE,
      col_types = cols(.default = col_double()),
      progress = FALSE
    )
  )

  if (nrow(matrix_values) != length(county_ids) || ncol(matrix_values) != length(county_ids)) {
    warning(
      "Skipping ",
      matrix_file,
      ": matrix dimensions are ",
      nrow(matrix_values),
      "x",
      ncol(matrix_values),
      " but county population file has ",
      length(county_ids),
      " county rows."
    )
    return(tibble())
  }

  dimnames(matrix_values) = list(county_ids, county_ids)
  as.data.frame(as.table(matrix_values), stringsAsFactors = FALSE) %>%
    as_tibble() %>%
    transmute(
      COUNTY_ORG = as.character(.data$Var1),
      COUNTY_DEST = as.character(.data$Var2),
      MOBILITY_MATRIX_VALUE = as.numeric(.data$Freq),
      QUARTER = paste0("Q", quarter)
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
#' plot_state_od_map(quarterly_od, "Texas", county_pop, "2025-Q1", "map.png")
plot_state_od_map = function(
  od,
  state_dir,
  county_pop,
  period_label,
  out_file,
  fill_metric = c("population", "outflow", "inflow")
) {
  fill_metric <- match.arg(fill_metric)
  state_counties = sort(unique(c(od$COUNTY_ORG, od$COUNTY_DEST)))
  population_weighted_od <- od %>%
    left_join(county_pop, by = c("COUNTY_ORG" = "fips")) %>%
    mutate(
      total_population = replace_na(.data$total_population, 0),
      population_flow = if_else(
        .data$COUNTY_ORG == .data$COUNTY_DEST,
        0,
        .data$MOBILITY_MATRIX_VALUE * .data$total_population
      )
    )
  county_flow <- full_join(
    population_weighted_od %>%
      group_by(fips = .data$COUNTY_ORG) %>%
      summarise(total_population_outflow = sum(.data$population_flow, na.rm = TRUE), .groups = "drop"),
    population_weighted_od %>%
      group_by(fips = .data$COUNTY_DEST) %>%
      summarise(total_population_inflow = sum(.data$population_flow, na.rm = TRUE), .groups = "drop"),
    by = "fips"
  )
  fill_config <- tibble(
    fill_metric = c("population", "outflow", "inflow"),
    fill_column = c("total_population", "total_population_outflow", "total_population_inflow"),
    fill_name = c(
      "Total population\n(matrix assumed equal\nacross age/risk/vax)",
      "Total population\noutflow",
      "Total population\ninflow"
    ),
    title_suffix = c("population", "population outflow", "population inflow")
  ) %>%
    dplyr::filter(.data$fill_metric == !!fill_metric)

  state_geo = county_geo %>%
    dplyr::filter(GEOID %in% state_counties) %>%
    left_join(county_pop, by = c("GEOID" = "fips")) %>%
    left_join(county_flow, by = c("GEOID" = "fips")) %>%
    mutate(
      total_population_outflow = replace_na(.data$total_population_outflow, 0),
      total_population_inflow = replace_na(.data$total_population_inflow, 0),
      county_fill_value = .data[[fill_config$fill_column[[1]]]]
    )
  state_points = county_points %>% dplyr::filter(GEOID %in% state_counties)

  plotted_od = od %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST, MOBILITY_MATRIX_VALUE >= min_line_matrix_value)

  od_lines = plotted_od %>%
    arrange(desc(MOBILITY_MATRIX_VALUE)) %>%
    left_join(state_points %>% rename(COUNTY_ORG = GEOID, X_ORG = X, Y_ORG = Y), by = "COUNTY_ORG") %>%
    left_join(state_points %>% rename(COUNTY_DEST = GEOID, X_DEST = X, Y_DEST = Y), by = "COUNTY_DEST") %>%
    dplyr::filter(if_all(c(X_ORG, Y_ORG, X_DEST, Y_DEST), ~ !is.na(.x))) %>%
    make_od_lines()

  matrix_breaks = scales::breaks_pretty(n = 3)

  mobility_map = ggplot() +
    geom_sf(data = state_geo, aes(fill = .data$county_fill_value), color = NA) +
    geom_sf(
      data = od_lines,
      aes(linewidth = MOBILITY_MATRIX_VALUE, alpha = MOBILITY_MATRIX_VALUE, color = MOBILITY_MATRIX_VALUE),
      lineend = "round"
    ) +
    scale_fill_gradientn(
      colors = mobility_fill_palette,
      labels = scales::comma,
      name = fill_config$fill_name[[1]],
      guide = guide_colorbar(order = 2)
    ) +
    scale_color_gradient(
      low = "#BDECC1",
      high = "#006D2C",
      name = "Matrix value",
      breaks = matrix_breaks,
      guide = guide_legend(order = 1)
    ) +
    scale_linewidth(
      range = c(0.25, 1.4),
      name = "Matrix value",
      breaks = matrix_breaks,
      guide = guide_legend(order = 1)
    ) +
    scale_alpha(range = c(0.12, 0.85), guide = "none") +
    guides(
      color = guide_legend(order = 1),
      linewidth = guide_legend(order = 1),
      fill = guide_colorbar(order = 2)
    ) +
    coord_sf(datum = NA) +
    labs(
      title = paste0(state_dir, " county mobility matrix flows by ", fill_config$title_suffix[[1]]),
      subtitle = period_label,
      caption = stringr::str_wrap(paste0(
        "Lines show all off-diagonal OD pairs with matrix value >= ",
        scales::percent(min_line_matrix_value, accuracy = 1),
        "."
      ), width = 95)
    ) +
    theme_void(base_size = 18) +
    theme(
      plot.title = element_text(face = "bold", hjust = 0.5, size = 24),
      plot.subtitle = element_text(hjust = 0.5, size = 18),
      plot.caption = element_text(hjust = 0.5, size = 14, margin = margin(t = 10)),
      plot.margin = margin(t = 12, r = 18, b = 36, l = 18),
      legend.position = "right"
    )

  ggsave(out_file, mobility_map, width = 12, height = 9, units = "in", dpi = 300, bg = "white")
  invisible(out_file)
}

read_input_metadata <- function() {
  if (!file.exists(master_csv)) {
    warning("No metadata file found for input plots: ", master_csv)
    return(tibble())
  }

  readr::read_csv(master_csv, show_col_types = FALSE)
}

initial_exposed_by_county <- function(metadata) {
  if (nrow(metadata) == 0 || !"initial_exposed_json" %in% names(metadata)) return(tibble())

  metadata %>%
    distinct(.data$geo_region, .data$initial_exposed_json) %>%
    group_by(.data$geo_region) %>%
    slice(1) %>%
    ungroup() %>%
    mutate(initial_exposed = map(.data$initial_exposed_json, parse_json_9a)) %>%
    select("geo_region", "initial_exposed") %>%
    tidyr::unnest("initial_exposed") %>%
    transmute(
      geo_region = .data$geo_region,
      county = as.character(.data$county),
      infected = safe_num(.data$infected)
    ) %>%
    group_by(.data$geo_region, .data$county) %>%
    summarise(initial_exposed = sum(.data$infected, na.rm = TRUE), .groups = "drop")
}

read_derived_initial_exposed_by_county <- function() {
  if (!dir.exists(derived_initial_exposed_dir)) return(tibble())

  derived_file <- if (nzchar(sim_day_0_label)) {
    file.path(
      derived_initial_exposed_dir,
      paste0("derived_initial_exposed_county_age_", sim_day_0_label, ".csv")
    )
  } else {
    files <- list.files(
      derived_initial_exposed_dir,
      pattern = "^derived_initial_exposed_county_age_.*[.]csv$",
      full.names = TRUE
    )
    if (length(files) == 0) return(tibble())
    files[order(file.info(files)$mtime, decreasing = TRUE)][[1]]
  }

  if (!file.exists(derived_file)) {
    warning("No derived initial exposed county-age file found: ", derived_file)
    return(tibble())
  }

  message("Reading initial exposed seed data from ", derived_file)
  readr::read_csv(derived_file, show_col_types = FALSE) %>%
    transmute(
      geo_region = .data$state_dir,
      county = stringr::str_pad(as.character(.data$fips), width = 5, side = "left", pad = "0"),
      infected = safe_num(.data$infected)
    ) %>%
    group_by(.data$geo_region, .data$county) %>%
    summarise(initial_exposed = sum(.data$infected, na.rm = TRUE), .groups = "drop")
}

county_population_for_state_dirs <- function(state_dirs) {
  map_dfr(sort(unique(state_dirs)), function(state_dir) {
    read_county_pop(state_dir) %>%
      mutate(geo_region = state_dir)
  })
}

initial_exposed_fill_scale <- function(values) {
  scale_fill_gradientn(
    colors = initial_exposed_palette,
    breaks = initial_exposed_midpoint_breaks(values),
    labels = format_initial_exposed_percent_label,
    name = "Initial\nexposed\n(% pop)",
    na.value = "grey90"
  )
}

plot_initial_exposed_for_state <- function(initial_exposed_state, state_dir, out_file) {
  state_fips <- all_state_lookup %>%
    dplyr::filter(.data$STATE_DIR == state_dir) %>%
    pull(.data$STATE_FIPS) %>%
    first_nonmissing(default = NA_character_)

  county_pop <- read_county_pop(state_dir)

  plot_geo <- county_geo %>%
    dplyr::filter(stringr::str_sub(.data$GEOID, 1, 2) == state_fips) %>%
    left_join(initial_exposed_state, by = c("GEOID" = "county")) %>%
    left_join(county_pop, by = c("GEOID" = "fips")) %>%
    mutate(
      initial_exposed = replace_na(.data$initial_exposed, 0),
      initial_exposed_percent = if_else(
        .data$total_population > 0,
        100 * .data$initial_exposed / .data$total_population,
        NA_real_
      )
    )

  if (nrow(plot_geo) == 0) {
    warning("No county geometries matched initial exposed data for ", state_dir)
    return(invisible(NULL))
  }

  label_data <- plot_geo %>%
    st_point_on_surface() %>%
    mutate(
      label_x = st_coordinates(.data$geometry)[, 1],
      label_y = st_coordinates(.data$geometry)[, 2],
      exposed_label = format_count_label(.data$initial_exposed),
      county_area = as.numeric(sf::st_area(plot_geo$geometry)),
      is_small_label_county = .data$county_area < stats::median(.data$county_area, na.rm = TRUE) * 0.15
    ) %>%
    st_drop_geometry()

  regular_label_data <- label_data %>% dplyr::filter(!.data$is_small_label_county)
  small_label_data <- label_data %>% dplyr::filter(.data$is_small_label_county)

  p <- ggplot(plot_geo) +
    geom_sf(aes(fill = .data$initial_exposed_percent), color = "black", linewidth = 0.2) +
    geom_text(
      data = regular_label_data,
      aes(x = .data$label_x, y = .data$label_y, label = .data$exposed_label),
      inherit.aes = FALSE,
      size = 4.5,
      color = "black"
    ) +
    ggrepel::geom_text_repel(
      data = small_label_data,
      aes(x = .data$label_x, y = .data$label_y, label = .data$exposed_label),
      inherit.aes = FALSE,
      size = 4.5,
      seed = 1,
      min.segment.length = 0,
      segment.color = "grey25",
      segment.linewidth = 0.25,
      box.padding = 0.25,
      point.padding = 0.12,
      max.overlaps = Inf
    ) +
    initial_exposed_fill_scale(plot_geo$initial_exposed_percent) +
    coord_sf(datum = NA) +
    labs(
      title = paste0(state_dir_to_name(state_dir), ": Initial Exposed Seeded by County")
    ) +
    theme_void(base_size = 18) +
    theme(
      plot.title = element_text(face = "bold", hjust = 0.5),
      legend.position = "right"
    )

  ggsave(out_file, p, width = 12, height = 9, units = "in", dpi = 300, bg = "white")
  invisible(out_file)
}

plot_initial_exposed_for_us <- function(initial_exposed, out_file) {
  county_pop <- county_population_for_state_dirs(all_state_lookup$STATE_DIR)

  plot_geo <- county_geo_shifted %>%
    left_join(initial_exposed, by = c("GEOID" = "county")) %>%
    left_join(county_pop, by = c("GEOID" = "fips")) %>%
    mutate(
      initial_exposed = replace_na(.data$initial_exposed, 0),
      initial_exposed_percent = if_else(
        .data$total_population > 0,
        100 * .data$initial_exposed / .data$total_population,
        NA_real_
      )
    )

  p <- ggplot(plot_geo) +
    geom_sf(aes(fill = .data$initial_exposed_percent), color = "black", linewidth = 0.2) +
    geom_sf(data = state_geo_shifted, fill = NA, color = "black", linewidth = 0.2) +
    initial_exposed_fill_scale(plot_geo$initial_exposed_percent) +
    coord_sf(datum = NA) +
    labs(
      title = "US: Initial Exposed Seeded by County"
    ) +
    theme_void(base_size = 18) +
    theme(
      plot.title = element_text(face = "bold", hjust = 0.5),
      legend.position = "right"
    )

  ggsave(out_file, p, width = 14, height = 9, units = "in", dpi = 300, bg = "white")
  invisible(out_file)
}

save_initial_exposed_figures <- function(metadata) {
  initial_exposed <- read_derived_initial_exposed_by_county()
  if (nrow(initial_exposed) == 0) {
    initial_exposed <- initial_exposed_by_county(metadata)
  }
  if (nrow(initial_exposed) == 0) {
    warning("No initial exposed rows found in metadata.")
    return(invisible(initial_exposed))
  }

  readr::write_csv(initial_exposed, file.path(input_figure_root, "initial_exposed_by_county.csv"))

  for (state_dir_i in sort(unique(initial_exposed$geo_region))) {
    plot_initial_exposed_for_state(
      initial_exposed %>% dplyr::filter(.data$geo_region == state_dir_i),
      state_dir_i,
      file.path(initial_exposed_figure_dir, paste0(state_dir_i, "_initial-exposed-by-county.png"))
    )
  }

  plot_initial_exposed_for_us(
    initial_exposed,
    file.path(initial_exposed_figure_dir, "US_initial-exposed-by-county.png")
  )

  invisible(initial_exposed)
}

read_contact_matrix_for_state <- function(state_dir) {
  contact_file <- file.path(repo_root, "data", state_dir, paste0("contact_matrix_", state_dir, "_Mistry2021_all.csv"))
  if (!file.exists(contact_file)) {
    warning("No contact matrix file found for ", state_dir, ": ", contact_file)
    return(tibble())
  }

  age_groups <- c("0-4", "5-17", "18-49", "50-64", "65+")
  contact_matrix <- readr::read_csv(contact_file, col_names = FALSE, show_col_types = FALSE) %>%
    as.matrix()
  contact_matrix <- apply(contact_matrix, 2, safe_num)

  if (!all(dim(contact_matrix) == c(length(age_groups), length(age_groups)))) {
    warning("Contact matrix for ", state_dir, " did not have expected 5x5 dimensions.")
    return(tibble())
  }

  as_tibble(contact_matrix, .name_repair = "minimal") %>%
    setNames(age_groups) %>%
    mutate(contact_initiator = factor(age_groups, levels = age_groups)) %>%
    pivot_longer(
      cols = all_of(age_groups),
      names_to = "contactee",
      values_to = "contacts"
    ) %>%
    mutate(
      contactee = factor(.data$contactee, levels = age_groups),
      contact_initiator = factor(as.character(.data$contact_initiator), levels = age_groups)
    )
}

plot_contact_matrix_for_state <- function(state_dir, out_file) {
  contact_long <- read_contact_matrix_for_state(state_dir)
  if (nrow(contact_long) == 0) return(invisible(NULL))

  state_abbr <- all_state_lookup %>%
    dplyr::filter(.data$STATE_DIR == state_dir) %>%
    pull(.data$STATE_ABBR) %>%
    first_nonmissing(default = state_dir)

  p <- ggplot(contact_long, aes(x = .data$contactee, y = .data$contact_initiator, fill = .data$contacts)) +
    geom_tile(color = "grey65", linewidth = 0.8) +
    scale_fill_gradientn(
      colors = contact_matrix_palette,
      labels = scales::label_number(accuracy = 1),
      name = "Contacts"
    ) +
    coord_fixed() +
    labs(
      title = paste0("Age Group Pop Weighted Daily Contacts: ", state_abbr, " (Mistry et al. 2021 - All)"),
      x = "Age of Contactee (j)",
      y = "Age of Contact Initiator (i)"
    ) +
    theme_classic(base_size = 24) +
    theme(
      plot.title = element_text(hjust = 0.5, size = 24, face = "bold"),
      axis.title = element_text(size = 32),
      axis.text = element_text(size = 30),
      axis.text.x = element_text(angle = 0, size = 28),
      legend.title = element_text(size = 22),
      legend.text = element_text(size = 20),
      legend.position = "right",
      plot.margin = margin(t = 18, r = 18, b = 12, l = 18)
    )

  ggsave(out_file, p, width = 12, height = 8, bg = "white", units = "in", dpi = 300)
  invisible(out_file)
}

save_contact_matrix_figures <- function() {
  state_dirs <- all_state_lookup$STATE_DIR
  for (state_dir_i in state_dirs) {
    plot_contact_matrix_for_state(
      state_dir_i,
      file.path(contact_matrix_figure_dir, paste0(state_dir_i, "_age-specific-contact-matrix.png"))
    )
  }
  invisible(state_dirs)
}

save_vaccine_coverage_figures <- function(metadata) {
  vaccine_file <- file.path(repo_root, "data", "VACCINATION", "all_US_weekly_vax_adult-ped.csv")
  if (!file.exists(vaccine_file)) return(tibble())

  states_to_plot <- tibble()
  if (nrow(metadata) > 0 && "metadata_sim_day_0" %in% names(metadata)) {
    states_to_plot <- metadata %>%
      distinct(.data$geo_region, .data$metadata_sim_day_0) %>%
      transmute(
        geo_region = .data$geo_region,
        State = state_dir_to_name(.data$geo_region),
        sim_day_0 = as.Date(.data$metadata_sim_day_0)
      ) %>%
      group_by(.data$geo_region, .data$State) %>%
      summarise(sim_day_0 = first_nonmissing(.data$sim_day_0[order(.data$sim_day_0)], as.Date(NA)), .groups = "drop")
  }

  if (nrow(states_to_plot) < nrow(all_state_lookup)) {
    sim_day_0 <- if (nzchar(sim_day_0_label)) {
      as.Date(sim_day_0_label)
    } else {
      first_nonmissing(states_to_plot$sim_day_0[order(states_to_plot$sim_day_0)], as.Date(NA))
    }
    states_to_plot <- all_state_lookup %>%
      transmute(
        geo_region = .data$STATE_DIR,
        State = .data$STATE_NAME,
        sim_day_0 = sim_day_0
      )
  }

  vaccine_coverage <- readr::read_csv(vaccine_file, show_col_types = FALSE) %>%
    mutate(
      WeekEnd = as.Date(.data$WeekEnd),
      VaxCov = safe_num(.data$VaxCov),
      TotalVax = safe_num(.data$TotalVax),
      TotalFullProtect = safe_num(.data$TotalFullProtect),
      WeeklyNewFullProtect = safe_num(.data$WeeklyNewFullProtect),
      VE_Inpatient = safe_num(.data$VE_Inpatient)
    ) %>%
    inner_join(states_to_plot, by = "State") %>%
    arrange(.data$State, .data$AgeGroup, .data$WeekEnd)

  if (nrow(vaccine_coverage) == 0) return(tibble())

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
    state_data <- vaccine_coverage %>% dplyr::filter(.data$State == state)
    state_dir <- state_data$geo_region[[1]]
    state_day0 <- as.Date(first_nonmissing(as.character(state_data$sim_day_0), NA_character_))
    state_dose_long <- state_data %>%
      mutate(AgeGroupVE = paste0(.data$AgeGroup, ", VE=", format_ve_label(.data$VE_Inpatient), "%")) %>%
      pivot_longer(c("TotalVax", "TotalFullProtect"), names_to = "Series", values_to = "Value") %>%
      mutate(Series = recode(.data$Series, TotalVax = "Doses Given", TotalFullProtect = "Doses 100% VE"))

    age_labels <- state_dose_long %>% distinct(.data$AgeGroup, .data$AgeGroupVE) %>% arrange(match(.data$AgeGroup, c("Adult", "Pediatric")))
    age_colors <- setNames(ifelse(age_labels$AgeGroup == "Adult", "#CD622E", "#4499F5"), age_labels$AgeGroupVE)
    y_top <- max(state_dose_long$Value, na.rm = TRUE) * 0.8
    if (!is.finite(y_top)) y_top <- 0
    x_min <- min(state_dose_long$WeekEnd, state_day0, na.rm = TRUE) - 14
    x_max <- max(state_dose_long$WeekEnd, state_day0, na.rm = TRUE) + 7

    p <- ggplot(
      state_dose_long,
      aes(x = .data$WeekEnd, y = .data$Value, color = .data$AgeGroupVE, linetype = .data$Series, group = interaction(.data$AgeGroupVE, .data$Series))
    ) +
      geom_line(linewidth = 1.9) +
      geom_vline(xintercept = state_day0, linetype = "dotted", color = "grey30", linewidth = 1.0, show.legend = FALSE) +
      annotate("label", x = state_day0, y = y_top, label = "Sim Day 0", hjust = 0.5, vjust = -0.4, color = "grey30", fontface = "bold", size = 8) +
      scale_color_manual(values = age_colors, name = NULL) +
      scale_linetype_manual(values = c("Doses Given" = "solid", "Doses 100% VE" = "dashed"), name = NULL, breaks = c("Doses Given", "Doses 100% VE")) +
      scale_y_continuous(labels = scales::label_number(accuracy = 1, scale_cut = scales::cut_short_scale())) +
      scale_x_date(limits = c(x_min, x_max), expand = expansion(mult = c(0.02, 0.03))) +
      coord_cartesian(clip = "off") +
      guides(
        color = guide_legend(order = 1, nrow = 1, override.aes = list(linetype = "solid", linewidth = 3.2)),
        linetype = guide_legend(order = 2, nrow = 1, keywidth = grid::unit(2.6, "cm"), override.aes = list(color = "black", linewidth = 2.4, linetype = c("solid", "dashed")))
      ) +
      labs(x = "Week Ending Date", y = "2025-26 Influenza Vaccine Doses", title = state) +
      theme_bw(base_size = 24) +
      theme(
        plot.title = element_text(size = 42),
        axis.title = element_text(size = 32),
        axis.text = element_text(size = 26),
        legend.text = element_text(size = 22),
        legend.key.width = grid::unit(2.6, "cm"),
        legend.box = "vertical",
        legend.position = "bottom"
      )

    ggsave(file.path(vaccine_figure_dir, paste0(state_dir, "_VE_ts.png")), p, width = 16, height = 10, bg = "white", units = "in", dpi = 300)
  }

  readr::write_csv(vaccine_summary, file.path(input_figure_root, "vaccine_coverage_state_summary.csv"))
  vaccine_summary
}

save_high_risk_heatmap <- function(metadata) {
  high_risk_file <- file.path(repo_root, "data", "RISK_RATIOS", "all_US_high-risk-ratios-detailed.csv")
  if (!file.exists(high_risk_file)) return(invisible(NULL))

  high_risk_age <- readr::read_csv(high_risk_file, show_col_types = FALSE) %>%
    mutate(age_group = factor(.data$age_group, levels = c("0-4", "5-17", "18-49", "50-64", "65+")), frac_high_risk = safe_num(.data$frac_high_risk))

  if (nrow(high_risk_age) == 0) return(invisible(NULL))

  p <- ggplot(high_risk_age, aes(x = .data$age_group, y = .data$STATE_NAME, fill = .data$frac_high_risk * 100)) +
    geom_tile(color = "white") +
    geom_text(aes(label = round(.data$frac_high_risk * 100, 0)), color = "black", size = 4.5) +
    scale_y_discrete(limits = function(x) rev(x)) +
    scale_fill_gradientn(colors = high_risk_palette, name = "% High Risk", limits = c(0, 100)) +
    labs(x = NULL, y = NULL) +
    guides(fill = guide_colourbar(barheight = 0.5, barwidth = 20)) +
    theme_classic(base_size = 18) +
    theme(legend.position = "bottom")

  ggsave(file.path(input_figure_root, "high_risk_heatmap.png"), p, width = 8, height = 11, bg = "white", units = "in", dpi = 300)
  invisible(high_risk_age)
}

read_county_high_risk <- function() {
  high_risk_file <- file.path(repo_root, "data", "RISK_RATIOS", "all_US_county_high-risk-ratios-detailed.csv")
  if (!file.exists(high_risk_file)) {
    warning("County high-risk file not found: ", high_risk_file)
    return(tibble())
  }

  readr::read_csv(high_risk_file, show_col_types = FALSE) %>%
    mutate(
      fips = as.character(.data$fips),
      age_group = factor(.data$age_group, levels = c("0-4", "5-17", "18-49", "50-64", "65+")),
      pop = safe_num(.data$pop),
      frac_high_risk_cnty = safe_num(.data$frac_high_risk_cnty)
    )
}

plot_us_county_high_risk_map <- function(plot_data, fill_label, title, out_file) {
  plot_geo <- county_geo_shifted %>%
    left_join(plot_data, by = c("GEOID" = "fips"))

  p <- ggplot(plot_geo) +
    geom_sf(aes(fill = .data$high_risk_percent), color = NA) +
    geom_sf(data = state_geo_shifted, fill = NA, color = "white", linewidth = 0.18) +
    scale_fill_gradientn(
      colors = high_risk_palette,
      labels = scales::label_number(accuracy = 1),
      name = fill_label,
      na.value = "grey92"
    ) +
    coord_sf(datum = NA) +
    labs(title = title) +
    theme_void(base_size = 18) +
    theme(
      plot.title = element_text(face = "bold", hjust = 0.5),
      legend.position = "right"
    )

  ggsave(out_file, p, width = 14, height = 9, bg = "white", units = "in", dpi = 300)
  invisible(out_file)
}

save_county_high_risk_maps <- function() {
  county_risk <- read_county_high_risk()
  if (nrow(county_risk) == 0) return(invisible(county_risk))

  for (age_group_i in levels(county_risk$age_group)) {
    age_data <- county_risk %>%
      dplyr::filter(.data$age_group == age_group_i) %>%
      transmute(fips = .data$fips, high_risk_percent = .data$frac_high_risk_cnty * 100)

    plot_us_county_high_risk_map(
      age_data,
      paste0("High risk (%)\nAge ", age_group_i),
      paste0("US County Percent High Risk: Age ", age_group_i),
      file.path(high_risk_county_figure_dir, paste0("US_county_high-risk_age-", str_replace_all(age_group_i, "\\+", "plus"), ".png"))
    )
  }

  all_age_data <- county_risk %>%
    group_by(.data$fips) %>%
    summarise(
      high_risk_percent = weighted.mean(.data$frac_high_risk_cnty * 100, .data$pop, na.rm = TRUE),
      .groups = "drop"
    )

  plot_us_county_high_risk_map(
    all_age_data,
    "High risk (%)\nAll ages",
    "US County Percent High Risk: All Ages",
    file.path(high_risk_county_figure_dir, "US_county_high-risk_all-ages.png")
  )

  invisible(county_risk)
}

save_comorbidity_heatmap <- function() {
  comorb_files <- c(
    BRFSS = file.path(repo_root, "data", "RISK_RATIOS", "BRFSS-comorb_high-risk-ratios-detailed.csv"),
    NSCH = file.path(repo_root, "data", "RISK_RATIOS", "NSCH-comorb_high-risk-ratios-detailed.csv")
  )
  existing_files <- comorb_files[file.exists(comorb_files)]
  if (length(existing_files) == 0) return(invisible(NULL))

  state_names <- all_state_lookup %>%
    transmute(STATE_FIPS = .data$STATE_FIPS, STATE_NAME = .data$STATE_NAME)

  comorbidity <- imap_dfr(
    existing_files,
    \(path, source_name) {
      readr::read_csv(path, show_col_types = FALSE) %>%
        mutate(source = source_name)
    }
  ) %>%
    left_join(state_names, by = "STATE_FIPS") %>%
    mutate(
      age_group = factor(.data$age_group, levels = c("0-4", "5-17", "18-49", "50-64", "65+")),
      condition = factor(.data$condition, levels = sort(unique(.data$condition))),
      prevalence = safe_num(.data$prev),
      prevalence_percent = .data$prevalence * 100,
      prevalence_label = scales::label_number(accuracy = 0.01, trim = TRUE)(.data$prevalence),
      text_color = ifelse(.data$prevalence_percent >= 18, "white", "black")
    ) %>%
    dplyr::filter(!is.na(.data$STATE_NAME), !is.na(.data$age_group))

  if (nrow(comorbidity) == 0) return(invisible(NULL))

  for (source_i in unique(comorbidity$source)) {
    source_data <- comorbidity %>%
      dplyr::filter(.data$source == source_i) %>%
      mutate(condition = factor(as.character(.data$condition), levels = sort(unique(as.character(.data$condition)))))

    p <- ggplot(source_data, aes(x = .data$condition, y = .data$STATE_NAME, fill = .data$prevalence_percent)) +
      geom_tile(color = "white", linewidth = 0.15) +
      geom_text(aes(label = .data$prevalence_label, color = .data$text_color), size = 3.4) +
      facet_wrap(~ age_group, nrow = 1) +
      scale_y_discrete(limits = function(x) rev(x)) +
      scale_fill_gradientn(
        colors = high_risk_palette,
        limits = c(0, 30),
        oob = scales::squish,
        labels = scales::label_number(accuracy = 1),
        name = "Prevalence (%)"
      ) +
      scale_color_identity() +
      labs(x = "Comorbidity", y = NULL) +
      theme_bw(base_size = 18) +
      theme(
        axis.text.x = element_text(angle = 45, hjust = 1),
        panel.grid = element_blank(),
        strip.text = element_text(face = "bold", size = 18),
        legend.position = "bottom"
      )

    ggsave(
      file.path(comorbidity_figure_dir, paste0(source_i, "_state-age_comorb-prev.png")),
      p,
      width = ifelse(source_i == "BRFSS", 16, 14),
      height = 12,
      bg = "white",
      units = "in",
      dpi = 300
    )
  }

  invisible(comorbidity)
}

metadata <- read_input_metadata()
save_initial_exposed_figures(metadata)
invisible(save_vaccine_coverage_figures(metadata))
save_high_risk_heatmap(metadata)
save_county_high_risk_maps()
save_comorbidity_heatmap()
save_contact_matrix_figures()

for (state_dir_i in state_lookup$STATE_DIR) {
  files_i = file.path(
    repo_root,
    "data",
    state_dir_i,
    paste0(state_dir_i, "_Q", 1:4, "-", analysis_year, "_mobility-matrix.csv")
  )
  files_i = files_i[file.exists(files_i)]
  if (length(files_i) == 0) next

  state_fig_dir = file.path(figure_dir, state_dir_i)
  quarterly_fig_dir = file.path(state_fig_dir, "quarterly")
  outflow_state_fig_dir = file.path(outflow_figure_dir, state_dir_i)
  outflow_quarterly_fig_dir = file.path(outflow_state_fig_dir, "quarterly")
  inflow_state_fig_dir = file.path(inflow_figure_dir, state_dir_i)
  inflow_quarterly_fig_dir = file.path(inflow_state_fig_dir, "quarterly")
  dir.create(quarterly_fig_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(outflow_quarterly_fig_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(inflow_quarterly_fig_dir, showWarnings = FALSE, recursive = TRUE)

  message("Writing mobility matrix flow maps for ", state_dir_i)
  county_pop = read_county_pop(state_dir_i)
  if (nrow(county_pop) == 0) next
  county_ids = sort(county_pop$fips)

  for (quarter_i in 1:4) {
    quarter_od = read_quarterly_matrix_od(state_dir_i, quarter_i, county_ids)
    if (nrow(quarter_od) == 0) next
    period_label = paste0(analysis_year, "-Q", quarter_i)
    quarter_od_plot <- quarter_od %>% dplyr::select(COUNTY_ORG, COUNTY_DEST, MOBILITY_MATRIX_VALUE)
    plot_state_od_map(
      quarter_od_plot,
      state_dir_i,
      county_pop,
      period_label,
      file.path(quarterly_fig_dir, paste0(state_dir_i, "_", period_label, "_mobility-matrix-flow-map.png")),
      fill_metric = "population"
    )
    plot_state_od_map(
      quarter_od_plot,
      state_dir_i,
      county_pop,
      period_label,
      file.path(outflow_quarterly_fig_dir, paste0(state_dir_i, "_", period_label, "_mobility-matrix-flow-map_by-outflow.png")),
      fill_metric = "outflow"
    )
    plot_state_od_map(
      quarter_od_plot,
      state_dir_i,
      county_pop,
      period_label,
      file.path(inflow_quarterly_fig_dir, paste0(state_dir_i, "_", period_label, "_mobility-matrix-flow-map_by-inflow.png")),
      fill_metric = "inflow"
    )
  }
}
