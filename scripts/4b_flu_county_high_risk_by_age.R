#///////////////////////////////////////////////////////////////////////////////
#' Create county-level high risk ratios based on the CDC PLACES data
#' Chose comorbs in CDC PLACES that increase flu risk
#' Used BRFSS and NSCH survey state-age level risk ratios
#' 
#' Tested sqrt of raw prevalence sum to limit outliers and that seems reasonable
#' Could/Should test an SVI only weighting scheme but PLACES comorbs seem better
#'  because they already incorporate SVI among other datasets
#'  
#'  PLACES data 2025: https://data.cdc.gov/500-Cities-Places/PLACES-Local-Data-for-Better-Health-County-Data-20/swc5-untb/about_data
#'              2024: https://data.cdc.gov/500-Cities-Places/PLACES-Local-Data-for-Better-Health-County-Data-20/fu4u-a9bh/about_data
#'  SVI    data 2022: https://www.atsdr.cdc.gov/place-health/php/svi/svi-data-documentation-download.html
#'  
#'  Parent dirs: PLACES, SVI, RISK_RATIOS, POPULATION
#///////////////////////////////////////////////////////////////////////////////

#### Libraries ####
library(ggpmisc)
library(tidyverse)

dir.create("../figures/")

#### Data Sources ####
# CDC PLACES 2025 release based on 2022 (Tennessee) and 2023 data sets with 2019-2023 ACS
# Weirdly Pennsylvania and Kentucky are missing even in the online interactive dashboard 
#  => downloaded on Dec 5 release day so maybe an error that will be corrected???
# In BRFSS: Kentucky (21) and Pennsylvania (42) did not collect enough data for 2023 survey so required 2022 data...
places_file_path_2025 = list.files(path="../data/PLACES/", 
                              pattern="^PLACES__Local_Data_for_Better_Health,_County_Data,_2025_release",
                              full.names = T)
# Annoyingly 2024 and 2025 filenames differ by a comma so just copy paste the exact header instead
places_file_path_2024 = list.files(path="../data/PLACES/", 
                                   pattern="^PLACES__Local_Data_for_Better_Health,_County_Data_2024_release",
                                   full.names = T)
county_comorbs_2025 = 
  read_csv(places_file_path_2025) %>%
  dplyr::select(Year, LocationID, Measure, Data_Value_Type, Data_Value) %>%
  rename(fips=LocationID) %>%
  dplyr::filter(Data_Value_Type == "Age-adjusted prevalence") %>%
  dplyr::filter(fips != 59) # United States - FIPS 59 is being used for national level
county_comorbs_2024 = 
  read_csv(places_file_path_2024) %>%
  dplyr::select(Year, LocationID, Measure, Data_Value_Type, Data_Value) %>%
  rename(fips=LocationID) %>%
  dplyr::filter(Data_Value_Type == "Age-adjusted prevalence") %>%
  dplyr::filter(fips != 59) # United States - FIPS 59 is being used for national level

# These are the 2024 release variable names
comorb_values = c(
  "Chronic obstructive pulmonary disease among adults",
  "Diagnosed diabetes among adults",
  "Coronary heart disease among adults",
  "High blood pressure among adults", # 2021
  "High cholesterol among adults who have ever been screened", # 2021
  # CKD missing here
  # Excluding cancer bc it has skin cancer
  "Stroke among adults",
  "Current asthma among adults",
  "Obesity among adults"
)

# There's also one TX county (48301) missing data for 2025 download, so we'll just take the most recent that's not NA
# Some Florida counties appear to be missing high blood pressure & cholesterol from 2024 dataset (e.g. pre-2023 values)
county_comorbs = county_comorbs_2025 %>%
  bind_rows(county_comorbs_2024) %>%
  group_by(fips, Measure) %>%
  arrange(Year, .by_group = T) %>%
  # keep only years where we actually have data
  dplyr::filter(!is.na(Data_Value)) %>%
  # grab the latest year with non-missing data
  mutate(total_years_avail = n()) %>%
  slice_max(order_by = Year, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  dplyr::filter(Measure %in% comorb_values)

# Expect 3144 counties per measure
check_counts =
  county_comorbs %>%
  group_by(Measure) %>%
  summarise(
    n_non_missing = sum(!is.na(Data_Value)),
    ok = n_non_missing == 3144,
    .groups = "drop"
  )
if(sum(check_counts$ok)<8){
  print("A variable is missing county data - need to fix")
}

# 2019-2023 ACS
county_pop = read_csv("../data/POPULATION/all_US_county_pop_by_age_2019-2023ACS.csv")
state_age_pop = county_pop %>%
  group_by(STATE_NAME, age_group) %>%
  summarise(pop = sum(pop), .groups = "drop") 

# Risk ratios calculated by 
risk_ratios = read_csv("../data/RISK_RATIOS/all_US_high-risk-ratios-detailed.csv") %>%
  mutate(age_group = fct_relevel(age_group, c("0-4", "5-17", "18-49", "50-64", "65+")))

# 2022 SVI data
svi_county = read_csv("../data/SVI/SVI_2022_US_county.csv")

#### SVI by State Plot ####
svi_state = svi_county %>%
  group_by(STATE) %>%
  summarise(
    across(
      c(starts_with("RPL_THEME"), "EP_UNINSUR", "EP_POV150"), # RPL_THEME1, ..., RPL_THEMES
      list(
        mean   = ~mean(.x, na.rm = TRUE),
        median = ~median(.x, na.rm = TRUE),
        sd     = ~sd(.x, na.rm = TRUE),
        min    = ~min(.x, na.rm = TRUE),
        p10    = ~quantile(.x, 0.10, na.rm = TRUE),
        p90    = ~quantile(.x, 0.90, na.rm = TRUE),
        max    = ~max(.x, na.rm = TRUE)
      ),
      .names = "{.col}_{.fn}"
    ),
    .groups = "drop"
  ) %>%
  full_join(risk_ratios, by=c("STATE"="STATE_NAME"))

svi_risk_plt = 
  ggplot(svi_state,
         aes(x = RPL_THEMES_mean, y = frac_high_risk, label=STATE)) +
  geom_errorbar(aes(
      ymin = frac_high_risk_low,
      ymax = frac_high_risk_upp,
      color = age_group),
    width = 0, alpha = 0.4) +
  geom_point(aes(color = age_group), alpha = 0.5) +
  geom_smooth(method = lm, formula = y ~ x, se = TRUE, color="black") +
  labs(x="Mean SVI of Counties in State",
       y="Proportion State at least 1 High Risk Comorb")+
  facet_grid( ~ age_group, scale="free_y") +
  stat_poly_eq(
    formula = y ~ x,
    aes(label = after_stat(eq.label)),
    parse = TRUE, size = 4
  ) +
  theme_bw(15) +
  guides(color = "none")
ggsave("../figures/svi_risk_ratios_by_age_comparison.png",
       svi_risk_plt, 
       width=10, height=8, units="in", bg="white", dpi=900)

# interactive option
#plotly::ggplotly(svi_risk_plt)

#### County PLACES Burden ####
# County burden score based on PLACES data available
# Leaves 3,144 counties
county_comorb_burden = county_comorbs %>%
  dplyr::filter(Measure %in% comorb_values) %>%
  group_by(fips) %>%
  summarise(county_burden_raw_total_prev = sum(Data_Value)/100,
            .groups = "drop") %>%
  mutate(county_burden_sqrt_total_prev = sqrt(county_burden_raw_total_prev))

# There are 3,243 counties in the U.S. as of 2025, 
#  which includes 3,144 counties in the 50 states + DC and 
#  99 county-equivalents in U.S. territories
if(nrow(county_comorb_burden)==3144){
  print("Correct number of counties found: 3,144")
}else{
  print(paste("Counties missing, only", nrow(county_comorb_burden), "when 3,144 expected"))
}

# Plot county burden allocation comparison with sqrt dampening
burden_compare = ggplot(county_comorb_burden,
       aes(x=county_burden_raw_total_prev, y=county_burden_sqrt_total_prev))+
  geom_point()+
  theme_bw()
ggsave("../figures/raw_vs_sqrt_burden_comparison.png",
       burden_compare, 
       width=10, height=8, units="in", bg="white", dpi=900)

# Plot PLACES variables against SVI
# Melanoma/skin cancer is negatively associated bc typical of affluent people
# Without skin cancer for 2023 release we still see slight negative correlation
comorb_svi_df = county_comorbs %>%
  dplyr::filter(Measure %in% comorb_values) %>%
  left_join(svi_county %>%
              dplyr::select(STATE, FIPS, c(starts_with("RPL_THEME"), starts_with("SVI")) ),
            by = c("fips"="FIPS"))

svi_plt = ggplot(comorb_svi_df,
       aes(x = RPL_THEMES, y = Data_Value ))+
  geom_point(alpha=0.3)+
  labs(x="County SVI",
       y="% Pop with Comorb")+
  geom_smooth(method = lm)+
  facet_wrap(~Measure, scales="free_y")+
  theme_bw()
ggsave("../figures/places_comorbs_svi_comparison.png",
       svi_plt, 
       width=12, height=8, units="in", bg="white", dpi=900)

#### County Weighted Risk ####
county_risk_df = county_pop %>%
  left_join(svi_county %>%
              dplyr::select(STATE, FIPS, c(starts_with("RPL_THEMES")) ),
            by = c("fips"="FIPS", "STATE_NAME"="STATE")) %>%
  left_join(risk_ratios, by=c("STATE_NAME", "age_group", "STATE_FIPS")) %>%
  drop_na()  %>% # remove PR
  left_join(county_comorb_burden, by = "fips") %>%
  group_by(STATE_FIPS, age_group) %>%
  # Keeping extra cols of each step of analysis to validate the accuracy of these
  mutate(
    # population weights within state-age
    state_age_pop_sum =  sum(pop, na.rm = TRUE),
    pop_wt          = pop / state_age_pop_sum,
    # multiply raw burden by pop_wt
    #county_burden_total_prev_weight = county_burden_raw_total_prev * pop_wt,
    county_burden_total_prev_weight = county_burden_sqrt_total_prev * pop_wt,
    
    # sum to get pop weighted state-average burden
    mean_burden_state     = sum(county_burden_total_prev_weight, na.rm = TRUE),
    # relative burden weight r_i
    #burden_weight   = county_burden_raw_total_prev / mean_burden_state,
    burden_weight   = county_burden_sqrt_total_prev / mean_burden_state,
    
    # county-level high-risk probability
    frac_high_risk_cnty = frac_high_risk * burden_weight,
    frac_high_risk_cnty = pmin(pmax(frac_high_risk_cnty, 0), 1)
  ) %>%
  ungroup() %>%
  mutate(age_group = factor(age_group, levels=c("0-4", "5-17", "18-49", "50-64", "65+")))

write.csv(county_risk_df,
          "../data/RISK_RATIOS/all_US_county_high-risk-ratios-detailed.csv",
          row.names = F)

# Plot how spread out the risk ratios are by county to re-create mean of state
# There is a larger range for older age groups that have higher % high risk
risk_spread = ggplot(county_risk_df,
       aes(x=frac_high_risk, y=frac_high_risk_cnty, 
           group=age_group, color=age_group, label=STATE_NAME))+
  geom_point(alpha=0.3)+
  theme_bw()
ggsave("../figures/county_risk_by_age.png",
       risk_spread, 
       width=10, height=8, units="in", bg="white", dpi=900)

# interactive option
#plotly::ggplotly(risk_spread)


#### Write State County Risk Files ####
county_risk_spread = county_risk_df %>%
  dplyr::select(STATE_NAME, COUNTY_NAME, fips, age_group, frac_high_risk_cnty) %>%
  spread(age_group, frac_high_risk_cnty) # 3144 rows as expected

state_names = unique(county_risk_spread$STATE_NAME) # length(state_names) = 51
for(state in state_names){
  state_specific_df = county_risk_spread %>%
    dplyr::filter(STATE_NAME==state) %>%
    # first col expected to be "fips" in file
    dplyr::select(-STATE_NAME, -COUNTY_NAME)
  
  state_name_hypen = str_replace_all(state, " ", "-")
  state_dir_path = paste0("../data/", state_name_hypen, "/")
  dir.create(state_dir_path) # just in case these scripts are run out of order
  file_path = paste0(state_dir_path, "county_", state_name_hypen, "_high-risk-ratios-flu-only.csv")
  
  # write.csv was ignoring direction to ignore header
  write.table(state_specific_df, 
              file_path,
              sep = ",", row.names = FALSE, quote = FALSE)
} # end loop over states

#### SVI by County Plot ####
county_svi_plt = 
  ggplot(county_risk_df, # %>%
           #dplyr::filter(STATE_NAME=="Texas"),
       aes(x = RPL_THEMES, y = frac_high_risk_cnty)) + # # label for tooltip , label=STATE_NAME
  geom_point(aes(color=STATE_NAME), alpha = 0.5) + # color here keeps formulas in black at same height
  geom_smooth(method = lm, formula = y ~ x, se = TRUE, color="black") +
  facet_wrap(~ age_group, nrow=1) + # , scale="free_y"
  labs(x="US County Social Vulnerability Index",
       y="County Proportion High Risk")+
  stat_poly_eq(
    formula = y ~ x,
    aes(label = after_stat(eq.label)),
    parse = TRUE, size = 4
  ) +
  theme_bw(base_size=15)+
  theme(legend.position = "none")

# all the stratified looking lines for 0-4 are states
# default color scheme looks cray cray
ggsave("../figures/county_risk_by_age_svi_comparison.png",
       county_svi_plt, 
       width=10, height=8, units="in", bg="white", dpi=900)

# interactive option
#plotly::ggplotly(county_svi_plt)

#### US County Risk Map ####
source("../data/private_input_data/api_keys.R")

# County level boundaries
acs_county_geo = 
  tidycensus::get_acs(geography = "county", variables="B01001_001",
                      year = 2023, geometry=T) %>%
  tigris::shift_geometry() 

# State level boundaries
acs_state_geo = 
  tidycensus::get_acs(geography = "state", variables="B01001_001",
                      year = 2023, geometry=T) %>%
  tigris::shift_geometry() %>%
  dplyr::filter(NAME != "Puerto Rico")
  
county_risk_full = county_risk_df %>%
  left_join(acs_county_geo, by=c("fips"="GEOID")) 

age_groups = unique(county_risk_df$age_group)
for(i in 1:length(age_groups)){
  # County data with boundaries
  single_age_group = age_groups[i]
  county_risk_geo = county_risk_full %>%
    dplyr::filter(age_group==single_age_group)
  
  # Plot the map 
  county_risk_plot =
    ggplot(county_risk_geo) +
    geom_sf(aes(fill=frac_high_risk_cnty*100, geometry=geometry),  linewidth = 0.2, color="white") +
    geom_sf(data = acs_state_geo, aes(geometry=geometry), fill = NA, color = "black", linewidth = 0.2) +
    scale_fill_gradientn(
      colors = c("#f3e79b","#fac484","#f8a07e","#eb7f86","#ce6693","#a059a0","#5c53a5"),
      #c("#fbe6c5","#f5ba98","#ee8a82","#dc7176","#c8586c","#9c3f5d","#70284a"),
      name   = paste0("High Risk (%)\nAge ", single_age_group)#,
      #limits = c(0, 100),
      #oob = scales::squish   # optional: keeps values outside 0–100 from breaking the scale
    ) +
    theme_void(base_size = 25) +
    theme(
      legend.position = "right",
      strip.text = element_text(face = "bold")
    )
  
  ggsave(filename = paste0("../figures/map_county_high-risk_", single_age_group, ".png"),
         plot = county_risk_plot,
         bg="white", width=14, height=10, units="in", dpi=900)
} # end loop over age groups to plot US county risk maps







