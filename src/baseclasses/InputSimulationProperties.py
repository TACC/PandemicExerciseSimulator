#!/usr/bin/env python3
import json

class InputSimulationProperties:

    def __init__(self, input_filename):
        
        with open(input_filename, 'r') as f:
            data = json.load(f)

        self.R0         = float(data['panflu']['params']['R0'])
        self.beta_scale = float(data['panflu']['params']['beta_scale'])
        self.tau        = float(data['panflu']['params']['tau'])
        self.kappa      = float(data['panflu']['params']['kappa'])
        self.gamma      = float(data['panflu']['params']['gamma'])
        self.nu_high    = data['panflu']['params']['nu_high']

        self.number_of_realizations = float(data['panflu']['number_of_realizations'])

        self.vaccine_effectiveness_age_0 = float(data['panflu']['params']['vaccine_effectiveness_age_0'])
        self.vaccine_effectiveness_age_1 = float(data['panflu']['params']['vaccine_effectiveness_age_1'])
        self.vaccine_effectiveness_age_2 = float(data['panflu']['params']['vaccine_effectiveness_age_2'])
        self.vaccine_effectiveness_age_3 = float(data['panflu']['params']['vaccine_effectiveness_age_3'])
        self.vaccine_effectiveness_age_4 = float(data['panflu']['params']['vaccine_effectiveness_age_4'])

        self.vaccine_adherence_age_0 = float(data['panflu']['params']['vaccine_adherence_age_0'])
        self.vaccine_adherence_age_1 = float(data['panflu']['params']['vaccine_adherence_age_1'])
        self.vaccine_adherence_age_2 = float(data['panflu']['params']['vaccine_adherence_age_2'])
        self.vaccine_adherence_age_3 = float(data['panflu']['params']['vaccine_adherence_age_3'])
        self.vaccine_adherence_age_4 = float(data['panflu']['params']['vaccine_adherence_age_4'])


    def __str__(self):
        return(f'R0={self.R0}, beta_scale={self.beta_scale}, tau={self.tau}, '
               f'kappa={self.kappa}, gamma={self.gamma}, nu_high={self.nu_high}')



### TODO
### Add some functions in here to verify that we got all the data





# "panflu": {                                            
#   "output": "3D_Slow_Mild_P0-2009_PR-children_Tx-high-risk_Vacc-2009.nc",
#   "data": {                                            
#     "population": "../data/texas/county_age_matrix.5", 
#     "contact": "../data/texas/contact_matrix.5",       
#     "flow": "../data/texas/work_matrix_rel.csv"        
#   },                                                   
# 
# const std::string KEY_PANFLU ( "panflu" );
# const std::string KEY_POPULATION_FILE ( "panflu.data.population" );
# const std::string KEY_CONTACT_FILE ( "panflu.data.contact" );
# const std::string KEY_FLOW_FILE ( "panflu.data.flow" );
# 
# const std::string KEY_NUM_REALIZATIONS ("panflu.number_of_realizations");
# 
# const std::string KEY_INITIAL ( "panflu.initial" );
# const std::string KEY_INITIAL_COUNTRY ( "county" );
# const std::string KEY_INITIAL_INFECTED ( "infected" );
# 
# const std::string KEY_ANTIVIRALS ( "panflu.antivirals" );
# const std::string KEY_ANTIVIRALS_DAY ( "day" );
# const std::string KEY_ANTIVIRALS_AMOUNT ( "amount" );
# 
# const std::string KEY_VACCINES ( "panflu.vaccines" );
# const std::string KEY_VACCINES_DAY ( "day" );
# const std::string KEY_VACCINES_AMOUNT ( "amount" );
# const std::string KEY_VACCINES_PRO_RATA ( "panflu.pro_rata" );
# const std::string KEY_VACCINES_UNIVERSAL ( "panflu.universal" );
# 
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS ( "panflu.public_health_announcements" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_DAY ( "day" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_EFFECTIVENESS_AGE_0 ( "effectiveness_age_0" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_EFFECTIVENESS_AGE_1 ( "effectiveness_age_1" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_EFFECTIVENESS_AGE_2 ( "effectiveness_age_2" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_EFFECTIVENESS_AGE_3 ( "effectiveness_age_3" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_EFFECTIVENESS_AGE_4 ( "effectiveness_age_4" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_HALFLIFE_AGE_0 ( "halflife_age_0" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_HALFLIFE_AGE_1 ( "halflife_age_1" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_HALFLIFE_AGE_2 ( "halflife_age_2" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_HALFLIFE_AGE_3 ( "halflife_age_3" );
# const std::string KEY_PUBLIC_HEALTH_ANNOUNCEMENTS_HALFLIFE_AGE_4 ( "halflife_age_4" );
# 
# const std::string KEY_OUTPUT_FILE ( "panflu.output" );
# 
# const std::string KEY_R0     ( "panflu.params.R0" );
# const std::string KEY_BETA_SCALE ( "panflu.params.beta_scale" );
# const std::string KEY_TAU    ( "panflu.params.tau" );
# const std::string KEY_KAPPA  ( "panflu.params.kappa" );
# const std::string KEY_GAMMA  ( "panflu.params.gamma" );
# const std::string KEY_NU_HIGH ( "panflu.params.nu_high" );
# const std::string KEY_VACCINE_EFFECTIVENESS_AGE_0 ( "panflu.params.vaccine_effectiveness_age_0" );
# const std::string KEY_VACCINE_EFFECTIVENESS_AGE_1 ( "panflu.params.vaccine_effectiveness_age_1" );
# const std::string KEY_VACCINE_EFFECTIVENESS_AGE_2 ( "panflu.params.vaccine_effectiveness_age_2" );
# const std::string KEY_VACCINE_EFFECTIVENESS_AGE_3 ( "panflu.params.vaccine_effectiveness_age_3" );
# const std::string KEY_VACCINE_EFFECTIVENESS_AGE_4 ( "panflu.params.vaccine_effectiveness_age_4" );
# 
# const std::string KEY_VACCINE_ADHERENCE_AGE_0 ( "panflu.params.vaccine_adherence_age_0" );
# const std::string KEY_VACCINE_ADHERENCE_AGE_1 ( "panflu.params.vaccine_adherence_age_1" );
# const std::string KEY_VACCINE_ADHERENCE_AGE_2 ( "panflu.params.vaccine_adherence_age_2" );
# const std::string KEY_VACCINE_ADHERENCE_AGE_3 ( "panflu.params.vaccine_adherence_age_3" );
# const std::string KEY_VACCINE_ADHERENCE_AGE_4 ( "panflu.params.vaccine_adherence_age_4" );
