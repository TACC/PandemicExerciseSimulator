#//////////////////////////////////////////////////////////////////////////////////////
#' Write state specific contact matrices for all settings and work
#'  to state folders, there is no seperate parent dir of all data
#' Mobility data from: https://github.com/epistorm/epydemix-data
#' 
#' Note:
#'  There is post-pandemic US-level data at https://github.com/epistorm/Epistorm-Mix
#'  However, for state-level data we use the the Epydemix package. 
#'  Epydemix also provides contact matrices for many international countries 
#/////////////////////////////////////////////////////////////////////////////////////

from epydemix.population import Population, load_epydemix_population
from pathlib import Path
import pandas as pd

US_states = ["Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut", "Delaware",
             "District-of-Columbia", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa",
             "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan", "Minnesota",
             "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada", "New-Hampshire", "New-Jersey",
             "New-Mexico", "New-York", "North-Carolina", "North-Dakota", "Ohio", "Oklahoma", "Oregon",
             "Pennsylvania", "Rhode-Island", "South-Carolina", "South-Dakota", "Tennessee", "Texas", "Utah",
             "Vermont", "Virginia", "Washington", "West-Virginia", "Wisconsin", "Wyoming"]

def to_population_name(state_hyphen: str) -> str:
    """Convert 'New-York' -> 'United_States_New_York'."""
    core = state_hyphen.replace("-", "_")
    return f"United_States_{core}"

current_directory_path = Path.cwd().parent / "data/"
contact_settings = ["all"] # "work" not being used
for state in US_states:
    state_name = to_population_name(state)
    # Load population data for States in the United States using the Mistry 2021 contact matrix
    population = load_epydemix_population(
        population_name  = state_name,
        contacts_source  = "mistry_2021",
        layers           = contact_settings, # "home", "school", "community"
        age_group_mapping={"0-4": [ '0',  '1',  '2',  '3',  '4'],
                          "5-17": [ '5',  '6',  '7',  '8',  '9',
                                   '10', '11', '12', '13', '14',
                                   '15', '16', '17'],
                         "18-49": ['18', '19', '20', '21', '22',
                                   '23', '24', '25', '26', '27',
                                   '28', '29', '30', '31', '32',
                                   '33', '34', '35', '36', '37',
                                   '38', '39', '40', '41', '42',
                                   '43', '44', '45', '46', '47',
                                   '48', '49'],
                         "50-64": ['50', '51', '52', '53', '54',
                                   '55', '56', '57', '58', '59',
                                   '60', '61', '62', '63', '64'],
                         "65+":   ['65', '66', '67', '68', '69',
                                   '70', '71', '72', '73', '74',
                                   '75', '76', '77', '78', '79',
                                   '80', '81', '82', '83', '84+']})

    for mat_idx in range(len(contact_settings)):
        contact_mat = population.contact_matrices[contact_settings[mat_idx]]
        df = pd.DataFrame(contact_mat)

        filename = f"contact_matrix_{state}_Mistry2021_{contact_settings[mat_idx]}.csv"
        out_path = current_directory_path / state / filename
        out_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(out_path, index=False, header=False) # no col/row labels, just matrix values
        print(f'Created {filename}')
