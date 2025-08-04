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
        #self.flow_reduction          = []       # moved to travel model

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
            self.vaccine_adherence = [float(x) for x in simulation_properties.vaccine_adherence]
        else:
            self.vaccine_adherence = simulation_properties.vaccine_adherence
        if simulation_properties.vaccine_effectiveness is not None:
            self.vaccine_effectiveness = [float(x) for x in simulation_properties.vaccine_effectiveness]
        else:
            self.vaccine_effectiveness = simulation_properties.vaccine_effectiveness
        if simulation_properties.vaccine_eff_lag_days is not None:
            self.vaccine_eff_lag_days  = float(simulation_properties.vaccine_eff_lag_days)
        else:
            self.vaccine_eff_lag_days  = simulation_properties.vaccine_eff_lag_days
        self.vaccine_stockpile       = simulation_properties.vaccine_stockpile

        # some things assigned later
        self.number_of_age_groups = 0

        # TODO some parameters still need to be set
        ## self.max_child_age_group = 1
        ## self.children_range = [0, 1]

        self._load_data_files(simulation_properties)

        logger.info(f'instantiated ModelParameters object')
        logger.debug(f'{self}')
        return


    def __str__(self) -> str:
        return( f'disease_parameters={self.disease_parameters}\n'
                f'travel_parameters={self.travel_parameters}\n'
                f'non_pharma_interventions={self.non_pharma_interventions}\n'
                f'vaccine_effectiveness = {self.vaccine_effectiveness}\n'
                f'vaccine_adherence = {self.vaccine_adherence}\n'
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

        if not self.vaccine_effectiveness:
            self.vaccine_effectiveness = [0]*len(self.high_risk_ratios)

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

