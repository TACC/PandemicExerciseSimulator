#!/usr/bin/env python3
import logging
from typing import Type

from .ModelParameters import ModelParameters

logger = logging.getLogger(__name__)


class DiseaseModel:

    def __init__(self, parameters:Type[ModelParameters], is_stochastic:bool = False):
        self.is_stochastic = is_stochastic
        self.parameters = parameters
        logger.info(f'instantiated DiseaseModel object')
        logger.debug(f'stochastic={self.is_stochastic}')
        logger.debug(f'{self.parameters}')
        return


    def __str__(self) -> str:
        return(f'DiseaseModel:Stochastic={self.is_stochastic}')


    def simulate():
        pass

    def expose_number_of_people():
        pass

    def reinitialize_events():
        pass

