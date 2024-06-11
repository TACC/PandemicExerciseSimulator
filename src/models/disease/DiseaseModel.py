#!/usr/bin/env python3
import logging
from typing import Type

from baseclasses.Group import Group
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.PopulationCompartments import RiskGroup, VaccineGroup, Compartments

logger = logging.getLogger(__name__)


class DiseaseModel:

    def __init__(self, parameters:Type[ModelParameters], is_stochastic:bool = False, now:float = 0.0):
        self.is_stochastic = is_stochastic
        self.now = now
        self.parameters = parameters
        logger.info(f'instantiated DiseaseModel object with stochastic={self.is_stochastic}, now={self.now}')
        logger.debug(f'{self.parameters}')
        return


    def __str__(self) -> str:
        return(f'DiseaseModel:Stochastic={self.is_stochastic}')


    def set_initial_conditions(self, initial:list, network:Type[Network]):
        for item in initial['v']:
            # TODO the word "county" is hardcoded here but should be made dynamic in case
            # people want to do zip codes instead
            this_node_id = int(item['county'])
            this_infected = int(item['infected'])
            this_age_group = int(item['age_group'])

            group = Group(this_age_group, RiskGroup.L.value, VaccineGroup.U.value)

            for node in network.nodes:
                if node.node_id == this_node_id:
                    self._expose_number_of_people(node, group, this_infected)
        return


    def _expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int):
        """
        Initial infected should be moved into 'Exposed' compartment
        """
        node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] -= num_to_expose
        node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.E.value] += num_to_expose
        return


    def simulate():
        pass


    def reinitialize_events():
        pass

