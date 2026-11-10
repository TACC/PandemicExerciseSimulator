#////////
#### Script Overview ####
#////////
#' Build recurring weekend NPI schedules from a single prototype intervention.
#'
#' The input template should contain one Weekend Mobility Decrease row. This
#' script expands it to every Saturday/Sunday in the configured simulation
#' window based on SIM_DAY_0 and SIMULATION_DAYS.
#////////
library(lubridate)
library(purrr)

SIM_DAY_0 <- as.Date(get0("SIM_DAY_0", ifnotfound = "2025-10-01"))
SIMULATION_DAYS <- as.integer(get0("SIMULATION_DAYS", ifnotfound = 300L))

first_saturday_day <- function(sim_day_0 = SIM_DAY_0) {
  sim_day_0 <- as.Date(sim_day_0)
  as.integer((6L - lubridate::wday(sim_day_0, week_start = 1L)) %% 7L)
}

make_weekend_mobility_npis <- function(prototype_npi,
                                       sim_day_0 = SIM_DAY_0,
                                       simulation_days = SIMULATION_DAYS) {
  if (length(prototype_npi) == 0) {
    return(list())
  }

  start_day <- first_saturday_day(sim_day_0)
  weekend_days <- seq(start_day, as.integer(simulation_days), by = 7L)

  purrr::map(weekend_days, function(day_i) {
    npi_i <- prototype_npi
    npi_i$day <- as.character(day_i)
    npi_i
  })
}
