#///////////////////////////////////////////////////////////////////////
#' Create within state only county mobility flow patterns
#'  accounting for Alaska and Connecticut county changes after pandemic
#' Using proportion of the population flowing out of county
#' Almost all county outflows greater than the ACS population estimate
#' 
#' Mobility data from: https://github.com/GeoDS/COVID19USFlows
#' 
#' Parent dir: MOBILITY
#///////////////////////////////////////////////////////////////////////

library(tidyverse)
source("../data/private_input_data/api_keys.R")

#////////////////////
#### CENSUS DATA ####
# Alaska and Connecticut crosswalk made by "3a_ct_ak_crosswalks.r"
ak_ct_crosswalk = read_csv("../data/MOBILITY/ak_ct_crosswalk.csv") %>%
  dplyr::select(OLD_FIPS, NEW_FIPS, afact)

# 2019-2023 ACS that has the new FIPS for CT and AK
# Pulling new because we don't need age group stratification 
acs_county_geo_2023 = 
  tidycensus::get_acs(geography = "county", variables="B01001_001",
                      year = 2023, geometry=F) %>%
  dplyr::select(-moe, -variable, -NAME) %>%
  rename(POP_ACS2023 = estimate)

# All mobility files, repo cloned from GitHub 
files_2019 = list.files(
  path = "../../COVID19USFlows-DailyFlows/daily_flows/county2county",
  pattern = "^daily_county2county_2019_.*",
  full.names = TRUE
) # 365 files as expected

#### Create output dirs ####
mob_output_dir = "../data/MOBILITY/" # comes with data dir
dir.create(paste0(mob_output_dir, "within-state_county-mobility"))
state_out_dir = paste0(mob_output_dir, "state_2019_timeseries")
dir.create(state_out_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(paste0(mob_output_dir,"max-norm_within-state_county-mobility"))
fig_dir = "../figures/"; dir.create(fig_dir)

#//////////////////////////////////////////
#### TRANSLATE DAILY FILES TO 2023 ACS ####
us_flow_file = paste0(mob_output_dir, "US_flow_diff_timeseries.csv")
if(file.exists(us_flow_file)){
  # Difference in daily mobility flow patterns from 2019 (pre-pandemic)
  flow_diff_df = read_csv(us_flow_file)
  print("2019 translated to 2023+ geometries already exist")
}else{
  # Loop over all the days of 2019 to create proportion of pop traveling to each county
  problem_fips = unique(ak_ct_crosswalk$OLD_FIPS) # FIPS to change
  flow_diff_df = data.frame() # initialize data frame for flow diff
  for(i in 1:length(files_2019)){
    # Open mobility network file for specific day
    us_mobility = read_csv(files_2019[i]) %>% # i=34
      # filter pairs to be within the same state only
      mutate(state_o = as.character(str_sub(geoid_o, 1, 2)),
             state_d = as.character(str_sub(geoid_d, 1, 2))
      ) %>%
      dplyr::filter(state_o == state_d) %>%
      dplyr::select(date, geoid_o, geoid_d, pop_flows)
    
    # Get date of mobility network
    mob_date = us_mobility$date[1]
    
    # Only convert the Alaska and Connecticut FIPS & flows with pop allocation factor
    mob_to_keep = us_mobility %>%
      dplyr::filter(!(geoid_o %in% problem_fips | geoid_d %in% problem_fips))
    mob_to_change = us_mobility %>%
      dplyr::filter(geoid_o %in% problem_fips | geoid_d %in% problem_fips)
    
    mob_converted = mob_to_change %>%
      # expand ORIGIN
      left_join(
        ak_ct_crosswalk %>%
          rename(
            geoid_o      = OLD_FIPS,
            geoid_o_new  = NEW_FIPS,
            afact_o      = afact
          ),
        by = "geoid_o", relationship = "many-to-many"
      ) %>%
      mutate(
        # if origin didn't need changing, keep original and afact_o = 1
        geoid_o_new = if_else(is.na(geoid_o_new), geoid_o, geoid_o_new),
        afact_o     = if_else(is.na(afact_o), 1.0, afact_o)
      ) %>%
      # expand DESTINATION
      left_join(
        ak_ct_crosswalk %>%
          rename(
            geoid_d      = OLD_FIPS,
            geoid_d_new  = NEW_FIPS,
            afact_d      = afact
          ),
        by = "geoid_d", relationship = "many-to-many"
      ) %>%
      mutate(
        # if dest didn't need changing, keep original and afact_d = 1
        geoid_d_new = if_else(is.na(geoid_d_new), geoid_d, geoid_d_new),
        afact_d     = if_else(is.na(afact_d), 1.0, afact_d),
        # allocate flows
        pop_flows_new   = pop_flows * afact_o * afact_d # 
      ) %>%
      group_by(date, geoid_o_new, geoid_d_new) %>%
      summarise(pop_flows = floor(sum(pop_flows_new)), .groups = "drop") %>% # round , 0)
      rename(
        geoid_o = geoid_o_new,
        geoid_d = geoid_d_new
      )
    
    # Re-join to get full US df
    total_mob_df = mob_to_keep %>%
      bind_rows(mob_converted) %>%
      group_by(geoid_o) %>%
      mutate(total_pop_flow = sum(pop_flows)) %>%
      ungroup() %>%
      # Convert to proportion of pop traveling based on population or total outflow
      left_join(acs_county_geo_2023, by=c("geoid_o" = "GEOID")) %>%
      mutate(flow_greater_than_pop = ifelse(total_pop_flow > estimate, T, F) ) %>%
      rowwise() %>%
      mutate(prop_flow = ifelse(flow_greater_than_pop, pop_flows/total_pop_flow, pop_flows/estimate)) %>%
      ungroup() 
    
    write.csv(
      total_mob_df,
      paste0(mob_output_dir, "within-state_county-mobility/within-state_county-mobility_", mob_date, ".csv"),
      row.names = F
    )
    
    # Get the US difference in pop due to rounding errors from CT and AK
    df = data.frame(
      date = mob_date,
      prev_flow_total = sum(us_mobility$pop_flows),
      new_flow_total  = sum(total_mob_df$pop_flows)
    )
    flow_diff_df = bind_rows(flow_diff_df, df)
  } #for loop over all days of year
  
  write.csv(
    flow_diff_df,
    paste0(mob_output_dir, "US_flow_diff_timeseries.csv"),
    row.names = F
  )
} # end if files already exist

#//////////////////////
#### NORM STATE TS ####
#//////////////////////
date_set = seq(as.Date("2019-01-01"), as.Date("2019-12-31"))
if(!file.exists(paste0(mob_output_dir, "county_max_pop_flow_2019.csv"))){
  fips_specific_ts = data.frame()
  for(i in 1:length(date_set)){
    fips_subset = read_csv(paste0(mob_output_dir, "within-state_county-mobility/within-state_county-mobility_", date_set[i], ".csv")) %>%
      dplyr::select(date, geoid_o, total_pop_flow) %>%
      distinct()
    fips_specific_ts = bind_rows(fips_specific_ts, fips_subset)
  } # end loop over days time series
  
  max_fips_specific_ts = fips_specific_ts %>%
    group_by(geoid_o) %>%
    mutate(max_total_pop_flow = max(total_pop_flow)) %>%
    arrange(desc(total_pop_flow), .by_group = T) %>%
    slice(1) %>%
    ungroup() %>%
    dplyr::select(date, geoid_o, max_total_pop_flow) %>%
    rename(date_of_max_flow = date)
  
  write.csv(
    max_fips_specific_ts,
    paste0(mob_output_dir, "county_max_pop_flow_2019.csv"),
    row.names = F
  )
}else{
  max_fips_specific_ts = read_csv(paste0(mob_output_dir, "county_max_pop_flow_2019.csv"))
  print("County maximum pop flow already exists")
}

#/////////////////////////
#### STATE TIMESERIES ####
#/////////////////////////
# state look-up table for group split in loop
state_lookup = tigris::fips_codes %>%
  distinct(state_code, state_name, state) %>%  # state is USPS abbrev
  rename(state_fips = state_code,
         state_name = state_name,
         state_abbr = state) %>%
  # Replace spaces in state names with hyphens 
  mutate(state_name = str_replace_all(state_name, " ", "-"))

# Naming a random state file to check for since all 51 would get created in this loop
if(!file.exists(file.path(state_out_dir, "Texas_2019_timeseries.csv"))){
  for(i in 1:length(date_set)){
    # Update the within-state mobility files to have flow proportions normalized by the maximum outflow 2019
    fips_norm = read_csv(paste0(mob_output_dir, "within-state_county-mobility/within-state_county-mobility_", date_set[i], ".csv")) %>%
      left_join(max_fips_specific_ts, by="geoid_o") %>%
      rowwise() %>%
      mutate(max_norm_prop_flow = pop_flows/max_total_pop_flow) %>%
      ungroup() %>%
      mutate(state_fips = str_sub(geoid_o, 1, 2) ) %>%
      left_join(state_lookup, by="state_fips")
    
    write.csv(
      fips_norm,
      paste0(mob_output_dir, "max-norm_within-state_county-mobility/max-norm_within-state_county-mobility_", date_set[i], ".csv"),
      row.names = F
    )
    
    # split per state and append out
    # It's only appending, so do not want to run more than once!
    fips_norm %>%
      group_split(state_name, .keep = TRUE) %>%
      set_names(fips_norm %>% group_by(state_name) %>% group_keys() %>% pull()) %>%
      iwalk(function(chunk, st_nm) {
        if (is.na(st_nm) || nrow(chunk) == 0) return(NULL)
        out_path = file.path(state_out_dir, paste0(gsub("[^A-Za-z-]", "", st_nm), "_2019_timeseries.csv"))
        data.table::fwrite(chunk, out_path, append = file.exists(out_path))
      })
  } # end loop over days time series
}else{
  print("State specific timeseries already exist")
} # end if files haven't been created yet

#///////////////////////////
#### QUARTERLY STATE TS ####
#///////////////////////////
state_ts_files = list.files(
  path = state_out_dir,
  pattern = "_timeseries.csv$",
  full.names = TRUE
) # 52 files with PR so removing that
state_ts_files = state_ts_files[!grepl("Puerto-Rico", state_ts_files)]

# Wyoming last in list so easy to check
if(!file.exists("../data/Wyoming/Wyoming_Q4-2019_mobility-matrix.csv")){
  # Group the timeseries into quarter of the year 
  for(i in 1:length(state_ts_files)){
    state_ts = read_csv(state_ts_files[i], col_types = c("geoid_o"="c", "geoid_d"="c")) %>%
      mutate(
        quarter = case_when(
          date >= as.Date("2019-01-01") & date <  as.Date("2019-04-01") ~ "1",
          date >= as.Date("2019-04-01") & date <  as.Date("2019-07-01") ~ "2",
          date >= as.Date("2019-07-01") & date <  as.Date("2019-10-01") ~ "3",
          date >= as.Date("2019-10-01") & date <= as.Date("2019-12-31") ~ "4",
          TRUE ~ NA_character_)) %>%
      group_by(across(starts_with("state")), geoid_o, geoid_d, quarter) %>%
      summarise(mean_max_norm_prop_flow = mean(max_norm_prop_flow),
                median_max_norm_prop_flow = median(max_norm_prop_flow),
                min_max_norm_prop_flow = min(max_norm_prop_flow),
                max_max_norm_prop_flow = max(max_norm_prop_flow)) %>%
      ungroup() %>%
      # Need missing pairs to still be in matrix
      # Had one county never appear in Q1 for Hawaii so the final matrix wasn't square like it should be
      group_by(across(starts_with("state")), geoid_o, geoid_d) %>%
      complete(
        quarter = c("1", "2", "3", "4")
      ) %>%
      arrange(across(starts_with("state")), geoid_o, geoid_d, quarter) %>%
      # mark which rows are newly created (i.e., all summary columns were NA)
      mutate(
        imputed = is.na(mean_max_norm_prop_flow)
      ) %>%
      # Fill **all** numeric quarter summary columns with 0
      replace_na(list(
        mean_max_norm_prop_flow   = 0,
        median_max_norm_prop_flow = 0,
        min_max_norm_prop_flow    = 0,
        max_max_norm_prop_flow    = 0
      )) %>%
      ungroup()
    
    state_name_i = state_ts$state_name[1]
    out_path = file.path("../data", state_name_i, paste0(state_name_i, "_quarterly-2019_mobility.csv"))
    write.csv(
      state_ts,
      out_path,
      row.names = F
    )
    
    # Get most connected counties per quarter and how many people leave on average daily
    crosscounty_connect = state_ts %>%
      # drop self-flows
      dplyr::filter(geoid_o != geoid_d) %>%
      group_by(across(starts_with("state")), quarter, geoid_o) %>%
      summarise(
        prop_county_outflow = sum(mean_max_norm_prop_flow, na.rm = TRUE),
        total_counties_connected = sum(mean_max_norm_prop_flow > 0, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      left_join(acs_county_geo_2023, by=c("geoid_o"="GEOID")) %>%
      rowwise() %>%
      mutate(total_pop_outflow = round(POP_ACS2023*prop_county_outflow, 0)) %>%
      ungroup() %>%
      group_by(state_name, quarter) %>%
      arrange(state_name, quarter, desc(total_pop_outflow)) %>%
      ungroup()
    
    connect_out_path = file.path("../data", state_name_i, paste0(state_name_i, "_quarterly-2019_county-connection-ranking.csv"))
    write.csv(
      crosscounty_connect,
      connect_out_path,
      row.names = F
    )
    
    # Build OD matrices for each quarter filling with mean 
    quarters = sort(unique(state_ts$quarter))
    for(q in quarters){
      chunk = state_ts %>%
        dplyr::filter(quarter == q)
      
      if(nrow(chunk) == 0 || is.na(q)) next
      
      # pivot to OD matrix (rows: geoid_o, cols: geoid_d)
      mat_df = chunk %>%
        dplyr::select(geoid_o, geoid_d, mean_max_norm_prop_flow) %>%
        pivot_wider(
          names_from  = geoid_d,
          values_from = mean_max_norm_prop_flow,
          values_fill = 0
        ) %>%
        arrange(geoid_o)
      
      # drop labels (keep just numeric matrix)
      quarter_mat = as.matrix(mat_df[, -1, drop = FALSE])
      
      # write no row or column names on matrix
      mat_out_path = file.path("../data", state_name_i, paste0(state_name_i, "_Q", q, "-2019_mobility-matrix.csv") )
      write.table(
        quarter_mat,
        mat_out_path,
        sep       = ",", row.names = FALSE, col.names = FALSE )
    } # end loop over quarters
  } # end loop over states
}else{
  print("Quarterly matrices exist in state dirs")
}

#////////////////////////////////
#### VIZ NATIONAL TIMESERIES ####
# Visualize the national time series
flow_diff_df =  read_csv(paste0(mob_output_dir, "US_flow_diff_timeseries.csv"))
daily_ts = ggplot(flow_diff_df)+
  # red lines demarcate the start of each quarter
  geom_vline(xintercept = c(as.Date("2019-01-01"), as.Date("2019-04-01"), 
                            as.Date("2019-07-01"), as.Date("2019-10-01")),
             color="red", linetype="dashed", alpha=0.5)+
  geom_line(aes(x=date, y=new_flow_total), color="black")+
  labs(x="Date", y="2019 US Daily Population Flow", 
       title="2019 SafeGraph cell-phone based estimates of people leaving home")+
  theme_bw()

ggsave(paste0(fig_dir, "US_daily_mobility_ts_2019.png"),
       daily_ts, width=10, height=8, units = "in", bg="white")

# interactive option
# plotly::ggplotly(daily_ts)






