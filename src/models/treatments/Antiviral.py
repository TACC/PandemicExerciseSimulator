#!/usr/bin/env python3
import logging
from typing import Type

from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node

logger = logging.getLogger(__name__)


class Antiviral:

    def __init__(self, parameters: Type[ModelParameters]):
        self.antiviral_model_str = 'parent'
        self.parameters = parameters

        logger.info(f'Instantiated Antiviral object with model={self.antiviral_model_str}')
        logger.debug(f'Antiviral.parameters = {self.parameters}')

    def get_child(self, antiviral_model_str: str, network: Type[Network]):
        """
        Choose antiviral strategy if one is specified.
        """
        if antiviral_model_str is None:
            logger.info("No antiviral strategy specified; using base Antiviral class.")
            return self

        if antiviral_model_str == "stockpile-age-risk":
            from .AntiViralStockpileStrategy import AntiviralStockpileStrategy
            return AntiviralStockpileStrategy(self, network)
        else:
            raise Exception(f'Antiviral model "{antiviral_model_str}" not recognized')

    def distribute_antivirals_to_nodes(self, network: Type[Network], day: int):
        pass

    def distribute_antivirals_to_population(self, node: Type[Node], day: int):
        pass
