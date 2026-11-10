#////////
#### Script Overview ####
#////////
#' Estimate state-specific counts of insured high-risk people for outpatient antiviral
#' stockpile scenarios.
#'
#' IMPORTANT MODELING ASSUMPTION:
#' We assume insurance status and influenza high-risk status are independent within each
#' state and model age group. Therefore:
#'
#'   insured_high_risk_population[state, age] =
#'     ACS_insured_population[state, age] * high_risk_fraction[state, age]
#'
#' This is a pragmatic first-pass estimate because the high-risk fractions are estimated
#' from BRFSS and NSCH, while insurance coverage is pulled from ACS PUMS using tidycensus.
#' A future refinement could estimate high-risk-and-insured jointly from BRFSS/NSCH if
#' the relevant insurance variables are harmonized into the survey design pipeline.
#'
#' Parent dirs: RISK_RATIOS
#////////
output_state_age_file <- "../data/RISK_RATIOS/state-age_insured-high-risk-antiviral-counts.csv"
output_state_file <- "../data/RISK_RATIOS/state_insured-high-risk-antiviral-counts.csv"

if (file.exists(output_state_age_file) && file.exists(output_state_file)) {
  message("Antiviral insured high-risk count files already exist; skipping 6b.")
} else {

library(tidyverse)
library(tidycensus)
library(tigris)
source("../data/private_input_data/api_keys.R")
options(tigris_use_cache = TRUE)

dir.create("../data/RISK_RATIOS/", showWarnings = FALSE, recursive = TRUE)
dir.create("../data/RISK_RATIOS/PUMS_CACHE/", showWarnings = FALSE, recursive = TRUE)

ACS_YEAR <- as.integer(get0("ACS_YEAR", ifnotfound = 2024L))
ACS_SURVEY <- "acs5"
MODEL_AGE_LEVELS <- c("0-4", "5-17", "18-49", "50-64", "65+")
PUMS_VARIABLES <- c("AGEP", "HICOV")
PUMS_CACHE_DIR <- "../data/RISK_RATIOS/PUMS_CACHE"

get_cached_pums <- function(state_abbrev) {
  cache_file <- file.path(
    PUMS_CACHE_DIR,
    paste0(
      "pums_",
      ACS_SURVEY,
      "_",
      ACS_YEAR,
      "_",
      state_abbrev,
      "_",
      paste(PUMS_VARIABLES, collapse = "-"),
      ".rds"
    )
  )
  
  if (file.exists(cache_file)) {
    message("Reading cached ACS PUMS insurance coverage for ", state_abbrev)
    return(readRDS(cache_file))
  }
  
  message("Pulling ACS PUMS insurance coverage for ", state_abbrev)
  pums_data <- tidycensus::get_pums(
    variables = PUMS_VARIABLES,
    state = state_abbrev,
    survey = ACS_SURVEY,
    year = ACS_YEAR
  )
  saveRDS(pums_data, cache_file)
  pums_data
}

state_crosswalk <- tidycensus::fips_codes %>%
  distinct(state_code, state_name, state) %>%
  filter(!(state_code %in% c("60", "66", "69", "72", "74", "78"))) %>%
  rename(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_ABB = state
  )

high_risk_by_age <- readr::read_csv(
  "../data/RISK_RATIOS/all_US_high-risk-ratios-detailed.csv",
  show_col_types = FALSE
) %>%
  transmute(
    STATE_FIPS,
    STATE_NAME,
    age_group = as.character(age_group),
    frac_high_risk
  )

acs_insured_by_age <- purrr::map_dfr(state_crosswalk$STATE_ABB, function(state_abbrev) {
  pums_data <- get_cached_pums(state_abbrev)
  
  pums_data %>%
    mutate(
      STATE_ABB = state_abbrev,
      age_group = case_when(
        AGEP <= 4 ~ "0-4",
        AGEP >= 5  & AGEP <= 17 ~ "5-17",
        AGEP >= 18 & AGEP <= 49 ~ "18-49",
        AGEP >= 50 & AGEP <= 64 ~ "50-64",
        AGEP >= 65 ~ "65+",
        TRUE ~ NA_character_
      ),
      insured = as.integer(HICOV) == 1
    ) %>%
    filter(!is.na(age_group)) %>%
    group_by(STATE_ABB, age_group) %>%
    summarise(
      acs_total_pop = sum(PWGTP, na.rm = TRUE),
      acs_insured_pop = sum(PWGTP[insured], na.rm = TRUE),
      acs_insured_frac = acs_insured_pop / acs_total_pop,
      .groups = "drop"
    )
})

insured_high_risk_by_state_age <- acs_insured_by_age %>%
  left_join(state_crosswalk, by = "STATE_ABB") %>%
  left_join(
    high_risk_by_age,
    by = c("STATE_FIPS", "STATE_NAME", "age_group")
  ) %>%
  mutate(
    insured_high_risk_pop = acs_insured_pop * frac_high_risk,
    age_group = factor(age_group, levels = MODEL_AGE_LEVELS)
  ) %>%
  arrange(STATE_NAME, age_group)

missing_high_risk <- insured_high_risk_by_state_age %>%
  filter(is.na(frac_high_risk))

if (nrow(missing_high_risk) > 0) {
  warning(
    "Missing high-risk estimates for some state-age rows; outputs will contain NA values. ",
    "Inspect missing_high_risk."
  )
}

insured_high_risk_by_state <- insured_high_risk_by_state_age %>%
  group_by(STATE_FIPS, STATE_NAME, STATE_ABB) %>%
  summarise(
    insured_high_risk_pop = round(sum(insured_high_risk_pop, na.rm = TRUE), 0),
    .groups = "drop"
  ) %>%
  arrange(STATE_NAME)

readr::write_csv(
  insured_high_risk_by_state_age,
  output_state_age_file
)

readr::write_csv(
  insured_high_risk_by_state,
  output_state_file
)

} # end skip if antiviral outputs already exist
