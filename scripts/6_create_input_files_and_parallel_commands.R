#///////////////////////////////////////////////////////////////
#' Change the template files to be state specific, then
#'  create the parallel commands to submit job on TACC LS6
#' This job took about 12h on 2 nodes, 64 tasks in parallel
#'  TX and GA take the longest to run at ~2sec per sim day
#'
#' Note:
#'  Assuming all the output files for each state execute from
#'   US_STATES dir, so launch parallel job from there
#'  You can also copy/paste one line of the commands file into a
#'   terminal window in US_STATES to test a single state locally
#'
#' Parent dirs: INPUT_FILE_TEMPLATES, VACCINATION, POPULATION
#////////////////////////////////////////////////////////////////

#///////////////////////
#### LOAD LIBRARIES ####
library(jsonlite)
library(tidyverse)

dir.create("../US_States/")
simulation_days = 212

#/////////////////////////
#### HELPER FUNCTIONS ####
# Replace "STATE" tokens in all strings from template
replace_STATE_tokens = function(x, state_dir) {
  # match STATE when not next to letters/digits (underscore is ok)
  pat = "(?<![A-Za-z0-9])STATE(?![A-Za-z0-9])"
  if (is.character(x)) {
    stringr::str_replace_all(x, pat, state_dir)
  } else if (is.list(x)) {
    lapply(x, replace_STATE_tokens, state_dir = state_dir)
  } else x
} # end replace_STATE_tokens

# Turn a state's schedule into the vaccine_stockpile JSON list
make_stockpile_json = function(state_df) {
  state_df %>%
    arrange(ReleaseDay) %>%
    transmute(
      day    = as.character(ReleaseDay),  # keep as strings to match template                
      amount = as.character(round(TotalWeeklyNewFullProtect))
    ) %>%
    transpose() # list of lists: list(list(day=..., amount=...), ...)                                          
} # end make_stockpile_json

#//////////////////
#### LOAD DATA ####
# Get template paths
input_dir_path   = "../data/INPUT_FILE_TEMPLATES"      # where files are written (FS path from here)
base_file = list.files(path        = input_dir_path,
                       pattern     = "^INPUT_SEIHRD-STOCH_STATE.*BASELINE\\.json$",
                       full.names  = TRUE, recursive  = TRUE)
vax_file = list.files(path        = input_dir_path,
                      pattern     = "^INPUT_SEIHRD-STOCH_STATE.*VAX\\.json$",
                      full.names  = TRUE, recursive  = TRUE)

# Vaccines distributed to people who get 100% VE against infection
state_weekly_vax_given = read_csv("../data/VACCINATION/all_US_weekly_vax_distribution.csv")

# Get total counties per state to determine num batches
county_df = read_csv("../data/POPULATION/county_lookup_2019-2023ACS.csv")
county_per_state = county_df %>%
  group_by(STATE_NAME) %>%
  summarise(num_county = n(), .groups = "drop")

# Get all county initial infected
county_init_inf = read_csv("../data/POPULATION/all_US_initial_infected.csv") %>%
  drop_na() %>%
  #dplyr::select("fips", "age_group", "pop", "STATE_NAME", "COUNTY_NAME", "STATE_FIPS", "init_inf_per_1M") %>%
  left_join(county_per_state, by="STATE_NAME") %>%
  mutate(
    STATE_NAME_DIR = str_replace_all(STATE_NAME, " ", "-"),
    base_file = base_file,
    vax_file = vax_file
  ) %>%
  separate(base_file, into = c(NA, NA, NA, "BASE_FILENAME_ONLY"), sep="\\/", remove=T) %>%
  separate(vax_file,  into = c(NA, NA, NA, "VAX_FILENAME_ONLY"),  sep="\\/", remove=T) %>%
  mutate(
    BASE_FILENAME_ONLY = replace_STATE_tokens(BASE_FILENAME_ONLY, STATE_NAME_DIR),
    BASE_OUTPUT_FILE_PATH = paste0("../data/", STATE_NAME_DIR, "/", BASE_FILENAME_ONLY),
    VAX_FILENAME_ONLY = replace_STATE_tokens(VAX_FILENAME_ONLY, STATE_NAME_DIR),
    VAX_OUTPUT_FILE_PATH = paste0("../data/", STATE_NAME_DIR, "/", VAX_FILENAME_ONLY),
    # Just for consistent formatting in json where every input is in quotes, doesn't actually matter
    init_inf_per_1M = as.character(init_inf_per_1M)
  )

total_states = length(unique(county_init_inf$STATE_NAME_DIR))

#//////////////////////////////
#### BASE SIMULATION FILES ####
base_template = jsonlite::fromJSON(base_file, simplifyVector = FALSE)
for(i in 1:total_states){
  print(i)
  # grab row just for single state
  single_state = county_init_inf %>%
    slice(i)
  
  state_template_copy = base_template
  state_template = replace_STATE_tokens(state_template_copy, state_dir = single_state$STATE_NAME_DIR)
  state_template$initial_infected[[1]]$county   = single_state$fips
  state_template$initial_infected[[1]]$infected = single_state$init_inf_per_1M
  
  write_json(state_template, single_state$BASE_OUTPUT_FILE_PATH, 
             auto_unbox = TRUE, pretty = TRUE, null = "null")
  print(paste0("wrote file to ", single_state$BASE_OUTPUT_FILE_PATH))
  
} # end loop over states


#/////////////////////////////////
#### VACCINE SIMULATION FILES ####
vax_template = jsonlite::fromJSON(vax_file, simplifyVector = FALSE)
for(i in 1:total_states){
  # grab row just for single state
  single_state = county_init_inf %>%
    slice(i)
  state_vax_ts = state_weekly_vax_given %>%
    dplyr::filter(State == single_state$STATE_NAME)
  
  state_template_copy = vax_template
  state_template = replace_STATE_tokens(state_template_copy, state_dir = single_state$STATE_NAME_DIR)
  state_template$initial_infected[[1]]$county   = single_state$fips
  state_template$initial_infected[[1]]$infected = single_state$init_inf_per_1M
  
  state_template$vaccine_model$parameters$vaccine_stockpile <- make_stockpile_json(state_vax_ts)
  
  write_json(state_template, single_state$VAX_OUTPUT_FILE_PATH, 
             auto_unbox = TRUE, pretty = TRUE, null = "null")
  print(paste0("wrote file to ", single_state$VAX_OUTPUT_FILE_PATH))
} # end loop over states


#////////////////////////
#### CREATE COMMANDS ####
base_commands_script = county_init_inf %>%
  mutate(poetry_command_start = paste("poetry run python3 ../src/simulator.py -l INFO -d", simulation_days ,"-i")) %>%
  rowwise() %>%
  mutate(final_poetry_command = paste(poetry_command_start, BASE_OUTPUT_FILE_PATH)) %>%
  ungroup() %>%
  dplyr::select(final_poetry_command)
vax_commands_script = county_init_inf %>%
  mutate(poetry_command_start = paste("poetry run python3 ../src/simulator.py -l INFO -d", simulation_days ,"-i")) %>%
  rowwise() %>%
  mutate(final_poetry_command = paste(poetry_command_start, VAX_OUTPUT_FILE_PATH)) %>%
  ungroup() %>%
  dplyr::select(final_poetry_command)

all_commands_script = base_commands_script %>%
  bind_rows(vax_commands_script)

write.table(all_commands_script,
            "../US_States/state_commands.txt",
            sep = "", col.names = FALSE,  row.names = FALSE, quote = FALSE)







