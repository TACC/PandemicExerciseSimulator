#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#' Get the total people who will have 100% vaccine effectiveness against inf
#' by combining the vaccine coverage and inpatient effectiveness for H1N1
#' 
#' VC by state from:
#'  https://data.cdc.gov/Vaccinations/Weekly-Cumulative-Influenza-Vaccination-Coverage-C/eudc-n39h/about_data
#'  https://data.cdc.gov/Flu-Vaccinations/Weekly-Influenza-Vaccination-Coverage-and-Intent-f/sw5n-wg2p/about_data 
#'  
#' H1N1 VE estimates from
#'  https://www.cdc.gov/flu-vaccines-work/php/effectiveness-studies/2023-2024.html
#'  
#' Parent dirs: POPULATION, VACCINATION
#////////////////////////////////////////////////////////////////////////////////////////////////////////////////

options(scipen=999) #  disable scientific notation

#/////////////////////////////////////////
#### Define key parameter assumptions ####
pediatric_VE = 0.51
adult_VE = 0.36
day0 = as.Date("2024-10-01") # day epidemic starts in simulation

# Need pop by age to determine total doses as fraction of vaccine coverage and effectiveness
state_pop_by_age = read_csv("../data/POPULATION/all_US_county_pop_by_age_2019-2023ACS.csv") %>%
  mutate(
    AgeGroup = case_when(age_group %in% c("0-4", "5-17") ~ "Pediatric",
                         age_group %in% c("18-49", "50-64", "65+") ~ "Adult",
                         TRUE ~ NA_character_
                         )) %>%
  group_by(STATE_NAME, AgeGroup) %>%
  summarise(total_pop = sum(pop), .groups = "drop") %>%
  rename(State = STATE_NAME)

#///////////////
#### Ped VC ####
ped_file = list.files(path = "../data/VACCINATION", pattern = "Children_6_Months-17_Years", full.names = T)
ped_flu_vc = 
  read_csv(ped_file) %>%
  dplyr::filter(Indicator_label == "Up-to-date") %>%
  dplyr::filter(influenza_season == "2024-2025") %>%
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

#/////////////////
#### Adult VC ####
adult_file = list.files(path="../data/VACCINATION", pattern ="Among_Adults_18_Years_and_Older", full.names = T)
adult_flu_vc = 
  read_csv(adult_file) %>%
  dplyr::filter(Influenza_Season == "2024-2025") %>%
  dplyr::filter(`Geographic Level` == "State") %>%
  dplyr::filter(indicator_label == "Up-to-date") %>%
  dplyr::select(`Geographic Name`, Estimates, Current_Season_Week_Ending) %>%
  # harmonize names + parse the week label string into Date
  transmute(
    State   = `Geographic Name`,
    VaxCov  = Estimates,
    WeekEnd = as.Date(strptime(Current_Season_Week_Ending, "%Y %b %d %I:%M:%S %p"))
  ) %>%
  arrange(State, WeekEnd) %>%
  mutate(
    AgeGroup = "Adult",
    VE_Inpatient = adult_VE
  ) 

#/////////////////////////
#### Vax doses weekly ####
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

#//////////////////////////////
#### Convert dates to days ####
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

















  


