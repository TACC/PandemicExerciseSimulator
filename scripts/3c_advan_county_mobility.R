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
#'   ../data/MOBILITY/Advan/advan_device_home_areas_YYYY-MM-DD_BATCH.csv
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
device_home_areas_out_prefix = file.path(advan_dir, "advan_device_home_areas")

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

  if (file.exists(device_home_areas_out_file)) {
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

home_panel_out_prefix = file.path(advan_dir, "advan_home_panel_us")
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
    advan_dir,
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

old_home_panel_out_files = list.files(
  path = advan_dir,
  pattern = paste0(
    "^advan_home_panel_us_",
    analysis_year,
    "_[0-9]{2}_part[0-9]{3}\\.csv$"
  ),
  full.names = TRUE
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
    advan_dir,
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
      NUMBER_DEVICES_RESIDING = as.numeric(NUMBER_DEVICES_RESIDING)
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

#////////////////////////////////////////////////////////
#### COUNTY-LEVEL DAILY MOBILITY MATRIX, BATCHED BY YEAR/MONTH ####
#////////////////////////////////////////////////////////

#' Build a county mobility matrix output path
#'
#' @param year Integer or character four-digit analysis year, such as `2025`.
#' @param month Integer month number from 1 to 12.
#'
#' @return Character path for the county-level daily mobility matrix CSV file.
#'
#' @examples
#' county_mobility_matrix_output_file(2025, 1)
county_mobility_matrix_output_file = function(year, month) {
  file.path(
    advan_dir,
    paste0(
      "advan_home_panel_us_county-level_",
      year,
      "_",
      stringr::str_pad(month, width = 2, pad = "0"),
      ".csv"
    )
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

device_home_areas_clean_files = list.files(
  path = advan_dir,
  pattern = paste0(
    "^advan_device_home_areas_",
    analysis_year,
    "-[0-9]{2}-[0-9]{2}_[^_]+\\.csv$"
  ),
  full.names = TRUE
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
  county_mobility_matrix_out_file = county_mobility_matrix_output_file(year_i, month_i)

  if (file.exists(county_mobility_matrix_out_file)) {
    message("Skipping existing county-level daily mobility matrix file: ",
            basename(county_mobility_matrix_out_file))
    next
  }

  message("Creating county-level daily mobility matrix file for ", year_month_i)

  month_days_i = as.integer(lubridate::days_in_month(as.Date(
    sprintf("%s-%02d-01", year_i, month_i)
  )))

  home_panel_month_files = list.files(
    path = advan_dir,
    pattern = paste0(
      "^advan_home_panel_us_",
      year_i,
      "_",
      stringr::str_pad(month_i, width = 2, pad = "0"),
      "_part[0-9]{3}\\.csv$"
    ),
    full.names = TRUE
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
      NUMBER_DEVICES_RESIDING = as.numeric(NUMBER_DEVICES_RESIDING),
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
    mutate(
      DAYS_IN_MONTH = month_days_i,
      MOBILITY_MATRIX_VALUE = DEVICE_COUNTS / (NUMBER_DEVICES_RESIDING * DAYS_IN_MONTH)
    ) %>%
    arrange(STATE_FIPS, COUNTY_ORG, COUNTY_DEST)
  log_elapsed_time(clean_start_time, paste("County mobility matrix calculation block for", year_month_i))

  write_csv(
    county_mobility_matrix,
    county_mobility_matrix_out_file
  )
} # end loop over county month year files
