#!/usr/bin/env python3
import logging
import numpy as np

logger = logging.getLogger(__name__)

class TravelFlow:

    def __init__(self, number_of_nodes:int):

        self.flow_data = np.zeros((number_of_nodes, number_of_nodes))
        logger.info(f'instantiated TravelFlow object for {number_of_nodes} nodes')
        logger.debug(f'{self.flow_data.shape}')
        return


    def load_travel_flow_file(self, filename:str):
        """
        The file work_matrix_rel.csv contains 254 rows and 254 columns, each 
        representing a county from the population file data
        Beware some numbers are in scientific format, e.g. 1.48929938393e-05
        """

        try:
            self.flow_data = np.genfromtxt(filename, delimiter=',')
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)
        return
