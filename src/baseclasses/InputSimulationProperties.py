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

        self.number_of_realizations = int(data['panflu']['number_of_realizations'])

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
        return( f'\n'
                f'R0={self.R0}\n'
                f'beta_scale={self.beta_scale}\n'
                f'tau={self.tau}\n'
                f'kappa={self.kappa}\n'
                f'gamma={self.gamma}\n'
                f'nu_high={self.nu_high}\n'
                f'number_of_realizations={self.number_of_realizations}\n'
                f'vaccine_effectiveness_age_0={self.vaccine_effectiveness_age_0}\n'
                f'vaccine_effectiveness_age_1={self.vaccine_effectiveness_age_1}\n'
                f'vaccine_effectiveness_age_2={self.vaccine_effectiveness_age_2}\n'
                f'vaccine_effectiveness_age_3={self.vaccine_effectiveness_age_3}\n'
                f'vaccine_effectiveness_age_4={self.vaccine_effectiveness_age_4}\n'
                f'vaccine_adherence_age_0={self.vaccine_adherence_age_0}\n'
                f'vaccine_adherence_age_1={self.vaccine_adherence_age_1}\n'
                f'vaccine_adherence_age_2={self.vaccine_adherence_age_2}\n'
                f'vaccine_adherence_age_3={self.vaccine_adherence_age_3}\n'
                f'vaccine_adherence_age_4={self.vaccine_adherence_age_4}\n'
                f'population_data_file={self.population_data_file}\n'
                f'contact_data_file={self.contact_data_file}\n'
                f'flow_data_file={self.flow_data_file}\n'
                f'output_data_file={self.output_data_file}\n'
                f'public_health_announcements={self.public_health_announcements}\n'
                f'vaccine_pro_rata={self.vaccine_pro_rata}\n'
                f'vaccine_universal={self.vaccine_universal}\n'
                f'initial={self.initial}\n'
                f'vaccines={self.vaccines}\n'
              )
               



### TODO
### Add some functions in here to verify that we got all the data

