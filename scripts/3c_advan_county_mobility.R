#///////////////////////////////////////////////////////////////////////
#' Create County Advan mobility intermediates
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
#'   ../data/MOBILITY/Advan/cleaned-direct-data/device-home-areas/advan_device_home_areas_YYYY-MM-DD_BATCH.csv
#'   ../data/MOBILITY/Advan/intermediate/home-panel-chunks/advan_home_panel_us_YYYY_MM_partNNN.csv
#'   ../data/MOBILITY/Advan/within-state_county-mobility/STATE_YYYY-MM_within-state_county-mobility.csv
#'   ../data/STATE/STATE_quarterly-YYYY_mobility.csv
#'   ../data/STATE/STATE_quarterly-YYYY_county-connection-ranking.csv
#'   ../data/STATE/STATE_QN-YYYY_mobility-matrix.csv
#'   ../figures/Advan/monthly-state-mobility-flows/STATE_YYYY_monthly_within-state_county-mobility-flow.png
#///////////////////////////////////////////////////////////////////////

library(tidyverse)
library(jsonlite)
library(lubridate)

#///////////////////
#### PATH SETUP ####
#///////////////////

# Set this value when running interactively in RStudio on TACC.
# Command-line use can still override it with `--year=2026`.
analysis_year = 2025

#' Get a command-line argument value by prefix
#'
#' @param prefix Character string prefix to match, such as `"--year="`.
#' @param default Value returned when no matching command-line argument is found.
#'
#' @return Character value supplied after `prefix`, or `default`.
#'
#' @examples
#' get_arg_value("--year=", "2025")
get_arg_value = function(prefix, default) {
  arg = commandArgs(trailingOnly = TRUE)
  match = arg[stringr::str_starts(arg, prefix)]
  if (length(match) == 0) {
    return(default)
  }
  stringr::str_remove(match[[1]], stringr::fixed(prefix))
}

analysis_year = as.integer(get_arg_value("--year=", as.character(analysis_year)))
if (is.na(analysis_year)) {
  stop("The --year argument must be a four-digit year, for example --year=2025")
}

# File name is always the same
# This is the count of tracked devices residing in each CBG per month and year
home_panel_dir = "../../neighborhood-patterns-us-home-panel-summary"

# File name depends on how you name the data in Dewey for download
# This is the actual mobility data of what CBGs visited others
mobility_dir = file.path("..", "..", paste0(analysis_year, "-us-dc-mobility-data-csv"))

# Output file prefix. Date and the final raw-file shard number are appended.
advan_dir = "../data/MOBILITY/Advan"
dir.create(advan_dir, showWarnings = FALSE, recursive = TRUE)
advan_intermediate_dir = file.path(advan_dir, "intermediate")
advan_cleaned_direct_data_dir = file.path(advan_dir, "cleaned-direct-data")
home_panel_chunk_dir = file.path(advan_intermediate_dir, "home-panel-chunks")
run_status_dir = file.path(advan_intermediate_dir, "run-status")
device_home_areas_dir = file.path(advan_cleaned_direct_data_dir, "device-home-areas")
county_mobility_dir = file.path(advan_dir, "within-state_county-mobility")
monthly_mobility_fig_dir = "../figures/Advan/monthly-state-mobility-flows"
dir.create(home_panel_chunk_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(run_status_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(device_home_areas_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(county_mobility_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(monthly_mobility_fig_dir, showWarnings = FALSE, recursive = TRUE)
device_home_areas_out_prefix = file.path(device_home_areas_dir, "advan_device_home_areas")

state_lookup = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%
  rename(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_ABBR = state
  ) %>%
  mutate(STATE_DIR = stringr::str_replace_all(STATE_NAME, " ", "-")) %>%
  dplyr::filter(as.integer(STATE_FIPS) < 60)

#/////////////////////
#### UTILITY FUNS ####
#/////////////////////

#' Parse a JSON object column value
#'
#' @param x Character scalar containing a JSON object, blank string, or `NA`.
#'
#' @return A named list parsed from `x`; empty values return `list()`.
#'
#' @examples
#' parse_json_object('{"010010201001": 12}')
parse_json_object = function(x) {
  if (is.na(x) || x == "" || x == "{}") {
    return(list())
  }
  jsonlite::fromJSON(x)
}

#' Write a CSV or append rows to an existing CSV
#'
#' @param df Data frame to write.
#' @param path Character path to the output CSV file.
#'
#' @return Invisibly writes `df` to `path`.
#'
#' @examples
#' write_or_append_csv(tibble::tibble(x = 1), tempfile(fileext = ".csv"))
write_or_append_csv = function(df, path) {
  if (!file.exists(path)) {
    readr::write_csv(df, path)
  } else {
    readr::write_csv(df, path, append = TRUE)
  }
}

#' Print elapsed runtime from a start time
#'
#' @param start_time POSIXct timestamp from `Sys.time()`.
#' @param label Character description of the timed code block.
#'
#' @return Invisibly returns the elapsed time as a lubridate period.
#'
#' @examples
#' log_elapsed_time(Sys.time(), "example block")
log_elapsed_time = function(start_time, label) {
  end_time = Sys.time()
  total_seconds = as.numeric(difftime(end_time, start_time, units = "secs"))
  final_time = lubridate::seconds_to_period(total_seconds)
  message(label, " run time ", final_time)
  invisible(final_time)
}

#' Find files in a primary directory and optional fallback directory
#'
#' @param primary_dir Character directory path for new organized outputs.
#' @param pattern Character regular expression passed to `list.files()`.
#' @param fallback_dir Optional character directory path containing older outputs.
#'
#' @return Character vector of unique matching file paths.
#'
#' @examples
#' find_output_files("new-dir", "^file.*\\.csv$", "old-dir")
find_output_files = function(primary_dir, pattern, fallback_dir = NULL) {
  primary_files = list.files(
    path = primary_dir,
    pattern = pattern,
    full.names = TRUE
  )

  if (is.null(fallback_dir)) {
    return(unique(primary_files))
  }

  fallback_files = list.files(
    path = fallback_dir,
    pattern = pattern,
    full.names = TRUE
  )

  unique(c(primary_files, fallback_files))
}

#' Read adult county population for one state
#'
#' @param state_dir Character state directory name, such as `"Texas"`.
#'
#' @return Tibble with county FIPS and summed adult population.
#'
#' @examples
#' read_state_adult_county_population("Texas")
read_state_adult_county_population = function(state_dir) {
  population_file = file.path(
    "../data",
    state_dir,
    paste0("county_pop_by_age_", state_dir, "_2019-2023ACS.csv")
  )

  if (!file.exists(population_file)) {
    stop(paste("No county population file found for", state_dir, "at", population_file))
  }

  read_csv(
    population_file,
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      across(any_of(c("18-49", "50-64", "65+")), as.numeric),
      adult_population = rowSums(pick(any_of(c("18-49", "50-64", "65+"))), na.rm = TRUE)
    ) %>%
    dplyr::select(fips, adult_population)
}

#' Build the device-home-areas output path for a raw mobility file
#'
#' @param path Character path to one raw Advan mobility CSV file.
#'
#' @return Character path for the cleaned device-home-areas CSV file.
#'
#' @examples
#' device_home_areas_output_file("2025-01-01-weekly_001.csv")
device_home_areas_output_file = function(path) {
  file_name = basename(path)
  date_prefix = stringr::str_extract(file_name, "^[0-9]{4}-[0-9]{2}-[0-9]{2}")
  final_shard = stringr::str_match(file_name, "_([^_]+)\\.csv$")[, 2]

  if (is.na(date_prefix) || is.na(final_shard)) {
    stop(paste("Could not parse date prefix and final shard from", file_name))
  }

  file.path(advan_dir,
    paste0(basename(device_home_areas_out_prefix), 
           "_", date_prefix,
           "_", final_shard, ".csv" ))
  }

#//////////////////////////////////////////////////
#### CBG_DEST, CBG_ORG, DEVICE_COUNTS BY FILE ####
#//////////////////////////////////////////////////

mobility_files = list.files(
  path = mobility_dir,
  pattern = paste0("^", analysis_year, "-.*\\.csv$"),
  full.names = TRUE
)

if (length(mobility_files) == 0) {
  stop(paste("No", analysis_year, "mobility files found in", mobility_dir))
}

device_home_areas_out_files = unique(map_chr(mobility_files, 
                                             device_home_areas_output_file ))

for (i in seq_along(mobility_files)) {
  device_home_areas_out_file = device_home_areas_output_file(mobility_files[i])
  legacy_device_home_areas_out_file = file.path(
    advan_dir,
    basename(device_home_areas_out_file)
  )

  if (file.exists(device_home_areas_out_file) ||
      file.exists(legacy_device_home_areas_out_file)) {
    message("Skipping existing device home areas file: ",
            basename(device_home_areas_out_file))
    next
  }

  message("Reading mobility file ", i, " of ", length(mobility_files), ": ",
          basename(mobility_files[i]))

  mobility_df = read_csv(
    mobility_files[i],
    col_types = cols(.default = col_character()),
    progress = FALSE
  )

  clean_start_time = Sys.time()
  device_home_areas_df = mobility_df %>%
    dplyr::select(
      any_of(c(
        "YEAR",
        "MONTH",
        "REGION",
        "DATE_RANGE_START",
        "DATE_RANGE_END",
        "AREA",
        "DEVICE_HOME_AREAS" ))
    ) %>%
    mutate(
      DEVICE_HOME_AREAS_PARSED = map(DEVICE_HOME_AREAS, parse_json_object)
    ) %>%
    dplyr::select(-DEVICE_HOME_AREAS) %>%
    tidyr::unnest_longer(
      DEVICE_HOME_AREAS_PARSED,
      values_to = "DEVICE_COUNTS",
      indices_to = "CBG_ORG"
    ) %>%
    rename(CBG_DEST = AREA) %>%
    mutate(
      DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
      SOURCE_FILE = basename(mobility_files[i])
    ) %>%
    dplyr::select(any_of(c( "YEAR",
                            "MONTH",
                            "REGION",
                            "DATE_RANGE_START",
                            "DATE_RANGE_END" )),
                  CBG_DEST,
                  CBG_ORG,
                  DEVICE_COUNTS,
                  SOURCE_FILE
    )

  write_or_append_csv(device_home_areas_df, device_home_areas_out_file)
  log_elapsed_time(clean_start_time, "Device home areas cleaning block")
  
} # end loop over 

#///////////////////////////////////////////////////////////
#### US-ONLY HOME PANEL FOR ANALYSIS YEAR, BATCHED BY YEAR/MONTH ####
#///////////////////////////////////////////////////////////

home_panel_out_prefix = file.path(home_panel_chunk_dir, "advan_home_panel_us")
# Part numbers restart for each year-month; every month can have a part001 file.
home_panel_chunk_n = 250000 # approx number of CBGs in the US

#' Build a monthly home panel chunk output path
#'
#' @param year Integer or character four-digit analysis year, such as `2025`.
#' @param month Integer month number from 1 to 12.
#' @param part Integer chunk number within the month.
#'
#' @return Character path for the home panel chunk CSV file.
#'
#' @examples
#' home_panel_output_file(2025, 1, 1)
home_panel_output_file = function(year, month, part) {
  file.path(
    home_panel_chunk_dir,
    paste0(
      basename(home_panel_out_prefix),
      "_",
      year,
      "_",
      stringr::str_pad(month, width = 2, pad = "0"),
      "_part",
      stringr::str_pad(part, width = 3, pad = "0"),
      ".csv" ))
  }

#' Get a numeric value stored in an environment
#'
#' @param env Environment containing keyed numeric values.
#' @param key Character key to look up.
#' @param default Numeric value returned when `key` is absent.
#'
#' @return Numeric value stored at `key`, or `default`.
#'
#' @examples
#' get_env_num(new.env(parent = emptyenv()), "2025_01", 1)
get_env_num = function(env, key, default = 0) {
  if (exists(key, envir = env, inherits = FALSE)) {
    get(key, envir = env, inherits = FALSE)
  } else {
    default
  }
}

#' Set a numeric value in an environment
#'
#' @param env Environment where the value should be assigned.
#' @param key Character key to assign.
#' @param value Numeric value to store.
#'
#' @return Assigned value, invisibly.
#'
#' @examples
#' set_env_num(new.env(parent = emptyenv()), "2025_01", 2)
set_env_num = function(env, key, value) {
  assign(key, value, envir = env)
}

#' Count data rows in a CSV file
#'
#' @param path Character path to a CSV file with one header row.
#'
#' @return Integer number of non-header rows in `path`.
#'
#' @examples
#' count_csv_data_rows("advan_home_panel_us_2025_01_part001.csv")
count_csv_data_rows = function(path) {
  con = file(path, open = "r")
  on.exit(close(con))

  line_count = 0
  repeat {
    lines = readLines(con, n = 100000, warn = FALSE)
    if (length(lines) == 0) {
      break
    }
    line_count = line_count + length(lines)
  }

  max(line_count - 1, 0)
}

#' Parse year, month, and part metadata from a home panel chunk path
#'
#' @param path Character path to a home panel chunk CSV file.
#'
#' @return Tibble with `PATH`, `YEAR`, `MONTH`, `YEAR_MONTH`, and `PART`.
#'
#' @examples
#' home_panel_chunk_details("advan_home_panel_us_2025_01_part001.csv")
home_panel_chunk_details = function(path) {
  parsed = stringr::str_match(
    basename(path),
    "^advan_home_panel_us_([0-9]{4})_([0-9]{2})_part([0-9]{3})\\.csv$"
  )

  tibble(
    PATH = path,
    YEAR = parsed[, 2],
    MONTH = parsed[, 3],
    YEAR_MONTH = paste0(parsed[, 2], "_", parsed[, 3]),
    PART = as.integer(parsed[, 4])
  )
}

#' Initialize home panel chunk write state from existing chunk files
#'
#' @param part_env Environment tracking the next part number by year-month.
#' @param row_env Environment tracking row counts in the active part by year-month.
#' @param chunk_files Character vector of existing home panel chunk CSV paths.
#'
#' @return `NULL`; updates `part_env` and `row_env` by reference.
#'
#' @examples
#' initialize_home_panel_chunk_state(new.env(), new.env(), character())
initialize_home_panel_chunk_state = function(part_env, row_env, chunk_files) {
  if (length(chunk_files) == 0) {
    return(NULL)
  }

  chunk_index = map_dfr(chunk_files, home_panel_chunk_details)

  chunk_index %>%
    group_by(YEAR_MONTH) %>%
    arrange(PART, .by_group = TRUE) %>%
    slice_tail(n = 1) %>%
    ungroup() %>%
    pwalk(function(PATH, YEAR, MONTH, YEAR_MONTH, PART) {
      rows_in_part = count_csv_data_rows(PATH)

      if (rows_in_part >= home_panel_chunk_n) {
        set_env_num(part_env, YEAR_MONTH, PART + 1)
        set_env_num(row_env, YEAR_MONTH, 0)
      } else {
        set_env_num(part_env, YEAR_MONTH, PART)
        set_env_num(row_env, YEAR_MONTH, rows_in_part)
      }
    })
}

#' Write monthly home panel rows into CSV chunks
#'
#' @param df Data frame of US home panel rows for one year-month.
#' @param year Integer or character four-digit analysis year, such as `2025`.
#' @param month Integer month number from 1 to 12.
#' @param part_env Environment tracking the next part number by year-month.
#' @param row_env Environment tracking row counts in the active part by year-month.
#'
#' @return `NULL`; writes one or more CSV files to `advan_dir`.
#'
#' @examples
#' write_home_panel_chunks(tibble::tibble(YEAR = 2025, MONTH = 1), 2025, 1, new.env(), new.env())
write_home_panel_chunks = function(df, year, month, part_env, row_env) {
  if (nrow(df) == 0) {
    return(NULL)
  }

  key = paste0(year, "_", stringr::str_pad(month, width = 2, pad = "0"))
  part = get_env_num(part_env, key, 1)
  rows_in_part = get_env_num(row_env, key, 0)
  remaining_df = df

  while (nrow(remaining_df) > 0) {
    room = home_panel_chunk_n - rows_in_part
    rows_to_write = min(room, nrow(remaining_df))
    chunk = remaining_df[seq_len(rows_to_write), , drop = FALSE]
    out_file = home_panel_output_file(year, month, part)

    write_or_append_csv(chunk, out_file)

    rows_in_part = rows_in_part + rows_to_write
    if (rows_in_part >= home_panel_chunk_n) {
      part = part + 1
      rows_in_part = 0
    }

    if (rows_to_write == nrow(remaining_df)) {
      remaining_df = remaining_df[0, , drop = FALSE]
    } else {
      remaining_df = remaining_df[(rows_to_write + 1):nrow(remaining_df), , drop = FALSE]
    }
  }

  set_env_num(part_env, key, part)
  set_env_num(row_env, key, rows_in_part)
}

home_panel_files = list.files(
  path = home_panel_dir,
  pattern = "^neighborhood-patterns-us-home-panel-summary_.*\\.csv$",
  full.names = TRUE
)

if (length(home_panel_files) == 0) {
  stop(paste("No home panel files found in", home_panel_dir))
}

old_home_panel_out_files = find_output_files(
  primary_dir = home_panel_chunk_dir,
  pattern = paste0(
    "^advan_home_panel_us_",
    analysis_year,
    "_[0-9]{2}_part[0-9]{3}\\.csv$"
  ),
  fallback_dir = advan_dir
)

home_panel_part_env = new.env(parent = emptyenv())
home_panel_row_env = new.env(parent = emptyenv())
initialize_home_panel_chunk_state(
  home_panel_part_env,
  home_panel_row_env,
  old_home_panel_out_files
)

for (i in seq_along(home_panel_files)) {
  clean_start_time = Sys.time()
  source_tag = stringr::str_remove(basename(home_panel_files[i]), "\\.csv$")
  source_done_file = file.path(
    run_status_dir,
    paste0("advan_home_panel_us_", analysis_year, "_done_", source_tag, ".csv")
  )

  if (file.exists(source_done_file)) {
    message("Skipping completed home panel file ", i, " of ",
            length(home_panel_files), ": ", basename(home_panel_files[i]))
    next
  }

  message("Reading home panel file ", i, " of ", length(home_panel_files), ": ",
          basename(home_panel_files[i]))

  home_panel_df = read_csv(
    home_panel_files[i],
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    dplyr::filter(
      ISO_COUNTRY_CODE == "US",
      YEAR == as.character(analysis_year),
      stringr::str_detect(CENSUS_BLOCK_GROUP, "^[0-9]{12}$")
    ) %>%
    mutate(
      MONTH = as.integer(MONTH),
      NUMBER_DEVICES_RESIDING = replace_na(as.numeric(NUMBER_DEVICES_RESIDING), 0)
    ) %>%
    dplyr::select(
      YEAR,
      MONTH,
      REGION,
      CENSUS_BLOCK_GROUP,
      NUMBER_DEVICES_RESIDING
    )

  home_panel_df %>%
    group_split(YEAR, MONTH, .keep = TRUE) %>%
    walk(function(month_df) {
      write_home_panel_chunks(
        month_df,
        unique(month_df$YEAR),
        unique(month_df$MONTH),
        home_panel_part_env,
        home_panel_row_env
      )
    })

  readr::write_csv(
    tibble(
      ANALYSIS_YEAR = analysis_year,
      SOURCE_FILE = basename(home_panel_files[i]),
      COMPLETED_AT = as.character(Sys.time())
    ),
    source_done_file
  )
  log_elapsed_time(clean_start_time, "Home panel cleaning and chunking block")
} # finish cleaning home panel files

#//////////////////////////////////////////////////////////////////
#### COUNTY-LEVEL DAILY MOBILITY MATRIX, BATCHED BY YEAR/MONTH ####
#//////////////////////////////////////////////////////////////////

#' Build a state monthly within-state county mobility output path
#'
#' @param state_dir Character state directory name, such as `"Texas"`.
#' @param year_month Character year-month string, such as `"2025-01"`.
#'
#' @return Character path for the monthly state within-state county mobility CSV file.
#'
#' @examples
#' state_monthly_county_mobility_output_file("Texas", "2025-01")
state_monthly_county_mobility_output_file = function(state_dir, year_month) {
  file.path(
    county_mobility_dir,
    paste0(
      state_dir,
      "_",
      year_month,
      "_within-state_county-mobility.csv"
    )
  )
}

#' Build a state data-directory output path
#'
#' @param state_dir Character state directory name, such as `"Texas"`.
#' @param filename Character output filename.
#'
#' @return Character path inside `../data/<STATE>/`.
#'
#' @examples
#' state_data_output_file("Texas", "Texas_Q1-2025_mobility-matrix.csv")
state_data_output_file = function(state_dir, filename) {
  state_dir_path = file.path("../data", state_dir)
  dir.create(state_dir_path, showWarnings = FALSE, recursive = TRUE)
  file.path(state_dir_path, filename)
}

#' Build a monthly state mobility-flow figure path
#'
#' @param state_dir Character state directory name, such as `"Texas"`.
#' @param year Integer or character four-digit analysis year, such as `2025`.
#'
#' @return Character path for the state monthly mobility-flow PNG.
#'
#' @examples
#' state_monthly_flow_figure_file("Texas", 2025)
state_monthly_flow_figure_file = function(state_dir, year) {
  file.path(
    monthly_mobility_fig_dir,
    paste0(state_dir, "_", year, "_monthly_within-state_county-mobility-flow.png")
  )
}

#' Parse year and month metadata from a cleaned device-home-areas path
#'
#' @param path Character path to a cleaned device-home-areas CSV file.
#'
#' @return Tibble with `SOURCE_FILE`, `YEAR`, `MONTH`, and `YEAR_MONTH`.
#'
#' @examples
#' county_month_from_device_file("advan_device_home_areas_2025-01-01_001.csv")
county_month_from_device_file = function(path) {
  file_name = basename(path)
  parsed = stringr::str_match(
    file_name,
    "^advan_device_home_areas_([0-9]{4})-([0-9]{2})-[0-9]{2}_[^_]+\\.csv$"
  )

  if (is.na(parsed[, 1])) {
    stop(paste("Could not parse year/month from", file_name))
  }

  tibble(
    SOURCE_FILE = file_name,
    YEAR = parsed[, 2],
    MONTH = as.integer(parsed[, 3]),
    YEAR_MONTH = paste0(parsed[, 2], "_", parsed[, 3])
  )
}

device_home_areas_clean_files = find_output_files(
  primary_dir = device_home_areas_dir,
  pattern = paste0(
    "^advan_device_home_areas_",
    analysis_year,
    "-[0-9]{2}-[0-9]{2}_[^_]+\\.csv$"
  ),
  fallback_dir = advan_dir
)

if (length(device_home_areas_clean_files) == 0) {
  stop(paste("No clean", analysis_year, "device home area files found in", advan_dir))
}

device_file_index = map_dfr(
  device_home_areas_clean_files,
  function(path_i) {
    county_month_from_device_file(path_i) %>%
      mutate(PATH = path_i)
  }
)

year_month_set = sort(unique(device_file_index$YEAR_MONTH))

for (year_month_i in year_month_set) {
  year_i = stringr::str_sub(year_month_i, 1, 4)
  month_i = as.integer(stringr::str_sub(year_month_i, 6, 7))
  year_month_label = paste0(year_i, "-", stringr::str_pad(month_i, width = 2, pad = "0"))

  message("Creating state-specific within-state county mobility files for ", year_month_label)

  month_days_i = as.integer(lubridate::days_in_month(as.Date(
    sprintf("%s-%02d-01", year_i, month_i)
  )))

  home_panel_month_files = find_output_files(
    primary_dir = home_panel_chunk_dir,
    pattern = paste0(
      "^advan_home_panel_us_",
      year_i,
      "_",
      stringr::str_pad(month_i, width = 2, pad = "0"),
      "_part[0-9]{3}\\.csv$"
    ),
    fallback_dir = advan_dir
  )

  if (length(home_panel_month_files) == 0) {
    stop(paste("No home panel chunks found for", year_month_i))
  }

  clean_start_time = Sys.time()
  county_number_devices_residing = map_dfr(
    home_panel_month_files,
    read_csv,
    col_types = cols(.default = col_character()),
    progress = FALSE
  ) %>%
    mutate(
      MONTH = as.integer(MONTH),
      NUMBER_DEVICES_RESIDING = replace_na(as.numeric(NUMBER_DEVICES_RESIDING), 0),
      STATE_FIPS = stringr::str_sub(CENSUS_BLOCK_GROUP, 1, 2),
      COUNTY_ORG = stringr::str_sub(CENSUS_BLOCK_GROUP, 1, 5)
    ) %>%
    group_by(YEAR, MONTH, STATE_FIPS, COUNTY_ORG) %>%
    summarise(
      NUMBER_DEVICES_RESIDING = sum(NUMBER_DEVICES_RESIDING, na.rm = TRUE),
      .groups = "drop"
    )
  log_elapsed_time(clean_start_time, paste("County home panel aggregation block for", year_month_i))

  month_device_files = device_file_index %>%
    dplyr::filter(YEAR_MONTH == year_month_i) %>%
    pull(PATH)

  clean_start_time = Sys.time()
  county_device_counts = map_dfr(month_device_files, function(path_i) {
    read_csv(
      path_i,
      col_types = cols(.default = col_character()),
      progress = FALSE
    ) %>%
      dplyr::filter(
        stringr::str_detect(CBG_ORG, "^[0-9]{12}$"),
        stringr::str_detect(CBG_DEST, "^[0-9]{12}$")
      ) %>%
      mutate(
        MONTH = as.integer(MONTH),
        DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
        STATE_ORG = stringr::str_sub(CBG_ORG, 1, 2),
        STATE_DEST = stringr::str_sub(CBG_DEST, 1, 2),
        COUNTY_ORG = stringr::str_sub(CBG_ORG, 1, 5),
        COUNTY_DEST = stringr::str_sub(CBG_DEST, 1, 5)
      ) %>%
      dplyr::filter(STATE_ORG == STATE_DEST) %>%
      group_by(YEAR, MONTH, STATE_FIPS = STATE_ORG, COUNTY_ORG, COUNTY_DEST) %>%
      summarise(
        DEVICE_COUNTS = sum(DEVICE_COUNTS, na.rm = TRUE),
        .groups = "drop"
      )
  }) %>%
    group_by(YEAR, MONTH, STATE_FIPS, COUNTY_ORG, COUNTY_DEST) %>%
    summarise(
      DEVICE_COUNTS = sum(DEVICE_COUNTS, na.rm = TRUE),
      .groups = "drop"
    )
  log_elapsed_time(clean_start_time, paste("County device counts cleaning block for", year_month_i))

  clean_start_time = Sys.time()
  county_mobility_matrix = county_device_counts %>%
    left_join(
      county_number_devices_residing,
      by = c("YEAR", "MONTH", "STATE_FIPS", "COUNTY_ORG")
    ) %>%
    left_join(state_lookup, by = "STATE_FIPS") %>%
    dplyr::filter(!is.na(STATE_DIR)) %>%
    mutate(
      DAYS_IN_MONTH = month_days_i,
      MOBILITY_MATRIX_VALUE = if_else(
        !is.na(NUMBER_DEVICES_RESIDING) & NUMBER_DEVICES_RESIDING > 0,
        DEVICE_COUNTS / (NUMBER_DEVICES_RESIDING * DAYS_IN_MONTH),
        0
      )
    ) %>%
    dplyr::select(
      YEAR,
      MONTH,
      STATE_NAME,
      STATE_DIR,
      STATE_ABBR,
      STATE_FIPS,
      COUNTY_ORG,
      COUNTY_DEST,
      DEVICE_COUNTS,
      NUMBER_DEVICES_RESIDING,
      DAYS_IN_MONTH,
      MOBILITY_MATRIX_VALUE
    ) %>%
    arrange(STATE_DIR, COUNTY_ORG, COUNTY_DEST)
  log_elapsed_time(clean_start_time, paste("County mobility matrix calculation block for", year_month_i))

  county_mobility_matrix %>%
    group_split(STATE_DIR, .keep = TRUE) %>%
    set_names(county_mobility_matrix %>% group_by(STATE_DIR) %>% group_keys() %>% pull()) %>%
    iwalk(function(state_chunk, state_dir_i) {
      if (is.na(state_dir_i) || nrow(state_chunk) == 0) {
        return(NULL)
      }

      write_csv(
        state_chunk,
        state_monthly_county_mobility_output_file(state_dir_i, year_month_label)
      )
    })
} # end loop over county month year files

#/////////////////////////////////////////////////
#### QUARTERLY STATE MOBILITY MATRIX OUTPUTS ####
#/////////////////////////////////////////////////

state_monthly_mobility_files = list.files(
  path = county_mobility_dir,
  pattern = paste0(
    "_",
    analysis_year,
    "-[0-9]{2}_within-state_county-mobility\\.csv$"
  ),
  full.names = TRUE
)

if (length(state_monthly_mobility_files) == 0) {
  stop(paste("No", analysis_year, "state monthly within-state county mobility files found in", county_mobility_dir))
}

for (state_dir_i in state_lookup$STATE_DIR) {
  state_start_time = Sys.time()
  state_files_i = state_monthly_mobility_files[
    startsWith(basename(state_monthly_mobility_files), paste0(state_dir_i, "_"))
  ]

  if (length(state_files_i) == 0) {
    next
  }

  message("Creating quarterly within-state county mobility outputs for ", state_dir_i)

  state_monthly_mobility = map_dfr(
    state_files_i,
    read_csv,
    col_types = cols(.default = col_character()),
    progress = FALSE
  )

  state_monthly_mobility = state_monthly_mobility %>%
    mutate(
      YEAR = as.integer(YEAR),
      MONTH = as.integer(MONTH),
      DEVICE_COUNTS = as.numeric(DEVICE_COUNTS),
      NUMBER_DEVICES_RESIDING = as.numeric(NUMBER_DEVICES_RESIDING),
      DAYS_IN_MONTH = as.integer(DAYS_IN_MONTH),
      MOBILITY_MATRIX_VALUE = as.numeric(MOBILITY_MATRIX_VALUE),
      QUARTER = as.character(lubridate::quarter(as.Date(
        sprintf("%s-%02d-01", YEAR, MONTH)
      )))
    )

  adult_county_population = read_state_adult_county_population(state_dir_i)

  monthly_state_flow = state_monthly_mobility %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, YEAR, MONTH, COUNTY_ORG) %>%
    summarise(
      adult_mobility_outflow = sum(MOBILITY_MATRIX_VALUE, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    left_join(adult_county_population, by = c("COUNTY_ORG" = "fips")) %>%
    mutate(
      MONTH_DATE = as.Date(sprintf("%s-%02d-01", YEAR, MONTH)),
      ESTIMATED_ADULT_DAILY_FLOW = adult_population * adult_mobility_outflow
    ) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, YEAR, MONTH, MONTH_DATE) %>%
    summarise(
      ESTIMATED_ADULT_DAILY_FLOW = sum(ESTIMATED_ADULT_DAILY_FLOW, na.rm = TRUE),
      COUNTIES_WITH_POPULATION = sum(!is.na(adult_population)),
      .groups = "drop"
    ) %>%
    arrange(MONTH_DATE)

  monthly_state_flow_fig = ggplot(
    monthly_state_flow,
    aes(x = MONTH_DATE, y = ESTIMATED_ADULT_DAILY_FLOW)
  ) +
    geom_line(color = "black", linewidth = 0.8) +
    geom_point(color = "#2C7FB8", size = 2) +
    scale_x_date(date_breaks = "1 month", date_labels = "%b") +
    scale_y_continuous(labels = scales::comma) +
    labs(
      x = paste0(analysis_year, " month"),
      y = "Estimated adult daily out-of-county flow",
      title = paste0(state_monthly_mobility$STATE_NAME[1], " monthly out-of-county mobility"),
      subtitle = "Adult county populations are used; children are assumed to follow the same destination pattern."
    ) +
    theme_bw()

  ggsave(
    state_monthly_flow_figure_file(state_dir_i, analysis_year),
    monthly_state_flow_fig,
    width = 10,
    height = 6,
    units = "in",
    bg = "white"
  )

  state_counties = sort(unique(c(
    state_monthly_mobility$COUNTY_ORG,
    state_monthly_mobility$COUNTY_DEST
  )))

  state_quarterly_mobility = state_monthly_mobility %>%
    mutate(
      # Keep the diagonal as its observed share of origin trips. The travel
      # model ignores same-county pairs, but retaining the diagonal prevents
      # off-diagonal destinations from being inflated to 100% of trips.
      TRIP_SHARE_DEVICE_COUNTS = replace_na(DEVICE_COUNTS, 0)
    ) %>%
    group_by(
      STATE_NAME,
      STATE_DIR,
      STATE_ABBR,
      STATE_FIPS,
      COUNTY_ORG,
      COUNTY_DEST,
      QUARTER
    ) %>%
    summarise(
      quarterly_device_counts = sum(TRIP_SHARE_DEVICE_COUNTS, na.rm = TRUE),
      mean_number_devices_residing = weighted.mean(
        NUMBER_DEVICES_RESIDING,
        w = DAYS_IN_MONTH,
        na.rm = TRUE
      ),
      .groups = "drop"
    ) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, QUARTER, COUNTY_ORG) %>%
    mutate(
      total_quarterly_origin_trips = sum(quarterly_device_counts, na.rm = TRUE),
      mean_mobility_matrix_value = if_else(
        total_quarterly_origin_trips > 0,
        quarterly_device_counts / total_quarterly_origin_trips,
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
    mutate(imputed = is.na(mean_mobility_matrix_value)) %>%
    replace_na(list(
      mean_mobility_matrix_value = 0,
      quarterly_device_counts = 0,
      total_quarterly_origin_trips = 0,
      mean_number_devices_residing = 0
    )) %>%
    arrange(STATE_DIR, COUNTY_ORG, COUNTY_DEST, QUARTER)

  write_csv(
    state_quarterly_mobility,
    state_data_output_file(
      state_dir_i,
      paste0(state_dir_i, "_quarterly-", analysis_year, "_mobility.csv")
    )
  )

  county_connection_ranking = state_quarterly_mobility %>%
    dplyr::filter(COUNTY_ORG != COUNTY_DEST) %>%
    group_by(STATE_NAME, STATE_DIR, STATE_ABBR, STATE_FIPS, QUARTER, COUNTY_ORG) %>%
    summarise(
      mobility_outflow = sum(mean_mobility_matrix_value, na.rm = TRUE),
      total_counties_connected = sum(mean_mobility_matrix_value > 0, na.rm = TRUE),
      mean_number_devices_residing = max(mean_number_devices_residing, na.rm = TRUE),
      tracked_device_outflow = round(mean_number_devices_residing * mobility_outflow, 0),
      .groups = "drop"
    ) %>%
    arrange(STATE_DIR, QUARTER, desc(tracked_device_outflow), desc(mobility_outflow))

  write_csv(
    county_connection_ranking,
    state_data_output_file(
      state_dir_i,
      paste0(state_dir_i, "_quarterly-", analysis_year, "_county-connection-ranking.csv")
    )
  )

  for (quarter_i in c("1", "2", "3", "4")) {
    quarter_chunk = state_quarterly_mobility %>%
      dplyr::filter(QUARTER == quarter_i)

    if (nrow(quarter_chunk) == 0) {
      next
    }

    matrix_df = quarter_chunk %>%
      dplyr::select(COUNTY_ORG, COUNTY_DEST, mean_mobility_matrix_value) %>%
      pivot_wider(
        names_from = COUNTY_DEST,
        values_from = mean_mobility_matrix_value,
        values_fill = 0
      ) %>%
      arrange(COUNTY_ORG) %>%
      dplyr::select(COUNTY_ORG, all_of(state_counties))

    quarter_matrix = as.matrix(matrix_df[, -1, drop = FALSE])

    write.table(
      quarter_matrix,
      state_data_output_file(
        state_dir_i,
        paste0(state_dir_i, "_Q", quarter_i, "-", analysis_year, "_mobility-matrix.csv")
      ),
      sep = ",",
      row.names = FALSE,
      col.names = FALSE
    )
  }

  log_elapsed_time(state_start_time, paste("Quarterly within-state county mobility output block for", state_dir_i))
}
