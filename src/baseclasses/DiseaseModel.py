#!/usr/bin/env python3
from .ModelParameters import ModelParameters

class DiseaseModel:

    def __init__(self, parameters, is_stochastic:bool = False):
        self.is_stochastic = is_stochastic
        self.parameters = parameters


    def __str__(self):
        return(f'DiseaseModel:Stochastic={self.is_stochastic}')


    def simulate():
        pass

    def expose_number_of_people():
        pass

    def reinitialize_events():
        pass

