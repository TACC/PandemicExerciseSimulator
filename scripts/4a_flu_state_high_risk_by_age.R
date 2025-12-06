#//////////////////////////////////////////////////////////////////////////////////////
#' Estimate state-specific proportion of each age group at 
#' high risk of severe influenza complications (hospitalization and death)

#' BRFSS data: https://www.cdc.gov/brfss/annual_data/annual_data.htm
#' You need 2023 and 2024 since Tennessee did not submit enough data for 2024 inclusion
#' Code Book:  HTML saved as PDF in data/metadata/BRFSS_LLCP_2023_CodebookReport.pdf

#' NSCH data: https://www.census.gov/programs-surveys/nsch/data/datasets.2024.html
#' Code Book: https://www.census.gov/data-tools/demo/uccb/nschdict

#' Flu high risk: https://www.cdc.gov/flu/highrisk/index.htm
#' Children high risk: https://www.cdc.gov/flu/highrisk/neurologic-pediatric.html
#' Including flu shot survey results for scenario modeling
#' 
#' Parent dirs: BRFSS, NSCH, RISK_RATIOS
#//////////////////////////////////////////////////////////////////////////////////////

#///////////////////
#### BRFSS VARS ####
#' _STATE   = state fips
#' _STSTR   = strata
#' _LLCPWT  = final weight assigned to each respondent
#' _PSU     = primary sampling unit, ID
#' _AGEG5YR = age reported in 5 year age categories
#' FLUSHOT7 = Adult flu shot/spray in last 12 months
#' ASTHMA3  = asthma ever
#'  with ASTHNOW = current asthma
#' CSRVTRT3 = current cancer treatment
#'  with CHCSCNC1 = ever skin cancer that is not melanoma?
#'  with CHCOCNC1 = ever melanoma or any other types of cancer?
#' CHCKDNY2 = ever had chronic kidney disease
#' CHCCOPD3 = ever had COPD
#' DIABETE4 = ever told have diabetes
#' CVDCRHD4 = ever had heart disease
#' _BMI5  = BIM severe obesity >=40
#' PREGNANT = current pregnant
#'  with SEXVAR  = female
#'  with
#' _SMOKER3 = current smoker calculated
#' CVDSTRK3 = ever had a stroke

#///////////////////
#### NSCH VARS ####
#' FIPSST        = state fips
#' STRATUM       = strata
#' FWC           = final weight assigned to each respondent
#' HHID          = ID
#' SC_AGE_YEARS  = age
#' AUTOIMMUNE    = ever autoimmune disorder
#' K2Q40A        = asthma ever
#'  with K2Q40B  = current asthma
#' BLOOD         = ever blood disorder
#' K2Q61A        = ever cerebral palsy
#' CYSTFIB       = ever cystic fibrosis
#' DIABETES      = diabetes ever 
#'  with DIABETES_CURR = current diabetes 
#' K2Q42A        = epilepsy ever 
#'  with K2Q42B  = current epilepsy
#' HEART         = heart condition ever
#'  with HEART_CURR = current heart condition
#' K2Q60B        = current intellectual disability
#' BMICLASS      = BMI percentile

#//////////////////
#### Libraries ####
# Load libraries
library(tidyverse)
library(srvyr)
dir.create("../data/RISK_RATIOS/")
dir.create("../figures/")

#///////////////////
#### BRFSS DATA ####
# Read .XPT file using haven
# If you wanted to use 2023 need 2022 as well
# Kentucky (21) and Pennsylvania (42) did not collect enough data for 2023 survey so need 2022
# brfss_2022 = haven::read_xpt("../data/BRFSS/LLCP2022.XPT") %>% # .XPT is the SAS transport file
#   dplyr::filter(`_STATE` %in% c(21, 42))

# This code uses 2023 and 2024 data because Tennessee (47) did not meet the requirements to submit data in 2024
brfss_2023 = haven::read_xpt("../data/BRFSS/LLCP2023.XPT") %>%
  dplyr::filter(`_STATE` %in% c(47))
brfss = haven::read_xpt("../data/BRFSS/LLCP2024.XPT") %>% # .XPT is the SAS transport file
  bind_rows(brfss_2023) %>%
  dplyr::filter(`_STATE` < 60) # Remove territories

#//////////////////
#### NSCH DATA ####
nsch = haven::read_sas("../data/NSCH/nsch_2024e_topical.sas7bdat")  

#////////////////////////
#### BRFSS HIGH RISK ####
brfss_high_risk_df = brfss %>%
  mutate(`_STATE`= str_pad(as.character(`_STATE`), 2, "left", "0")) %>%
  transmute(
    STATE_FIPS   = `_STATE`,
    AGE_5YR_CAT  = `_AGEG5YR`,
    weight       = `_LLCPWT`,
    PSU          = `_PSU`,
    STRATA       = `_STSTR`,
    # strata unique within states and not between so need to add prefix
    STRATA_STATE = interaction(STATE_FIPS, STRATA, drop = TRUE),
    age_group = case_when(
      AGE_5YR_CAT %in% c(1, 2, 3, 4, 5, 6)   ~ "18-49",
      AGE_5YR_CAT %in% c(7, 8, 9)            ~ "50-64",
      AGE_5YR_CAT %in% c(10, 11, 12, 13, 14) ~ "65+",
      AGE_5YR_CAT == 14 ~ NA_character_,  # Don't know / Refused / Missing
      TRUE ~ NA_character_
    ),
    flu_shot = dplyr::case_when(
      FLUSHOT7 == 1 ~ 1, 
      FLUSHOT7 == 2 ~ 0,
      FLUSHOT7 %in% c(7,9) ~ NA_integer_,
      TRUE ~ NA_integer_),
    asthma = dplyr::case_when(
      ASTHMA3 == 1 & ASTHNOW == 1 ~ 1,   # ever had AND still have asthma
      ASTHMA3 == 2                ~ 0,   # never had asthma
      ASTHMA3 == 1 & ASTHNOW == 2 ~ 0,   # had asthma, but not currently
      TRUE ~ NA_integer_),               # refused / DK / missing
    cancer = dplyr::case_when( # CURRENT treatment for non-skin cancers only
      CHCOCNC1 == 1 & CSRVTRT3 == 1 ~ 1, # Currently receiving treatment for non-skin cancer
      CHCOCNC1 == 1 & CSRVTRT3 %in% c(2, 3, 4, 5) ~ 0, # Ever non-skin cancer but NOT currently treated
      CHCOCNC1 == 2 & CHCSCNC1 == 2 ~ 0, # No melanoma/other cancer AND no skin cancer
      CHCSCNC1 == 1 & CHCOCNC1 != 1 ~ 0, # Skin cancer only (CHCSCNC1 == 1, CHCOCNC1 != 1)
      TRUE ~ NA_integer_),
    ckd = dplyr::case_when(
      CHCKDNY2 == 1 ~ 1,
      CHCKDNY2 == 2 ~ 0,
      CHCKDNY2 %in% c(7, 9) ~ NA_integer_,
      TRUE ~ NA_integer_),
    copd = dplyr::case_when(
      CHCCOPD3 == 1 ~ 1,
      CHCCOPD3 == 2 ~ 0,
      CHCCOPD3 %in% c(7, 9) ~ NA_integer_,
      TRUE ~ NA_integer_),
    diab = dplyr::case_when(
      DIABETE4 == 1 ~ 1,            # Yes = true chronic diabetes
      DIABETE4 %in% c(2, 3, 4) ~ 0, # gestational, no, or pre-diabetes = NOT high risk
      DIABETE4 %in% c(7, 9) ~ NA_integer_,
      TRUE ~ NA_integer_),
    heart = dplyr::case_when(
      CVDCRHD4 == 1 ~ 1,
      CVDCRHD4 == 2 ~ 0,
      CVDCRHD4 %in% c(7, 9) ~ NA_integer_,
      TRUE ~ NA_integer_),
    obese = case_when( # CDC considers only people with a body mass index (BMI) of 40 kg/m2 or higher
      `_BMI5` >= 4000 & `_BMI5` < 9999 ~ 1,   # BMI ≥ 40
      `_BMI5` < 4000  ~ 0,                    # BMI < 40
      TRUE ~ NA_integer_), # all DK/refused/missing
    preg = case_when( # female, 18-49, and currently pregnant
      `_SEX` == 2 & `_AGEG5YR` %in% 1:6 & PREGNANT == 1 ~ 1,
      `_SEX` == 2 & `_AGEG5YR` %in% 1:6 & PREGNANT == 2 ~ 0,
      TRUE ~ NA_integer_),
    smoke = dplyr::case_when(
      `_SMOKER3` %in% c(1, 2) ~ 1,   # current smoker
      `_SMOKER3` %in% c(3, 4) ~ 0,   # former or never smoker
      TRUE ~ NA_integer_),           # DK/refused/missing
    stroke = dplyr::case_when(
      CVDSTRK3 == 1 ~ 1,
      CVDSTRK3 == 2 ~ 0,
      CVDSTRK3 %in% c(7, 9) ~ NA_integer_,
      TRUE ~ NA_integer_)
  ) %>%
  mutate(
    any_known = if_any(c(asthma, cancer, copd, ckd, heart,
                         obese, smoke, diab, preg, stroke), ~ !is.na(.x)),
    any_yes   = if_any(c(asthma, cancer, copd, ckd, heart,
                         obese, smoke, diab, preg, stroke), ~ .x == 1L),
    high_risk = case_when(
      any_yes ~ 1,
      !any_known ~ NA_integer_,   # all comorbidities responses missing
      TRUE ~ 0                    # at least one known and none are "yes"
    )
  ) %>%
  dplyr::filter(!(STATE_FIPS %in% c("66", "78", "72") )) # remove Guam, Puerto Rico, Virgin Islands if present

#///////////////////////
#### NSCH HIGH RISK ####
nsch_high_risk_df = nsch %>%
  mutate(FIPSST  = str_pad(as.character(FIPSST), 2, "left", "0")) %>%
  transmute(
    STATE_FIPS   = FIPSST,
    weight       = FWC,
    PSU          = HHID,
    STRATA       = STRATUM,
    STRATA_STATE = interaction(STATE_FIPS, STRATA, drop = TRUE),
    age_group = case_when(
      SC_AGE_YEARS %in% c(0, 1, 2, 3, 4)      ~ "0-4",
      SC_AGE_YEARS %in% c( 5,  6,  7,  8,  9,
                          10, 11, 12, 13, 14,
                          15, 16, 17)         ~ "5-17",
      TRUE ~ NA_character_
    ),
    autoimm = dplyr::case_when( # only autoimmune ever available for 2016-2023
      AUTOIMMUNE == 1 ~ 1,
      AUTOIMMUNE == 2 ~ 0,
      TRUE ~ NA_integer_),
    asthma = dplyr::case_when(
      K2Q40A == 1 & K2Q40B == 1 ~ 1, # ever asthma AND currently asthma
      K2Q40A == 1 & K2Q40B == 2 ~ 0, # ever asthma but NOT current
      K2Q40A == 2 ~ 0,               # never asthma
      TRUE ~ NA_integer_),
    blood = dplyr::case_when( # only blood ever available for 2016-2023
      BLOOD == 1 ~ 1,
      BLOOD == 2 ~ 0,
      TRUE ~ NA_integer_),
    cerpal = dplyr::case_when( # only cerebral palsy ever available for 2016-2023
      K2Q61A == 1 ~ 1,
      K2Q61A == 2 ~ 0,
      TRUE ~ NA_integer_),
    cystfib = dplyr::case_when( # only cystic fibrosis ever available for 2016-2023
      CYSTFIB == 1 ~ 1,
      CYSTFIB == 2 ~ 0,
      TRUE ~ NA_integer_),
    diab = dplyr::case_when( # Only T2D available for 2016-2023
      DIABETES == 1 & DIABETES_CURR == 1 ~ 1, # ever AND current
      DIABETES == 1 & DIABETES_CURR == 2 ~ 0, # ever but NOT current
      DIABETES == 2 ~ 0,                      # never
      TRUE ~ NA_integer_),
    epilep = dplyr::case_when(
      K2Q42A == 1 & K2Q42B == 1 ~ 1, # ever epilepsy AND currently epilepsy
      K2Q42A == 1 & K2Q42B == 2 ~ 0, # ever epilepsy but NOT current
      K2Q42A == 2 ~ 0,               # never epilepsy
      TRUE ~ NA_integer_),
    heart = dplyr::case_when(
      HEART == 1 & HEART_CURR == 1 ~ 1, # ever AND current
      HEART == 1 & HEART_CURR == 2 ~ 0, # ever but NOT current
      HEART == 2 ~ 0,                   # never
      TRUE ~ NA_integer_),
    intell = dplyr::case_when(
      K2Q60A == 1 & K2Q60B == 1 ~ 1, # ever AND current
      K2Q60A == 1 & K2Q60B == 2 ~ 0, # ever but NOT current
      K2Q60A == 2 ~ 0,               # never
      TRUE ~ NA_integer_),
    obese = dplyr::case_when(
      BMICLASS %in% c(4) ~ 1, # BMI ≥95th percentile
      BMICLASS %in% c(1, 2, 3) ~ 0,
      TRUE ~ NA_integer_)
  ) %>%
  mutate(
    any_known = if_any(c(asthma, cystfib, heart, obese, diab, 
                         blood, cerpal, epilep, autoimm, intell), ~ !is.na(.x)),
    any_yes   = if_any(c(asthma, cystfib, heart, obese, diab, 
                         blood, cerpal, epilep, autoimm, intell), ~ .x == 1),
    high_risk = case_when(
      any_yes ~ 1,
      !any_known ~ NA_integer_,   # all comorbidities responses missing
      TRUE ~ 0                    # at least one known and none are "yes"
    )
  ) %>%
  dplyr::filter(!(STATE_FIPS %in% c("66", "78", "72") )) # remove Guam, Puerto Rico, Virgin Islands if present

#///////////////////////
#### DESIGN SURVEYS ####
options(survey.lonely.psu = "certainty") # treat single PSU strata as certainty

brfss_design_survey = brfss_high_risk_df %>%
  dplyr::select(PSU, STRATA_STATE, weight, STATE_FIPS, age_group, high_risk) %>%
  drop_na() %>%
  srvyr::as_survey_design(
    ids     = PSU,
    strata  = STRATA_STATE,
    weights = weight,
    nest    = TRUE
  ) %>%
  ungroup()

# Takes a little while to run
brfss_age_results = brfss_design_survey %>%
  group_by(STATE_FIPS, age_group) %>%
  summarise(
    frac_high_risk = srvyr::survey_mean(high_risk == 1, vartype = "ci", na.rm = TRUE),
    n_unw = srvyr::unweighted(n()) ) %>%
  ungroup()

nsch_design_survey = nsch_high_risk_df %>%
  dplyr::select(PSU, STRATA_STATE, weight, STATE_FIPS, age_group, high_risk) %>%
  drop_na() %>%
  srvyr::as_survey_design(
    ids     = PSU,
    strata  = STRATA_STATE,
    weights = weight,
    nest    = TRUE
  ) %>%
  ungroup()
nsch_age_results = nsch_design_survey %>%
  group_by(STATE_FIPS, age_group) %>%
  summarise(
    frac_high_risk = srvyr::survey_mean(high_risk == 1, vartype = "ci", na.rm = TRUE),
    n_unw = srvyr::unweighted(n()) ) %>%
  ungroup()

#////////////////////
#### ROWBIND DFS ####
state_names_df = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%  # state is USPS abbrev
  rename(STATE_FIPS = state_code,
         STATE_NAME = state_name) %>%
  dplyr::select(STATE_NAME, STATE_FIPS) %>%
  distinct()

all_age_df = brfss_age_results %>%
  bind_rows(nsch_age_results) %>%
  left_join(state_names_df, by="STATE_FIPS") %>%
  mutate(age_group = factor(age_group),
         age_group = fct_relevel(age_group, c("0-4", "5-17", "18-49", "50-64", "65+")) ) %>%
  dplyr::select(STATE_NAME, STATE_FIPS, everything())

length(unique(all_age_df$STATE_NAME)) # 51 as expected

file_path_all = "../data/RISK_RATIOS/all_US_high-risk-ratios-detailed.csv"
write.csv(all_age_df,
          file_path_all,
          row.names = FALSE, quote = FALSE)

#///////////////////////////////////
#### WRITE STATE SPECIFIC FILES ####
states = unique(all_age_df$STATE_NAME)
for(state in states){
  state_name_hypen = str_replace_all(state, " ", "-")
  state_age_df = all_age_df %>%
    dplyr::filter(STATE_NAME == state) %>%
    arrange(age_group)

  # Redundant as this can be taken from the parent file and not used by model directly
  # file_path_detailed = paste0("../data/", state_name_hypen, "/state_", state_name_hypen, "_high-risk-ratios-flu-detailed.csv")
  # write.csv(state_age_df,
  #           file_path_detailed,
  #           row.names = FALSE, quote = FALSE)

  file_path_only = paste0("../data/", state_name_hypen, "/state_", state_name_hypen, "_high-risk-ratios-flu-only.csv")
  write.table(state_age_df %>%
                dplyr::select(frac_high_risk),
              file_path_only,
              sep = ",", col.names = FALSE,  row.names = FALSE, quote = FALSE)
} # end loop over states

#////////////////////////
#### COMORB BREAKOUT ####
brfss_comorb_vars = c(
  "asthma", "cancer", "copd", "ckd", "heart",
  "obese", "smoke", "diab", "preg", "stroke")
brfss_comorb_breakout = brfss_high_risk_df %>% # Takes quite awhile to run
  # reshape to long: one row per person × condition
  pivot_longer(
    cols      = all_of(brfss_comorb_vars),
    names_to  = "condition",
    values_to = "value"
  ) %>%
  # now define the survey design on the long data
  as_survey_design(
    ids     = PSU,
    strata  = STRATA_STATE,
    weights = weight,
    nest    = TRUE
  ) %>%
  group_by(STATE_FIPS, age_group, condition) %>%
  summarise(
    prev      = survey_mean(value == 1, vartype = "ci", na.rm = TRUE),
    # FIXED: correctly count *non-missing* observations
    n_unw = unweighted(sum(!is.na(value))),
    .groups   = "drop"
  ) %>%
  mutate(
    prev_low = pmax(prev_low, 0),
    prev_upp = pmin(prev_upp, 1),
    reliability = case_when(
      n_unw < 30 ~ "suppress",
      n_unw < 60 ~ "unstable",
      TRUE       ~ "ok"
    )
  )

file_path_brfss_comorb = "../data/RISK_RATIOS/BRFSS-comorb_high-risk-ratios-detailed.csv"
write.csv(brfss_comorb_breakout,
          file_path_brfss_comorb,
          row.names = FALSE, quote = FALSE)

nsch_comorb_vars = c(
  "asthma", "cystfib", "heart", "obese", "diab",
  "blood", "cerpal", "epilep", "autoimm", "intell")
nsch_comorb_breakout = nsch_high_risk_df %>%
  # reshape: one row per child × condition
  pivot_longer(
    cols      = all_of(nsch_comorb_vars),
    names_to  = "condition",
    values_to = "value"
  ) %>%
  # survey design with PSUs, strata, and weights
  as_survey_design(
    ids     = PSU,
    strata  = STRATA_STATE,
    weights = weight,
    nest    = TRUE
  ) %>%
  # weighted estimates by state × age × condition
  group_by(STATE_FIPS, age_group, condition) %>%
  summarise(
    prev      = survey_mean(value == 1, vartype = "ci", na.rm = TRUE),
    # FIXED: correctly count *non-missing* observations
    n_unw = unweighted(sum(!is.na(value))),
    .groups   = "drop"
  ) %>%
  mutate(
    prev_low = pmax(prev_low, 0),
    prev_upp = pmin(prev_upp, 1),
    reliability = case_when(
      n_unw < 30 ~ "suppress",
      n_unw < 60 ~ "unstable",
      TRUE       ~ "ok"
    )
  )

file_path_nsch_comorb = "../data/RISK_RATIOS/NSCH-comorb_high-risk-ratios-detailed.csv"
write.csv(nsch_comorb_breakout,
          file_path_nsch_comorb,
          row.names = FALSE, quote = FALSE)


#### BRFSS HEAT MAP ####
state_crosswalk = tidycensus::fips_codes %>%
  dplyr::select(state_code, state_name, state) %>%       # state = abbreviation
  distinct() %>%
  rename(
    STATE_FIPS = state_code,
    STATE_NAME = state_name,
    STATE_ABB  = state
  ) %>%
  mutate(
    STATE_ABB = factor(STATE_ABB, levels = rev(sort(unique(STATE_ABB)))),
    STATE_NAME = factor(STATE_NAME, levels = rev(sort(unique(STATE_NAME))))
  )

brfss_state_comorb_mix = brfss_comorb_breakout %>%
  group_by(STATE_FIPS, age_group) %>%
  mutate(total = sum(prev, na.rm = TRUE),
         weight = prev / total) %>%
  ungroup() %>%
  left_join(state_crosswalk, by="STATE_FIPS") %>%
  mutate(
    label_weight = scales::percent(weight, accuracy = 0.1),
    text_color_weight = if_else(weight > 0.2, "white", "black"),
    label_prev = round(prev, 2),
    text_color_prev = if_else(prev > 0.2, "#FFF", "#000000")
  )

brfss_comorb_heatmap = 
  ggplot(brfss_state_comorb_mix,
         aes(x = condition, y = STATE_NAME, fill = prev*100)) +
  geom_tile(color = "white") +
  geom_text(aes(label = label_prev, color = text_color_prev), size = 3) +
  scale_color_identity() + 
  facet_wrap(~ age_group, scales = "free_y") +
  scale_fill_gradientn(
    colors = c("#f3e79b","#fac484","#f8a07e","#eb7f86","#ce6693","#a059a0","#5c53a5"),
    #colors = c("#798234","#a3ad62","#d0d3a2","#fdfbe4","#f0c6c3","#df91a3","#d46780"),
    name   = "Prevalence (%)") +
  labs(x = "Comorbidity", y="") +
  theme_bw(base_size = 14) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid = element_blank(),
    strip.background = element_rect(fill = "grey95"),
    strip.text = element_text(face = "bold"),
    legend.position = "bottom")
ggsave(filename = "../figures/BRFSS_state-age_comorb-prev.png",
       plot = brfss_comorb_heatmap,
       bg="white", width=16, height=12, units="in", dpi=900)


#### NSCH HEAT MAP ####
nsch_state_comorb_mix = nsch_comorb_breakout %>%
  group_by(STATE_FIPS, age_group) %>%
  mutate(total = sum(prev, na.rm = TRUE),
         weight = prev / total) %>%
  ungroup() %>%
  left_join(state_crosswalk, by="STATE_FIPS") %>%
  mutate(
    label_weight = scales::percent(weight, accuracy = 0.1),
    text_color_weight = if_else(weight > 0.15, "white", "black"),
    label_prev = round(prev, 2),
    text_color_prev = if_else(prev > 0.15, "#FFF", "#000000")
  )

nsch_comorb_heatmap =
  ggplot(nsch_state_comorb_mix,
         aes(x = condition, y = STATE_NAME, fill = prev*100)) +
  geom_tile(color = "white") +
  geom_text(aes(label = label_prev, color = text_color_prev), size = 3) +
  scale_color_identity() + 
  facet_wrap(~ age_group, scales = "free_y") +
  scale_fill_gradientn( # color palettes from CARTO Colors
    colors = c("#f3e79b","#fac484","#f8a07e","#eb7f86","#ce6693","#a059a0","#5c53a5"),
    #colors = c("#798234","#a3ad62","#d0d3a2","#fdfbe4","#f0c6c3","#df91a3","#d46780"),
    name   = "Prevalence (%)") +
  labs(x = "Comorbidity", y="") +
  theme_bw(base_size = 14) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    panel.grid = element_blank(),
    strip.background = element_rect(fill = "grey95"),
    strip.text = element_text(face = "bold"),
    legend.position = "bottom")
ggsave(filename = "../figures/NSCH_state-age_comorb-prev.png",
       plot = nsch_comorb_heatmap,
       bg="white", width=14, height=12, units="in", dpi=900)


