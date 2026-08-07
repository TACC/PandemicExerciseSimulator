#///////////////////////////////////////////////////////////////////////
#' Create Advan within-state county mobility inputs
#'
#' Run from the PES scripts directory:
#'   Rscript 3c_advan_county_mobility.R --year=2025
#'
#' In RStudio, set `analysis_year` below before running the script.
#'
#' Inputs:
#'   ../../neighborhood-patterns-us-home-panel-summary/
#'   ../../YYYY-us-dc-mobility-data-csv/
#'
#' Outputs:
#'   ../data/MOBILITY/Advan/cleaned-direct-data/home-panel/
#'   ../data/MOBILITY/Advan/cleaned-direct-data/device-home-areas/
#'   ../data/MOBILITY/Advan/intermediate/
#'   ../data/MOBILITY/Advan/within-state_county-mobility/
#'   ../data/STATE/STATE_quarterly-YYYY_county-connection-ranking.csv
#'   ../data/STATE/STATE_QN-YYYY_mobility-matrix.csv
#'   ../figures/Advan/monthly-state-mobility-flows/
#///////////////////////////////////////////////////////////////////////

library(tidyverse)
library(jsonlite)
library(lubridate)

#///////////////////
#### USER SETUP ####
#///////////////////

analysis_year = 2025
args = commandArgs(trailingOnly = TRUE)
year_arg = args[stringr::str_starts(args, "--year=")]
if (length(year_arg) > 0) {
  analysis_year = as.integer(stringr::str_remove(year_arg[[1]], "--year="))
}
if (is.na(analysis_year)) {
  stop("analysis_year must be a four-digit year, for example 2025")
}

mobility_dir = file.path("..", "..", paste0(analysis_year, "-us-dc-mobility-data-csv"))
raw_home_panel_dir = "../../neighborhood-patterns-us-home-panel-summary"

advan_dir = "../data/MOBILITY/Advan"
home_panel_dir = file.path(advan_dir, "cleaned-direct-data", "home-panel")
device_home_areas_dir = file.path(advan_dir, "cleaned-direct-data", "device-home-areas")
intermediate_dir = file.path(advan_dir, "intermediate")
home_panel_county_dir = file.path(intermediate_dir, "county-home-panel")
county_device_counts_dir = file.path(intermediate_dir, "county-device-counts")
monthly_state_dir = file.path(advan_dir, "within-state_county-mobility")
monthly_fig_dir = "../figures/Advan/monthly-state-mobility-flows"
walk(
  c(home_panel_dir, device_home_areas_dir, home_panel_county_dir, county_device_counts_dir,
    monthly_state_dir, monthly_fig_dir),
  dir.create,
  showWarnings = FALSE,
  recursive = TRUE
)

state_lookup = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%
  transmute(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_ABBR = state,
    STATE_DIR = stringr::str_replace_all(state_name, " ", "-")
  ) %>%
  dplyr::filter(as.integer(STATE_FIPS) < 60)

#/////////////////////
#### SMALL HELPERS ####
#/////////////////////

#' Parse an Advan JSON object cell
#'
#' @param x Character scalar containing a JSON object, blank string, or `NA`.
#'
#' @return Named list; empty values return `list()`.
#'
#' @examples
#' parse_json_object('{"010010201001": 12}')
parse_json_object = function(x) {
  if (is.na(x) || x == "" || x == "{}") return(list())
  jsonlite::fromJSON(x)
}

#' Log elapsed runtime
#'
#' @param start_time POSIXct timestamp from `Sys.time()`.
#' @param label Character description of the timed block.
#'
#' @return Invisibly returns elapsed time as a lubridate period.
#'
#' @examples
#' log_elapsed_time(Sys.time(), "example block")
log_elapsed_time = function(start_time, label) {
  elapsed = lubridate::seconds_to_period(
    as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  )
  message(label, " run time ", elapsed)
  invisible(elapsed)
}

#' Read adult county populations for one state
#'
#' @param state_dir Character state directory name, such as `"Texas"`.
#'
#' @return Tibble with county FIPS and summed adult population.
#'
#' @examples
#' read_adult_pop("Texas")
read_adult_pop = function(state_dir) {
  read_csv(
    file.path("../data", state_dir, paste0("county_pop_by_age_", state_dir, "_2019-2023ACS.csv")),
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      across(any_of(c("18-49", "50-64", "65+")), as.numeric),
      adult_population = rowSums(pick(any_of(c("18-49", "50-64", "65+"))), na.rm = TRUE)
    ) %>%
    dplyr::select(fips, adult_population)
}

#' Convert a file name to a date-and-shard output name
#'
#' @param path Character path to one raw Advan mobility CSV.
#'
#' @return Character output path in `device_home_areas_dir`.
#'
#' @examples
#' device_home_areas_file("2025-01-01_0.csv")
device_home_areas_file = function(path) {
  file_name = basename(path)
  date_prefix = stringr::str_extract(file_name, "^[0-9]{4}-[0-9]{2}-[0-9]{2}")
  shard = stringr::str_match(file_name, "_([^_]+)\\.csv$")[, 2]
  if (is.na(date_prefix) || is.na(shard)) {
    stop(paste("Could not parse date prefix and shard from", file_name))
  }
  file.path(device_home_areas_dir, paste0("advan_device_home_areas_", date_prefix, "_", shard, ".csv"))
}

#///////////////////////////////////////
#### CLEAN DIRECT ADVAN MOBILITY CSVS ####
#///////////////////////////////////////

mobility_files = list.files(
  mobility_dir,
  pattern = paste0("^", analysis_year, "-.*\\.csv$"),
  full.names = TRUE
)
if (length(mobility_files) == 0) {
  stop(paste("No", analysis_year, "mobility files found in", mobility_dir))
}

for (path_i in mobility_files) {
  out_file = device_home_areas_file(path_i)
  if (file.exists(out_file)) {
    message("Skipping existing device home areas file: ", basename(out_file))
    next
  }

  message("Cleaning raw mobility file: ", basename(path_i))
  start_time = Sys.time()
  read_csv(path_i, col_types = cols(.default = col_character()), progress = FALSE) %>%
    dplyr::select(any_of(c(
      "YEAR", "MONTH", "REGION", "DATE_RANGE_START", "DATE_RANGE_END",
      "AREA", "DEVICE_HOME_AREAS"
    ))) %>%
    mutate(DEVICE_HOME_AREAS_PARSED = map(DEVICE_HOME_AREAS, parse_json_object)) %>%
    dplyr::select(-DEVICE_HOME_AREAS) %>%
    unnest_longer(
      DEVICE_HOME_AREAS_PARSED,
      values_to = "DEVICE_COUNTS",
      indices_to = "CBG_ORG"
    ) %>%
    rename(CBG_DEST = AREA) %>%
    mutate(
      DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
      SOURCE_FILE = basename(path_i)
    ) %>%
    dplyr::select(
      any_of(c("YEAR", "MONTH", "REGION", "DATE_RANGE_START", "DATE_RANGE_END")),
      CBG_DEST, CBG_ORG, DEVICE_COUNTS, SOURCE_FILE
    ) %>%
    write_csv(out_file)
  log_elapsed_time(start_time, "Device home areas cleaning block")
}

#//////////////////////////////////////
#### CLEAN DIRECT HOME-PANEL CSVS ####
#//////////////////////////////////////

raw_home_panel_files = list.files(
  raw_home_panel_dir,
  pattern = "^neighborhood-patterns-us-home-panel-summary_.*\\.csv$",
  full.names = TRUE
)
home_panel_files = list.files(
  home_panel_dir,
  pattern = "^advan_home_panel_us_[0-9]{4}_[0-9]{2}\\.csv$",
  full.names = TRUE
)
if (!any(stringr::str_detect(basename(home_panel_files), paste0("^advan_home_panel_us_", analysis_year, "_")))) {
  if (length(raw_home_panel_files) == 0) {
    stop(paste("No raw home-panel files found in", raw_home_panel_dir))
  }
  message("Creating cleaned monthly home-panel files")
  start_time = Sys.time()
  map_dfr(raw_home_panel_files, read_csv, col_types = cols(.default = col_character()), progress = FALSE) %>%
    dplyr::filter(ISO_COUNTRY_CODE == "US") %>%
    mutate(MONTH = as.integer(MONTH)) %>%
    group_split(YEAR, MONTH, .keep = TRUE) %>%
    walk(function(df) {
      write_csv(
        df,
        file.path(home_panel_dir, sprintf("advan_home_panel_us_%s_%02d.csv", unique(df$YEAR), unique(df$MONTH)))
      )
    })
  log_elapsed_time(start_time, "Cleaned monthly home-panel block")
}

#////////////////////////////////////
#### MONTHLY COUNTY INTERMEDIATES ####
#////////////////////////////////////

device_home_files = list.files(
  device_home_areas_dir,
  pattern = paste0("^advan_device_home_areas_", analysis_year, "-[0-9]{2}-[0-9]{2}_[^_]+\\.csv$"),
  full.names = TRUE
)
if (length(device_home_files) == 0) {
  stop(paste("No cleaned device home areas files found in", device_home_areas_dir))
}
device_file_index = tibble(PATH = device_home_files) %>%
  mutate(
    FILE = basename(PATH),
    YEAR = stringr::str_match(FILE, "^advan_device_home_areas_([0-9]{4})-([0-9]{2})-")[, 2],
    MONTH = as.integer(stringr::str_match(FILE, "^advan_device_home_areas_([0-9]{4})-([0-9]{2})-")[, 3]),
    YEAR_MONTH = paste0(YEAR, "-", stringr::str_pad(MONTH, 2, pad = "0"))
  )
year_month_set = sort(unique(device_file_index$YEAR_MONTH))

home_panel_files = list.files(
  home_panel_dir,
  pattern = "^advan_home_panel_us_[0-9]{4}_[0-9]{2}\\.csv$",
  full.names = TRUE
)
if (length(home_panel_files) == 0) {
  stop(paste("No cleaned monthly home-panel files found in", home_panel_dir))
}

for (year_month_i in year_month_set) {
  year_i = stringr::str_sub(year_month_i, 1, 4)
  month_i = as.integer(stringr::str_sub(year_month_i, 6, 7))
  target_month_i = as.Date(sprintf("%s-%02d-01", year_i, month_i))
  home_panel_county_file = file.path(home_panel_county_dir, paste0(year_month_i, "_county-home-panel.csv"))
  county_device_counts_file = file.path(county_device_counts_dir, paste0(year_month_i, "_county-device-counts.csv"))
  home_panel_intermediate_is_current = file.exists(home_panel_county_file) &&
    "TRACKED_DEVICES" %in% names(read_csv(
      home_panel_county_file,
      n_max = 0,
      show_col_types = FALSE,
      progress = FALSE
    ))

  if (!home_panel_intermediate_is_current) {
    message("Creating county tracked-device intermediate for ", year_month_i)
    start_time = Sys.time()
    county_home_panel = map_dfr(
      home_panel_files,
      read_csv,
      col_types = cols(.default = col_character()),
      progress = FALSE
    ) %>%
      dplyr::filter(
        ISO_COUNTRY_CODE == "US",
        stringr::str_detect(CENSUS_BLOCK_GROUP, "^[0-9]{12}$")
      ) %>%
      mutate(
        HOME_PANEL_MONTH = as.Date(sprintf("%s-%02d-01", YEAR, as.integer(MONTH))),
        TRACKED_DEVICES = as.numeric(NUMBER_DEVICES_RESIDING)
      ) %>%
      group_by(HOME_PANEL_MONTH) %>%
      dplyr::filter(HOME_PANEL_MONTH <= target_month_i, any(!is.na(TRACKED_DEVICES))) %>%
      ungroup() %>%
      dplyr::filter(HOME_PANEL_MONTH == max(HOME_PANEL_MONTH)) %>%
      transmute(
        YEAR = year_i,
        MONTH = month_i,
        STATE_FIPS = stringr::str_sub(CENSUS_BLOCK_GROUP, 1, 2),
        COUNTY = stringr::str_sub(CENSUS_BLOCK_GROUP, 1, 5),
        TRACKED_DEVICES = replace_na(TRACKED_DEVICES, 0)
      ) %>%
      group_by(YEAR, MONTH, STATE_FIPS, COUNTY) %>%
      summarise(TRACKED_DEVICES = sum(TRACKED_DEVICES, na.rm = TRUE), .groups = "drop")
    if (nrow(county_home_panel) == 0) {
      stop(paste("No home-panel tracked-device rows found for", year_month_i))
    }
    write_csv(county_home_panel, home_panel_county_file)
    log_elapsed_time(start_time, paste("County tracked-device aggregation block for", year_month_i))
  } else {
    message("Using existing county tracked-device intermediate for ", year_month_i)
  }

  if (!file.exists(county_device_counts_file)) {
    message("Creating county device-count intermediate for ", year_month_i)
    start_time = Sys.time()
    device_file_index %>%
      dplyr::filter(YEAR_MONTH == year_month_i) %>%
      pull(PATH) %>%
      map_dfr(function(path_i) {
        read_csv(path_i, col_types = cols(.default = col_character()), progress = FALSE) %>%
          dplyr::filter(
            stringr::str_detect(CBG_ORG, "^[0-9]{12}$"),
            stringr::str_detect(CBG_DEST, "^[0-9]{12}$")
          ) %>%
          transmute(
            YEAR,
            MONTH = as.integer(MONTH),
            DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
            STATE_ORG = stringr::str_sub(CBG_ORG, 1, 2),
            STATE_DEST = stringr::str_sub(CBG_DEST, 1, 2),
            COUNTY_ORG = stringr::str_sub(CBG_ORG, 1, 5),
            COUNTY_DEST = stringr::str_sub(CBG_DEST, 1, 5)
          ) %>%
          dplyr::filter(STATE_ORG == STATE_DEST) %>%
          group_by(YEAR, MONTH, STATE_FIPS = STATE_ORG, COUNTY_ORG, COUNTY_DEST) %>%
          summarise(DEVICE_COUNTS = sum(DEVICE_COUNTS, na.rm = TRUE), .groups = "drop")
      }) %>%
      group_by(YEAR, MONTH, STATE_FIPS, COUNTY_ORG, COUNTY_DEST) %>%
      summarise(DEVICE_COUNTS = sum(DEVICE_COUNTS, na.rm = TRUE), .groups = "drop") %>%
      write_csv(county_device_counts_file)
    log_elapsed_time(start_time, paste("County device counts cleaning block for", year_month_i))
  } else {
    message("Using existing county device-count intermediate for ", year_month_i)
  }
}

#//////////////////////////////////////////////////
#### MONTHLY STATE WITHIN-STATE COUNTY MOBILITY ####
#//////////////////////////////////////////////////

for (year_month_i in year_month_set) {
  expected_outputs = file.path(
    monthly_state_dir,
    paste0(state_lookup$STATE_DIR, "_", year_month_i, "_within-state_county-mobility.csv")
  )
  expected_outputs_exist = all(file.exists(expected_outputs))
  expected_outputs_are_current = expected_outputs_exist && all(map_lgl(
    expected_outputs,
    ~ all(c("ORIGIN_COVERAGE", "POPULATION_EXPANDED_DEVICE_COUNTS",
            "ORIGIN_ROW_DENOMINATOR", "MOBILITY_MATRIX_VALUE") %in% names(read_csv(
              .x,
              n_max = 0,
              show_col_types = FALSE,
              progress = FALSE
            )))
  ))
  if (expected_outputs_are_current) {
    message("Skipping existing monthly state files for ", year_month_i)
    next
  }

  message("Creating monthly state files for ", year_month_i)
  county_home_panel = read_csv(
    file.path(home_panel_county_dir, paste0(year_month_i, "_county-home-panel.csv")),
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      MONTH = as.integer(MONTH),
      TRACKED_DEVICES = as.numeric(TRACKED_DEVICES)
    )

  monthly_state_od = read_csv(
    file.path(county_device_counts_dir, paste0(year_month_i, "_county-device-counts.csv")),
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(MONTH = as.integer(MONTH), DEVICE_COUNTS = as.numeric(DEVICE_COUNTS)) %>%
    left_join(state_lookup, by = "STATE_FIPS") %>%
    dplyr::filter(!is.na(STATE_DIR)) %>%
    left_join(
      county_home_panel,
      by = c("YEAR", "MONTH", "STATE_FIPS", "COUNTY_ORG" = "COUNTY")
    ) %>%
    group_split(STATE_DIR, .keep = TRUE)

  monthly_state_od %>%
    iwalk(function(df, i) {
      state_dir_i = unique(df$STATE_DIR)
      adult_pop = read_adult_pop(state_dir_i) %>%
        rename(COUNTY_ORG = fips, ADULT_POPULATION_ORG = adult_population)

      df = df %>%
        left_join(adult_pop, by = "COUNTY_ORG") %>%
        # Trips from lower-coverage origin counties are expanded because each
        # tracked device represents more adults from that origin population.
        mutate(
          ORIGIN_COVERAGE = if_else(
            ADULT_POPULATION_ORG > 0,
            TRACKED_DEVICES / ADULT_POPULATION_ORG,
            NA_real_
          ),
          POPULATION_EXPANDED_DEVICE_COUNTS = if_else(
            ORIGIN_COVERAGE > 0,
            DEVICE_COUNTS / ORIGIN_COVERAGE,
            NA_real_
          )
        ) %>%
        group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, YEAR, MONTH, COUNTY_ORG) %>%
        mutate(
          ORIGIN_ROW_DENOMINATOR = sum(POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
          MOBILITY_MATRIX_VALUE = if_else(
            ORIGIN_ROW_DENOMINATOR > 0,
            POPULATION_EXPANDED_DEVICE_COUNTS / ORIGIN_ROW_DENOMINATOR,
            0
          )
        ) %>%
        ungroup() %>%
        dplyr::select(
          YEAR, MONTH, STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS,
          COUNTY_ORG, COUNTY_DEST, DEVICE_COUNTS, TRACKED_DEVICES,
          ADULT_POPULATION_ORG, ORIGIN_COVERAGE,
          POPULATION_EXPANDED_DEVICE_COUNTS, ORIGIN_ROW_DENOMINATOR,
          MOBILITY_MATRIX_VALUE
        ) %>%
        arrange(COUNTY_ORG, COUNTY_DEST)

      write_csv(
        df,
        file.path(monthly_state_dir, paste0(state_dir_i, "_", year_month_i, "_within-state_county-mobility.csv"))
      )
    })
}

#////////////////////////////////////
#### QUARTERLY MATRICES AND PLOTS ####
#////////////////////////////////////

state_monthly_files = list.files(
  monthly_state_dir,
  pattern = paste0("_", analysis_year, "-[0-9]{2}_within-state_county-mobility\\.csv$"),
  full.names = TRUE
)
if (length(state_monthly_files) == 0) {
  stop(paste("No monthly state mobility files found in", monthly_state_dir))
}

for (state_dir_i in state_lookup$STATE_DIR) {
  files_i = state_monthly_files[startsWith(basename(state_monthly_files), paste0(state_dir_i, "_"))]
  if (length(files_i) == 0) next

  message("Creating quarterly outputs and monthly plot for ", state_dir_i)
  start_time = Sys.time()

  monthly = map_dfr(files_i, read_csv, col_types = cols(.default = col_character()), progress = FALSE) %>%
    mutate(
      YEAR = as.integer(YEAR),
      MONTH = as.integer(MONTH),
      DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
      TRACKED_DEVICES = as.numeric(TRACKED_DEVICES),
      ADULT_POPULATION_ORG = as.numeric(ADULT_POPULATION_ORG),
      ORIGIN_COVERAGE = as.numeric(ORIGIN_COVERAGE),
      POPULATION_EXPANDED_DEVICE_COUNTS = as.numeric(POPULATION_EXPANDED_DEVICE_COUNTS),
      ORIGIN_ROW_DENOMINATOR = as.numeric(ORIGIN_ROW_DENOMINATOR),
      MOBILITY_MATRIX_VALUE = as.numeric(MOBILITY_MATRIX_VALUE),
      QUARTER = as.character(lubridate::quarter(as.Date(sprintf("%s-%02d-01", YEAR, MONTH))))
    )

  monthly %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, YEAR, MONTH, COUNTY_ORG) %>%
    summarise(
      ADULT_POPULATION_ORG = max(ADULT_POPULATION_ORG, na.rm = TRUE),
      out_of_county_share = sum(if_else(COUNTY_ORG == COUNTY_DEST, 0, MOBILITY_MATRIX_VALUE), na.rm = TRUE),
      .groups = "drop"
    ) %>%
    ungroup() %>%
    mutate(
      MONTH_DATE = as.Date(sprintf("%s-%02d-01", YEAR, MONTH)),
      ESTIMATED_ADULT_OUT_OF_COUNTY_FLOW = ADULT_POPULATION_ORG * replace_na(out_of_county_share, 0)
    ) %>%
    group_by(STATE_NAME, MONTH_DATE) %>%
    summarise(ESTIMATED_ADULT_OUT_OF_COUNTY_FLOW = sum(ESTIMATED_ADULT_OUT_OF_COUNTY_FLOW, na.rm = TRUE), .groups = "drop") %>%
    ggplot(aes(MONTH_DATE, ESTIMATED_ADULT_OUT_OF_COUNTY_FLOW)) +
    geom_line(color = "black", linewidth = 0.8) +
    geom_point(color = "#2C7FB8", size = 2) +
    scale_x_date(date_breaks = "1 month", date_labels = "%b") +
    scale_y_continuous(labels = scales::comma) +
    labs(
      x = paste0(analysis_year, " month"),
      y = "Estimated adult out-of-county flow",
      title = paste0(unique(monthly$STATE_NAME), " monthly out-of-county mobility"),
      subtitle = "Adult county populations are used; children are assumed to follow the same destination pattern."
    ) +
    theme_bw()
  ggsave(
    file.path(monthly_fig_dir, paste0(state_dir_i, "_", analysis_year, "_monthly_within-state_county-mobility-flow.png")),
    width = 10,
    height = 6,
    units = "in",
    bg = "white"
  )

  state_counties = sort(unique(c(monthly$COUNTY_ORG, monthly$COUNTY_DEST)))
  quarterly = monthly %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, COUNTY_ORG, COUNTY_DEST, QUARTER) %>%
    summarise(
      QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS = sum(POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, QUARTER, COUNTY_ORG) %>%
    mutate(
      QUARTERLY_ORIGIN_ROW_DENOMINATOR = sum(QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS, na.rm = TRUE),
      MOBILITY_MATRIX_VALUE = if_else(
        QUARTERLY_ORIGIN_ROW_DENOMINATOR > 0,
        QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS / QUARTERLY_ORIGIN_ROW_DENOMINATOR,
        0
      )
    ) %>%
    ungroup() %>%
    complete(
      nesting(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS),
      COUNTY_ORG = state_counties,
      COUNTY_DEST = state_counties,
      QUARTER = c("1", "2", "3", "4")
    ) %>%
    mutate(imputed = is.na(MOBILITY_MATRIX_VALUE)) %>%
    replace_na(list(
      QUARTERLY_POPULATION_EXPANDED_DEVICE_COUNTS = 0,
      QUARTERLY_ORIGIN_ROW_DENOMINATOR = 0,
      MOBILITY_MATRIX_VALUE = 0
    )) %>%
    arrange(STATE_DIR, COUNTY_ORG, COUNTY_DEST, QUARTER)

  state_out_dir = file.path("../data", state_dir_i)
  dir.create(state_out_dir, showWarnings = FALSE, recursive = TRUE)

  quarterly %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, QUARTER, COUNTY_ORG) %>%
    summarise(
      mobility_outflow = sum(MOBILITY_MATRIX_VALUE, na.rm = TRUE),
      total_counties_connected = sum(MOBILITY_MATRIX_VALUE > 0, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(STATE_DIR, QUARTER, desc(mobility_outflow), desc(total_counties_connected)) %>%
    write_csv(file.path(state_out_dir, paste0(state_dir_i, "_quarterly-", analysis_year, "_county-connection-ranking.csv")))

  for (quarter_i in c("1", "2", "3", "4")) {
    quarter_matrix = quarterly %>%
      dplyr::filter(QUARTER == quarter_i) %>%
      dplyr::select(COUNTY_ORG, COUNTY_DEST, MOBILITY_MATRIX_VALUE) %>%
      pivot_wider(names_from = COUNTY_DEST, values_from = MOBILITY_MATRIX_VALUE, values_fill = 0) %>%
      arrange(COUNTY_ORG) %>%
      dplyr::select(COUNTY_ORG, all_of(state_counties)) %>%
      dplyr::select(-COUNTY_ORG) %>%
      as.matrix()

    write.table(
      quarter_matrix,
      file.path(state_out_dir, paste0(state_dir_i, "_Q", quarter_i, "-", analysis_year, "_mobility-matrix.csv")),
      sep = ",",
      row.names = FALSE,
      col.names = FALSE
    )
  }

  log_elapsed_time(start_time, paste("Quarterly output block for", state_dir_i))
}
