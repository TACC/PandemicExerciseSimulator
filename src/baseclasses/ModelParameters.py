#!/usr/bin/env python3
import logging
import numpy as np
from typing import Type

from .InputSimulationProperties import InputSimulationProperties

logger = logging.getLogger(__name__)


class ModelParameters:

    def __init__(self, simulation_properties:Type[InputSimulationProperties]):

        # parameters
        self.R0             = simulation_properties.R0 
        self.beta_scale     = simulation_properties.beta_scale   # R0CorrectionFactor
        self.beta           = self.R0 / self.beta_scale
        self.tau            = simulation_properties.tau
        self.kappa          = simulation_properties.kappa
        self.gamma          = simulation_properties.gamma
        self.chi            = simulation_properties.chi
        self.low_death_rate = True if simulation_properties.nu_high == "no" else False
        self.vaccine_wastage_factor   = simulation_properties.vaccine_wastage_factor
        self.antiviral_effectiveness  = simulation_properties.antiviral_effectiveness
        self.antiviral_wastage_factor = simulation_properties.antiviral_wastage_factor

        # some things assigned later

        # data files
        self.vaccine_effectiveness   = []
        self.vaccine_adherence       = []
        self.high_risk_ratios        = []
        self.relative_susceptibility = []       # SIGMA / sigma
        self.nu_values               = [[],[]]

        # TODO some parameters still need to be set
        ## self.number_of_age_groups = 0
        ## self.pha_day = 0
        ## self.max_child_age_group = 1
        ## self.children_range = [0, 1]

        logger.info(f'instantiated ModelParameters object')
        logger.debug(f'{self}')

        return


    def __str__(self) -> str:
        return( f'R0={self.R0}, '
                f'beta_scale={self.beta_scale}, '
                f'beta={self.beta}, '
                f'tau={self.tau}, '
                f'kappa={self.kappa}, '
                f'gamma={self.gamma}, '
                f'chi={self.chi}, '
                f'low_death_rate={self.low_death_rate}, '
                f'vaccine_wastage_factor={self.vaccine_wastage_factor}, '
                f'antiviral_effectiveness={self.antiviral_effectiveness}, '
                f'antiviral_wastage_factor={self.antiviral_wastage_factor}'
              )


    def load_data_files(self, simulation_properties:Type[InputSimulationProperties]):

        with open(simulation_properties.vaccine_effectiveness_file, 'r') as f:
            self.vaccine_effectiveness = [ line.rstrip() for line in f ]

        with open(simulation_properties.vaccine_adherence_file, 'r') as f:
            self.vaccine_adherence = [ line.rstrip() for line in f ]

        with open(simulation_properties.high_risk_ratios_file, 'r') as f:
            self.high_risk_ratios = [ line.rstrip() for line in f ]

        with open(simulation_properties.relative_susceptibility_file, 'r') as f:
            self.relative_susceptibility = [ line.rstrip() for line in f ]

        # TODO confirm with Lauren that our understanding of these numbers is correct
        # This file is N rows X 4 columns. N=number of age groups
        # column 1 = low death rate, low risk group
        # column 2 = low death rate, high risk group
        # column 3 = high death rate, low risk group
        # column 4 = high death rate, high risk group
        try:
            np_all_nu_values = np.genfromtxt(simulation_properties.nu_value_matrix_file, delimiter=',')
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)
        
        if self.low_death_rate == True: # grab columns 1 and 2 from data
            self.nu_values[0] = list(np_all_nu_values.transpose()[0])
            self.nu_values[1] = list(np_all_nu_values.transpose()[1])

        elif self.low_death_rate == False: # grab columns 3 and 4 from data
            self.nu_values[0] = list(np_all_nu_values.transpose()[2])
            self.nu_values[1] = list(np_all_nu_values.transpose()[3])


        logger.debug( f'opening files: {simulation_properties.vaccine_effectiveness_file}, '
                      f'{simulation_properties.vaccine_adherence_file}, '
                      f'{simulation_properties.high_risk_ratios_file} '
                      f'{simulation_properties.relative_susceptibility_file} '
                      f'{simulation_properties.nu_value_matrix_file} '
                    )
        logger.debug( f'vaccine_effectiveness = {self.vaccine_effectiveness}, '
                      f'vaccine_adherence = {self.vaccine_adherence}, '
                      f'high_risk_ratios = {self.high_risk_ratios}, '
                      f'relative_susceptibility = {self.relative_susceptibility}, '
                      f'nu_values = {self.nu_values} '
                    )

        return


    def load_contact_matrix(self, filename:str):
        """
        Expecting an NxN matrix where N = number of age groups
        """

        try:
            self.np_contact_matrix = np.genfromtxt(filename, delimiter=',')
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)

        self._set_age_group_size()
        logger.debug(f'number_of_age_groups = {self.number_of_age_groups}')
        logger.debug(f'model parameter-associated contact matrix:')
        logger.debug(f'{self.np_contact_matrix}')

        return


    def _set_age_group_size(self):
        self.number_of_age_groups = (np.shape(self.np_contact_matrix)[0])
        return
            

    def get_contact(self, i:int, j:int) -> float:
        return(self.np_contact_matrix[i][j])


