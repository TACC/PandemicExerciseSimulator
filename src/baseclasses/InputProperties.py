#!/usr/bin/env python3
import json
import logging

logger = logging.getLogger(__name__)


class InputProperties:

    def __init__(self, input_filename:str):
        
        logger.info(f'loaded in config file named {input_filename}')
        with open(input_filename, 'r') as f:
            input = json.load(f)

        # simulation control
        self.number_of_realizations = int(input['number_of_realizations'])
        self.output_data_file       = input['output']

        # parameters
        self.R0         = input['parameters']['R0']
        self.beta_scale = input['parameters']['beta_scale']  # "R0CorrectionFactor"
        self.tau        = input['parameters']['tau']
        self.kappa      = input['parameters']['kappa']
        self.gamma      = input['parameters']['gamma']
        self.chi        = input['parameters']['chi']
        self.rho        = input['parameters']['rho']
        self.nu         = input['parameters']['nu']

        # data files
        self.population_data_file         = input['data']['population']
        self.contact_data_file            = input['data']['contact']
        self.flow_data_file               = input['data']['flow']
        self.flow_reduction_file          = input['data']['flow_reduction']
        self.high_risk_ratios_file        = input['data']['high_risk_ratios']
        self.relative_susceptibility_file = input['data']['relative_susceptibility'] # SIGMA

        # initial infected
        self.initial     = input['initial_infected']

        # non-pharmaceutical interventions (optional)
        self.non_pharma_interventions = input.get('non_pharma_interventions', [])

        # antivirals (optional)
        self.antiviral_effectiveness  = input.get('antivirals').get('antiviral_effectiveness', 0)
        self.antiviral_wastage_factor = input.get('antivirals').get('antiviral_wastage_factor', 0)
        self.antiviral_stockpile      = input.get('antivirals').get('antiviral_stockpile', [])
        
        # vaccines (optional)
        self.vaccine_wastage_factor   = input.get('vaccines').get('vaccine_wastage_factor', 0)
        self.vaccine_pro_rata         = input.get('vaccines').get('vaccine_pro_rata', None)
        self.vaccine_adherence        = input.get('vaccines').get('vaccine_adherence', [])
        self.vaccine_effectiveness    = input.get('vaccines').get('vaccine_effectiveness', [])
        self.vaccine_stockpile        = input.get('vaccines').get('vaccine_stockpile', [])

        logger.info(f'instantiated InputProperties object')
        logger.debug(f'{self}')

        if (self._validate_input()):
            logger.info(f'verified InputProperties')

        return


    def __str__(self) -> str:
        return( f'\n'
                f'## SIMULATION CONTROL ##\n'
                f'number_of_realizations={self.number_of_realizations}\n'
                f'output_data_file={self.output_data_file}\n'
                f'## PARAMETERS ##\n'
                f'R0={self.R0}\n'
                f'beta_scale={self.beta_scale}\n'
                f'tau={self.tau}\n'
                f'kappa={self.kappa}\n'
                f'gamma={self.gamma}\n'
                f'chi={self.chi}\n'
                f'rho={self.rho}\n'
                f'nu={self.nu}\n'
                f'## DATA FILES ##\n'
                f'population_data_file={self.population_data_file}\n'
                f'contact_data_file={self.contact_data_file}\n'
                f'flow_data_file={self.flow_data_file}\n'
                f'flow_reduction_file={self.flow_data_file}\n'
                f'high_risk_ratios_file={self.high_risk_ratios_file}\n'
                f'relative_susceptibility_file={self.relative_susceptibility_file}\n'
                f'## INITIAL INFECTIONS ##\n'
                f'initial={self.initial}\n'
                f'## NON-PHARMACEUTICAL INTERVENTIONS ##\n'
                f'non_pharma_interventions={self.non_pharma_interventions}\n'
                f'## ANTIVIRALS ##\n'
                f'antiviral_effectiveness={self.antiviral_effectiveness}\n'
                f'antiviral_wastage_factor={self.antiviral_wastage_factor}\n'
                f'antiviral_stockpile={self.antiviral_stockpile}\n'
                f'## VACCINES ##\n'
                f'vaccine_wastage_factor={self.vaccine_wastage_factor}\n'
                f'vaccine_pro_rata={self.vaccine_pro_rata}\n'
                f'vaccine_adherence={self.vaccine_adherence}\n'
                f'vaccine_effectiveness={self.vaccine_effectiveness}\n'
                f'vaccine_stockpile={self.vaccine_stockpile}\n'
              )


    # TODO add some functions in here to verify that we got all the data
    def _validate_input(self) -> bool:
        return True



