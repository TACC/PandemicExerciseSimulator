#!/usr/bin/env python3
import numpy as np

class TravelFlowData:

    def __init__(self, number_of_nodes:int):

        self.flow_data = np.zeros((number_of_nodes, number_of_nodes))

