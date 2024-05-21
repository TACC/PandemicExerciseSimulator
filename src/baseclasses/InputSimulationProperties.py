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

        self.population_data_file = data['panflu']['data']['population']
        self.contact_data_file    = data['panflu']['data']['contact']
        self.flow_data_file       = data['panflu']['data']['flow']
        self.output_data_file     = data['panflu']['output']

        self.public_health_announcements = data['panflu']['public_health_announcements']
        self.vaccine_pro_rata = data['panflu']['pro_rata']
        self.vaccine_universal = data['panflu']['universal']

        self.initial = data['panflu']['initial']
        self.vaccines = data['panflu']['vaccines']


    def __str__(self):
        return(f'R0={self.R0}, beta_scale={self.beta_scale}, tau={self.tau}, '
               f'kappa={self.kappa}, gamma={self.gamma}, nu_high={self.nu_high}')



### TODO
### Add some functions in here to verify that we got all the data

