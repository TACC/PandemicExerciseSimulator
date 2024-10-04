#!/usr/bin/env python3
import logging
import numpy as np
import sys
from typing import Type

from .InputProperties import InputProperties

logger = logging.getLogger(__name__)


class ModelParameters:

    def __init__(self, simulation_properties:Type[InputProperties]):

        # parameters
        self.R0             = float(simulation_properties.R0)
        self.beta_scale     = float(simulation_properties.beta_scale)   # "R0CorrectionFactor"
        self.beta           = self.R0 / self.beta_scale

        # the following four parameters are provided by users as periods (units = days),
        # but then stored here as rates (units = 1/days)
        self.tau            = 1/float(simulation_properties.tau)
        self.kappa          = 1/float(simulation_properties.kappa)
        self.gamma          = 1/float(simulation_properties.gamma)
        self.chi            = 1/float(simulation_properties.chi)

        self.rho            = float(simulation_properties.rho)

        # the user enters one nu value for each age group, assumed to be low risk
        # population. use multiplier 9x to derive values for high risk population
        self.nu_values      = [[],[]]
        self.nu_values[0]   = [float(x)   for x in simulation_properties.nu]
        self.nu_values[1]   = [float(x)*9 for x in simulation_properties.nu]

        # transpose nu_values so that we can access values in the order we are used to
        #   e.g.:    nu_values[age][risk]
        self.nu_values = np.array(self.nu_values).transpose().tolist()

        # data files
        self.high_risk_ratios        = []
        self.relative_susceptibility = []       # SIGMA / sigma
        self.flow_reduction          = []

        # non-pharmaceutical interventions
        self.non_pharma_interventions = simulation_properties.non_pharma_interventions
        
        # antivirals
        if simulation_properties.antiviral_effectiveness is not None:
            self.antiviral_effectiveness  = float(simulation_properties.antiviral_effectiveness)
        else:
            self.antiviral_effectiveness  = simulation_properties.antiviral_effectiveness
        if simulation_properties.antiviral_wastage_factor is not None:
            self.antiviral_wastage_factor = float(simulation_properties.antiviral_wastage_factor)
        else:
            self.antiviral_wastage_factor = simulation_properties.antiviral_wastage_factor
        self.antiviral_stockpile      = simulation_properties.antiviral_stockpile

        # vaccines
        if simulation_properties.vaccine_wastage_factor is not None:
            self.vaccine_wastage_factor  = float(simulation_properties.vaccine_wastage_factor)
        else:
            self.vaccine_wastage_factor  = simulation_properties.vaccine_wastage_factor
        self.vaccine_pro_rata        = simulation_properties.vaccine_pro_rata
        if simulation_properties.vaccine_adherence is not None:
            self.vaccine_adherence       = [float(x) for x in simulation_properties.vaccine_adherence]
        else:
            self.vaccine_adherence = simulation_properties.vaccine_adherence
        if simulation_properties.vaccine_effectiveness is not None:
            self.vaccine_effectiveness   = [float(x) for x in simulation_properties.vaccine_effectiveness]
        else:
            self.vaccine_effectiveness = simulation_properties.vaccine_effectiveness
        self.vaccine_stockpile       = simulation_properties.vaccine_stockpile

        # some things assigned later
        self.number_of_age_groups = 0

        # TODO some parameters still need to be set
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
                f'rho={self.rho}, '
                f'nu_values = {self.nu_values} '
                f'antiviral_effectiveness={self.antiviral_effectiveness}, '
                f'antiviral_wastage_factor={self.antiviral_wastage_factor}, '
                f'vaccine_wastage_factor={self.vaccine_wastage_factor}, '
                f'vaccine_pro_rata={self.vaccine_pro_rata}, '
              )


    def load_data_files(self, simulation_properties:Type[InputProperties]):
        """
        Read in simulation properties from file and store
        """
        with open(simulation_properties.high_risk_ratios_file, 'r') as f:
            self.high_risk_ratios = [ float(line.rstrip()) for line in f ]

        with open(simulation_properties.relative_susceptibility_file, 'r') as f:
            self.relative_susceptibility = [ float(line.rstrip()) for line in f ]

        with open(simulation_properties.flow_reduction_file, 'r') as f:
            self.flow_reduction = [ float(line.rstrip()) for line in f ]

        logger.info(f'opening file: {simulation_properties.high_risk_ratios_file}')
        logger.info(f'opening file: {simulation_properties.relative_susceptibility_file}')
        logger.info(f'opening file: {simulation_properties.flow_reduction_file}')

        if not self.vaccine_effectiveness:
            self.vaccine_effectiveness = [0]*len(self.high_risk_ratios)

        logger.debug( f'vaccine_effectiveness = {self.vaccine_effectiveness}, '
                      f'vaccine_adherence = {self.vaccine_adherence}, '
                      f'high_risk_ratios = {self.high_risk_ratios}, '
                      f'relative_susceptibility = {self.relative_susceptibility}, '
                      f'flow_reduction = {self.flow_reduction}, '
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

        self._set_age_group_size()
        logger.debug(f'number_of_age_groups = {self.number_of_age_groups}')
        logger.debug(f'model parameter-associated contact matrix:')
        logger.debug(f'{self.np_contact_matrix}')
        return


    def get_contact(self, i:int, j:int) -> float:
        """
        Return contact rate beteween nodes i and j
        """
        return(self.np_contact_matrix[i][j])


    def _set_age_group_size(self):
        """
        Set age group size after loading in contact matrix
        """
        self.number_of_age_groups = (np.shape(self.np_contact_matrix)[0])
        return

