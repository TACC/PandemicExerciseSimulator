#!/usr/bin/env python3
import json
import logging
import pandas as pd
from typing import Type

from .Node import Node
from .PopulationCompartments import PopulationCompartments
from .PopulationCompartments import RiskGroup, VaccineGroup

logger = logging.getLogger(__name__)


class Network:

    def __init__(self):
        self.nodes = []
        self.travel_flow_data = None
        self.total_population = 0
        self.df_county_age_matrix = []
        logger.info(f'instantiated Network object with {self.number_of_nodes()} nodes')
        return


    def __str__(self) -> str:
        return(f'Network:Nodes={self.number_of_nodes()}')


    def load_population_file(self, filename:str):
        """
        The population file should contain a header row followed by a row for
        each node (e.g. county, city, zip code, etc.). The first column should
        be the fips ID, and the rest of the columns should be age groups.

        "fips","0-4","5-24","25-49","50-64","65+"
        1,3292,13222,23406,9535,6898             
        3,1134,4152,3997,2234,1803               
        5,6223,23990,27426,14327,10768           
        7,1314,6019,6481,5964,5454               
        """

        try:
            self.df_county_age_matrix = pd.read_csv(filename)
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)
        logger.info(f'loaded population data from {filename} into Network')
        logger.debug(f'{self.df_county_age_matrix}')
        return

            
    def population_to_nodes(self, high_risk_ratios: list):
        """
        Store population data as list of nodes. Needs high_risk_ratios to
        partition between high risk and low risk compartments
        """

        for index, row in self.df_county_age_matrix.iterrows():
            this_id = row.iloc[0]
            this_group = list(row[1:])
            this_compartment = PopulationCompartments(this_group, high_risk_ratios)
            this_node = Node(this_id, this_compartment)
            self._add_node(this_node)

        logger.info(f'converted population data into {self.number_of_nodes()} nodes')

        return


    def _add_node(self, node:Type[Node]):
        self.nodes.append(node)
        return


    def number_of_nodes(self) -> int:
        return(len(self.nodes))


    def add_travel_flow_data(self, travel_flow_data):
        self.travel_flow_data = travel_flow_data
        logger.info(f'added travel flow data to Network object')
        logger.debug(f'{self.travel_flow_data.shape}')
        logger.debug(f'{self.travel_flow_data}')
        
        return


    def get_total_population(self) -> int:
        total_population = 0
        for item in self.nodes:
            total_population += item.compartments.total_population
            #logger.debug(f'population in this node is {item.compartments.total_population}')
        self.total_population = total_population
        return self.total_population


    def get_number_of_age_groups(self) -> int:
        return self.nodes[0].compartments.number_of_age_groups


    def get_number_of_stratifications(self) -> int:
        return (self.nodes[0].compartments.number_of_age_groups * len(RiskGroup) * len(VaccineGroup))


