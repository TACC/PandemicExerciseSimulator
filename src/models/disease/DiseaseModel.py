#!/usr/bin/env python3
import logging
import numpy.typing as npt
import numpy as np
from typing import Type

from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from models.treatments.NonPharmaInterventions import NonPharmaInterventions
from models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)


class DiseaseModel:

    def __init__(self, parameters:Type[ModelParameters], npis:Type[NonPharmaInterventions], now:float = 0.0):
        self.disease_model = 'parent'
        self.parameters = parameters
        self.now = now
        self.npis_schedule = npis.schedule

        logger.info(f'instantiated DiseaseModel object with model={self.disease_model}, now={self.now}')
        logger.debug(f'DiseaseModel.parameters = {self.parameters}')
        return

    def __str__(self) -> str:
        return(f'DiseaseModel:Model={self.disease_model}')


    def get_child(self, disease_model:str):
        self.disease_model = disease_model
        if self.disease_model == 'seatird-deterministic':
            from .DeterministicSEATIRD import DeterministicSEATIRD
            return DeterministicSEATIRD(self)
        elif self.disease_model == 'seir-deterministic':
            from .DeterministicSEIRS import DeterministicSEIRS
            return DeterministicSEIRS(self)
        elif self.disease_model == 'seatird-stochastic':
            from .StochasticSEATIRD import StochasticSEATIRD
            return StochasticSEATIRD(self)
        else:
            raise Exception(f'Disease model "{self.disease_model}" not recognized')
        return


    def set_initial_conditions(self, initial: list, network: Type[Network], vaccine_model:Type[Vaccination]):
        """
        This method is invoked from the main simulator block. Read in the list of initial infected
        per location per age group, and expose

        Args:
            initial (list): list of initial infected per age group per county from INPUT
            network (Network): network object with list of nodes
        """
        # Get proportion of the population each subgroup is in for each node = group cache & doesn't change over time
        self._group_cache_per_node(network)

        for item in initial:
            # TODO the word "county" is hardcoded here but should be made dynamic in case
            # people want to do zip codes instead. Maybe 'location_id'
            this_node_id   = int(item['county'])
            this_infected  = int(item['infected'])
            this_age_group = int(item['age_group'])

            # The initial conditions currently only take in initial E by age and county, not risk/vax
            group = Group(this_age_group, RiskGroup.L.value, VaccineGroup.U.value)

            for node in network.nodes:
                if node.node_id == this_node_id:
                    self.expose_number_of_people(node, group, this_infected, vaccine_model)
        
        return

    def _group_cache_per_node(self, network: Type[Network]):
        for node in network.nodes:
            group_cache = np.zeros((self.parameters.number_of_age_groups,
                                    len(RiskGroup),
                                    len(VaccineGroup)))
            node.group_cache = self._demographic_sizes(node, group_cache)  # attach it to the node
        return

    def _demographic_sizes(self, node:Type[Node], group_cache:npt.ArrayLike):
        """
        Given a node, calculate demographic percentages and fill a given cache
        """
        this_population = node.total_population()
        for i in range(self.parameters.number_of_age_groups):
            for j in range(len(RiskGroup)):
                for k in range(len(VaccineGroup)):
                    group = Group(i, j, k)
                    group_cache[i][j][k] = node.compartments.demographic_population(group) / this_population
        return group_cache

    def _calculate_beta_w_npi(self, node_index: int, node_id: int) -> list:
        """
        Calculate the change in beta given non-pharmaceutical interventions
        """
        this_day = 0 if self.now == 0 else self.now - 1
        logging.debug(f'day = {this_day}; node_id = {node_id}; node_index = {node_index}')

        npi_effectiveness = self.npis_schedule[this_day][node_index]
        logging.debug(f'npi_effectiveness = {npi_effectiveness}')

        beta_baseline  = self.beta
        age_group_size = self.parameters.number_of_age_groups
        beta = [beta_baseline] * age_group_size

        if (len(npi_effectiveness) == age_group_size):
            for ag in range(age_group_size):
                beta[ag] = beta_baseline * (1.0 - npi_effectiveness[ag])

        logging.debug(f'beta_baseline = {beta_baseline}, beta = {beta}')
        return beta


    #def expose_number_of_people(self):
    #    pass

    def simulate(self):
        pass

    def reinitialize_events(self):
        pass

