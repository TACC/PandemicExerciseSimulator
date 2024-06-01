#!/usr/bin/env python3
import logging

from .DiseaseModel import DiseaseModel

logger = logging.getLogger(__name__)

class StochasticSEATIRD(DiseaseModel):

    def __init__(self, disease_model):
        self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters
        #logger.info(f'instantiated StochasticSEATIRD object with stochastic={self.is_stochastic}')
        #logger.debug(f'{self.parameters}')
        return


    def simulate(self, node, time, parameters):
        #logger.debug(f'node={node}, time={time}')

        # grab PHA info

        # make 3d array of compartment totals / N
        # make copy of initial_state of node

        #_next_event(node, array, initial_state)

        pass

    def _next_event(self):
        pass

    def reinitialize_events(self, node):
        pass
