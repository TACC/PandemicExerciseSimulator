#!/usr/bin/env python3
import logging
from typing import Type

from baseclasses.ModelParameters import ModelParameters
from models.treatments.NonPharmaInterventions import NonPharmaInterventions

logger = logging.getLogger(__name__)


class DiseaseModel:

    def __init__(self, parameters:Type[ModelParameters], npis:Type[NonPharmaInterventions], is_stochastic:bool = False, now:float = 0.0):
        self.is_stochastic = is_stochastic
        self.now = now
        self.parameters = parameters
        self.npis_schedule = npis.schedule
        logger.info(f'instantiated DiseaseModel object with stochastic={self.is_stochastic}, now={self.now}')
        logger.debug(f'DiseaseModel.parameters = {self.parameters}')
        return


    def __str__(self) -> str:
        return(f'DiseaseModel:Stochastic={self.is_stochastic}')


    def set_initial_conditions(self):
        pass


    def expose_number_of_people(self):
        pass


    def simulate(self):
        pass


    def reinitialize_events(self):
        pass

