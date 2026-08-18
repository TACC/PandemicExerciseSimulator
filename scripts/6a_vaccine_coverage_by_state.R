#////////
#### Script Overview ####
#////////
#' Get the total people who will have 100% vaccine effectiveness against inf
#' by combining the vaccine coverage and inpatient effectiveness for H1N1
#' 
#' VC by state from:
#'  6mon - 17yr: https://data.cdc.gov/Child-Vaccinations/Weekly-Cumulative-Influenza-Vaccination-Coverage-b/vncy-2ds7/about_data 
#'  18yr - 65+ : https://data.cdc.gov/Flu-Vaccinations/Weekly-Influenza-Vaccination-Coverage-and-Intent-f/sw5n-wg2p/about_data   
#'  
#' H2N3 VE estimates 
#' Children from NVSN (inpatient) 
#' Adults age >=18 IVY (Inpatient) not available for 2025-26 as of Aug 8, 2026 using VISION (inpatient) for Influenza A
#' https://www.cdc.gov/flu-vaccines-work/php/effectiveness-studies/2025-2026.html
#'  
#' Parent dirs: POPULATION, VACCINATION
#////////
options(scipen=999) #  disable scientific notation

#////////
#### Define key parameter assumptions ####
#////////
pediatric_VE = get0("PEDIATRIC_VACCINE_EFFECTIVENESS", ifnotfound = 0.38) # 38 (13 to 55) from NVSN (inpatient) H3N2 specific
adult_VE = get0("ADULT_VACCINE_EFFECTIVENESS", ifnotfound = 0.30) # 30 (21 to 38) from VISION (inpatient) Influenza A
day0 = as.Date(get0("SIM_DAY_0", ifnotfound = "2025-10-01")) # day epidemic starts in simulation
acs_year_range = get0("ACS_YEAR_RANGE", ifnotfound = "2020-2024")

# Need pop by age to determine total doses as fraction of vaccine coverage and effectiveness
state_pop_by_age = read_csv(paste0("../data/POPULATION/all_US_county_pop_by_age_", acs_year_range, "ACS.csv")) %>%
  mutate(
    AgeGroup = case_when(age_group %in% c("0-4", "5-17") ~ "Pediatric",
                         age_group %in% c("18-49", "50-64", "65+") ~ "Adult",
                         TRUE ~ NA_character_
                         )) %>%
  group_by(STATE_NAME, AgeGroup) %>%
  summarise(total_pop = sum(pop), .groups = "drop") %>%
  rename(State = STATE_NAME)

#////////
#### Ped VC ####
#////////
ped_file = list.files(path = "../data/VACCINATION", pattern = "Children_6_Months-17_Years", full.names = T)
ped_flu_vc = 
  read_csv(ped_file) %>%
  dplyr::filter(Indicator_label == "Up-to-date") %>%
  dplyr::filter(influenza_season == "2025-2026") %>%
  dplyr::select(`Geographic Name`, Estimate, Current_Season_Week_Ending_Label) %>%
  transmute(
    State   = `Geographic Name`,
    VaxCov  = Estimate,
    WeekEnd = as.Date(Current_Season_Week_Ending_Label)  # already <date>
  ) %>%
  mutate(
    AgeGroup = "Pediatric",
    VE_Inpatient = pediatric_VE
    )

#////////
#### Adult VC ####
#////////
adult_file = list.files(path="../data/VACCINATION", pattern ="Among_Adults_18_Years_and_Older", full.names = T)
week_end_col <- c("Week_ending", "Current_Season_Week_Ending") # col name change from 2024-25 to 2025-26
adult_flu_vc = 
  read_csv(adult_file) %>%
  dplyr::filter(Influenza_Season == "2025-2026") %>%
  dplyr::filter(`Geographic Level` == "State") %>%
  dplyr::filter(indicator_label == "Up-to-date") %>%
  dplyr::select(`Geographic Name`, Estimates, dplyr::any_of(week_end_col)) %>%
  dplyr::rename_with(~ "WeekEndRaw", dplyr::any_of(week_end_col)) %>%
  transmute(
    State   = `Geographic Name`,
    VaxCov  = Estimates,
    WeekEnd = as.Date(strptime(WeekEndRaw, "%Y %b %d %I:%M:%S %p"))
  ) %>%
  arrange(State, WeekEnd) %>%
  mutate(
    AgeGroup = "Adult",
    VE_Inpatient = adult_VE
  )

#////////
#### Vax doses weekly ####
#////////
# Join Peds & Adults to get the total vaccines consumed per week
all_age_df = adult_flu_vc %>%
  bind_rows(ped_flu_vc) %>%
  mutate(VaxCov = VaxCov/100) %>%
  left_join(state_pop_by_age, by=c("State", "AgeGroup")) %>%
  rowwise() %>%
  mutate(TotalVax = VaxCov * total_pop,
         TotalFullProtect = round(VE_Inpatient * TotalVax, 0) ) %>%
  ungroup() %>%
  group_by(State, AgeGroup) %>%
  arrange(State, AgeGroup, WeekEnd, .by_group = T) %>%
  mutate(WeeklyNewFullProtect = TotalFullProtect - dplyr::lag(TotalFullProtect, default = 0)
         ) %>%
  ungroup()

write.csv(
  all_age_df,
  "../data/VACCINATION/all_US_weekly_vax_adult-ped.csv",
  row.names = FALSE, quote = FALSE
)

#////////
#### Convert dates to days ####
#////////
# Make weeks into integer days in simulation to release vaccines from stockpile
weekly_ts = all_age_df %>%
  group_by(State, WeekEnd) %>%
  summarise(TotalWeeklyNewFullProtect = sum(WeeklyNewFullProtect), .groups = "drop") %>%
  mutate(ReleaseDay = as.integer(WeekEnd - day0)) %>%
  group_by(State, ReleaseDay) %>%
  summarise(TotalWeeklyNewFullProtect = sum(TotalWeeklyNewFullProtect), .groups = "drop") %>%
  arrange(State, ReleaseDay) %>%
  dplyr::filter(TotalWeeklyNewFullProtect>0)

write.csv(
  weekly_ts,
  "../data/VACCINATION/all_US_weekly_vax_distribution.csv",
  row.names = FALSE, quote = FALSE
)

















  
