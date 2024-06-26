#!/usr/bin/env python3
import logging
from typing import Type

from baseclasses.Group import Group
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.Group import RiskGroup, VaccineGroup, Compartments

logger = logging.getLogger(__name__)


class DiseaseModel:

    def __init__(self, parameters:Type[ModelParameters], is_stochastic:bool = False, now:float = 0.0):
        self.is_stochastic = is_stochastic
        self.now = now
        self.parameters = parameters
        logger.info(f'instantiated DiseaseModel object with stochastic={self.is_stochastic}, now={self.now}')
        logger.debug(f'DiseaseModel.parameters = {self.parameters}')
        return


    def __str__(self) -> str:
        return(f'DiseaseModel:Stochastic={self.is_stochastic}')


    def set_initial_conditions(self, initial:list, network:Type[Network]):
        pass


    def _expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int):
        pass


    def simulate():
        pass


    def reinitialize_events():
        pass

