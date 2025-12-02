#!/usr/bin/env python3
import logging
import numpy as np
from typing import Type

from .InputProperties import InputProperties

logger = logging.getLogger(__name__)


class ModelParameters:

    def __init__(self, simulation_properties:Type[InputProperties]):

        # parameters loaded as a dictionary here, processed later by disease model
        self.disease_parameters = simulation_properties.disease_parameters

        # travel parameters loaded as a dictionary here, processed later by travel model
        self.travel_parameters = simulation_properties.travel_parameters

        # data files
        self.high_risk_ratios        = []

        # non-pharmaceutical interventions
        self.non_pharma_interventions = simulation_properties.non_pharma_interventions
        
        # antivirals
        #self.antiviral_parameters = simulation_properties.antiviral_parameters

        # vaccines
        self.vaccine_parameters = simulation_properties.vaccine_parameters

        # some things assigned later
        self.number_of_age_groups = 0

        self._load_data_files(simulation_properties)

        logger.info(f'instantiated ModelParameters object')
        logger.debug(f'{self}')
        return


    def __str__(self) -> str:
        return( f'disease_parameters={self.disease_parameters}\n'
                f'travel_parameters={self.travel_parameters}\n'
                f'non_pharma_interventions={self.non_pharma_interventions}\n'
                #f'antiviral_parameters = {self.antiviral_parameters}\n'
                f'vaccine_parameters = {self.vaccine_parameters}\n'
                f'high_risk_ratios = {self.high_risk_ratios}\n'
                f'number_of_age_groups = {self.number_of_age_groups}\n'
                f'model parameter-associated contact matrix=\n{self.np_contact_matrix}\n'
              )


    def _load_data_files(self, simulation_properties:Type[InputProperties]):
        """
        Read in simulation data that is stored in files, not including
        the population data file and the travel flow matrix.
        """
        logger.info(f'opening file: {simulation_properties.high_risk_ratios_file}')
        with open(simulation_properties.high_risk_ratios_file, 'r') as f:
            self.high_risk_ratios = [ float(line.rstrip()) for line in f ]

        logger.info(f'opening file: {simulation_properties.contact_data_file}')
        try:
            self.np_contact_matrix = np.genfromtxt(simulation_properties.contact_data_file,
                                                   delimiter=',')
        except FileNotFoundError as e:
            raise Exception(f'Could not open {simulation_properties.contact_data_file}') from e

        self._set_age_group_size()

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

