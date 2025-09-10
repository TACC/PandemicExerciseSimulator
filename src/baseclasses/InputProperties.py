#!/usr/bin/env python3
import json
import logging
import os

logger = logging.getLogger(__name__)


class InputProperties:

    def __init__(self, input_filename:str):
        
        with open(input_filename, 'r') as f:
            input = json.load(f)
        logger.info(f'loaded in config file named {input_filename}')

        # simulation control
        self.output_dir_path        = input['output_dir_path']
        self.number_of_realizations = int(input['number_of_realizations'])

        # data files
        self.population_data_file         = input['data']['population']
        self.contact_data_file            = input['data']['contact']
        self.flow_data_file               = input['data']['flow']
        self.high_risk_ratios_file        = input['data']['high_risk_ratios']
        
        # disease model
        self.disease_model      = input['disease_model']['identity']
        self.disease_parameters = input['disease_model']['parameters']

        # travel model
        self.travel_model      = input['travel_model']['identity']
        self.travel_parameters = input['travel_model']['parameters']

        # initial infected
        self.initial     = input['initial_infected']

        # non-pharmaceutical interventions (optional)
        self.non_pharma_interventions = input.get('non_pharma_interventions', [])

        # antivirals (optional)
        self.antiviral_model = input['antiviral_model']['identity']
        self.antiviral_parameters = input['antiviral_model']['parameters']
        
        # vaccines (optional)
        vaccine_input = input.get('vaccine_model', {})  # returns {} if not present
        self.vaccine_model = vaccine_input.get('identity', None)
        self.vaccine_parameters = vaccine_input.get('parameters', {})

        logger.info(f'instantiated InputProperties object')
        logger.debug(f'{self}')

        if (self._validate_input()):
            logger.info(f'verified InputProperties')

        return


    def __str__(self) -> str:
        return( f'\n\n'
                f'## SIMULATION CONTROL ##\n'
                f'output_dir_path={self.output_dir_path}\n'
                f'number_of_realizations={self.number_of_realizations}\n'
                f'\n## DATA FILES ##\n'
                f'population_data_file={self.population_data_file}\n'
                f'contact_data_file={self.contact_data_file}\n'
                f'flow_data_file={self.flow_data_file}\n'
                f'high_risk_ratios_file={self.high_risk_ratios_file}\n'
                f'\n## DISEASE MODEL ##\n'
                f'disease_model={self.disease_model}\n'
                f'disease_parameters={self.disease_parameters}\n'
                f'\n## TRAVEL MODEL ##\n'
                f'travel_model={self.travel_model}\n'
                f'travel_parameters={self.travel_parameters}\n'  
                f'\n## INITIAL INFECTIONS ##\n'
                f'initial={self.initial}\n'
                f'\n## NON-PHARMACEUTICAL INTERVENTIONS ##\n'
                f'non_pharma_interventions={self.non_pharma_interventions}\n'
                f'\n## ANTIVIRALS ##\n'
                f'antiviral_model={self.vaccine_model}\n'
                f'antiviral_parameters={self.vaccine_parameters}\n'
                f'\n## VACCINES ##\n'
                f'vaccine_model={self.vaccine_model}\n'
                f'vaccine_parameters={self.vaccine_parameters}\n'
              )


    def _validate_input(self) -> bool:

        # Check output dir was created
        if not os.path.isdir(self.output_dir_path):
            logger.error(f'Output directory not found: {self.output_dir_path}')
            return False
        
        # verify that all input data files exist
        for data_file in [self.population_data_file,
                          self.contact_data_file,
                          self.flow_data_file,
                          self.high_risk_ratios_file]:
            try:
                with open(data_file, 'r') as f:
                    pass
            except FileNotFoundError as e:
                logger.error(f'Could not open data file {data_file}: {e}')
                return False
        
        return True



