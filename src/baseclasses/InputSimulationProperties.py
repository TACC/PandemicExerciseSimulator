#!/usr/bin/env python3
import json
import logging

logger = logging.getLogger(__name__)


class InputSimulationProperties:

    def __init__(self, input_filename:str):
        
        logger.info(f'loaded in config file named {input_filename}')
        with open(input_filename, 'r') as f:
            data = json.load(f)

        # parameters
        self.R0         = float(data['panflu']['params']['R0'])
        self.beta_scale = float(data['panflu']['params']['beta_scale'])  # R0CorrectionFactor
        self.tau        = float(data['panflu']['params']['tau'])
        self.kappa      = float(data['panflu']['params']['kappa'])
        self.gamma      = float(data['panflu']['params']['gamma'])
        self.chi        = float(data['panflu']['params']['chi'])
        self.nu_high    = data['panflu']['params']['nu_high']
        self.vaccine_wastage_factor   = float(data['panflu']['params']['vaccine_wastage_factor'])
        self.antiviral_effectiveness  = float(data['panflu']['params']['antiviral_effectiveness'])
        self.antiviral_wastage_factor = float(data['panflu']['params']['antiviral_wastage_factor'])

        # data files
        self.population_data_file         = data['panflu']['data']['population']
        self.contact_data_file            = data['panflu']['data']['contact']
        self.flow_data_file               = data['panflu']['data']['flow']
        self.vaccine_effectiveness_file   = data['panflu']['data']['vaccine_effectiveness']
        self.vaccine_adherence_file       = data['panflu']['data']['vaccine_adherence'] 
        self.high_risk_ratios_file        = data['panflu']['data']['high_risk_ratios']
        self.relative_susceptibility_file = data['panflu']['data']['relative_susceptibility'] # SIGMA
        self.nu_value_matrix_file         = data['panflu']['data']['nu_value_matrix']

        # simulation control
        self.number_of_realizations = int(data['panflu']['number_of_realizations'])
        self.output_data_file       = data['panflu']['output']

        # other
        self.public_health_announcements = data['panflu']['public_health_announcements']
        self.vaccine_pro_rata            = data['panflu']['pro_rata']
        self.vaccine_universal           = data['panflu']['universal']
        self.initial                     = data['panflu']['initial']
        self.vaccines                    = data['panflu']['vaccines']

        logger.info(f'instantiated InputSimulationProperties object')
        logger.debug(f'{self}')

        if (self._validate_input()):
            logger.info(f'verified InputSimulationProperties')

        return


    def __str__(self) -> str:
        return( f'\n'
                f'## PARAMETERS ##\n'
                f'R0={self.R0}\n'
                f'beta_scale={self.beta_scale}\n'
                f'tau={self.tau}\n'
                f'kappa={self.kappa}\n'
                f'gamma={self.gamma}\n'
                f'chi={self.chi}\n'
                f'nu_high={self.nu_high}\n'
                f'vaccine_wastage_factor={self.vaccine_wastage_factor}\n'
                f'antiviral_effectiveness={self.antiviral_effectiveness}\n'
                f'antiviral_wastage_factor={self.antiviral_wastage_factor}\n'
                f'## DATA FILES ##\n'
                f'population_data_file={self.population_data_file}\n'
                f'contact_data_file={self.contact_data_file}\n'
                f'flow_data_file={self.flow_data_file}\n'
                f'vaccine_effectiveness_file={self.vaccine_effectiveness_file}\n'
                f'vaccine_adherence_file={self.vaccine_adherence_file}\n'
                f'high_risk_ratios_file={self.high_risk_ratios_file}\n'
                f'relative_susceptibility_file={self.relative_susceptibility_file}\n'
                f'nu_value_matrix_file={self.nu_value_matrix_file}\n'
                f'## SIMULATION CONTROL ##\n'
                f'number_of_realizations={self.number_of_realizations}\n'
                f'output_data_file={self.output_data_file}\n'
                f'## OTHER ##\n'
                f'public_health_announcements={self.public_health_announcements}\n'
                f'vaccine_pro_rata={self.vaccine_pro_rata}\n'
                f'vaccine_universal={self.vaccine_universal}\n'
                f'initial={self.initial}\n'
                f'vaccines={self.vaccines}\n'
              )


    # TODO add some functions in here to verify that we got all the data
    def _validate_input(self) -> bool:
        return True



