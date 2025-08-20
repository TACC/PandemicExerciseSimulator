#!/usr/bin/env python3
import logging
from typing import Type

from baseclasses.ModelParameters import ModelParameters

logger = logging.getLogger(__name__)


class TravelModel:

    def __init__(self, parameters:Type[ModelParameters]):
        self.travel_model = 'parent'
        self.parameters = parameters

        logger.info(f'instantiated a TravelModel object with model={self.travel_model}')
        logger.debug(f'TravelModel.parameters={self.parameters}')
        return


    def __str__(self) -> str:
        return(f'TravelModel')
    

    def get_child(self, travel_model:str):
        self.travel_model = travel_model
        if self.travel_model == 'binomial':
            from .BinomialTravel import BinomialTravel
            return BinomialTravel(self)
        else:
            raise Exception(f'Travel model "{self.travel_model}" not recognized')
        return


    def travel(self):
        pass