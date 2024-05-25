#!/usr/bin/env python3
import json
import logging
import pandas as pd
from typing import Type

from .Node import Node
from .PopulationCompartments import PopulationCompartments

logger = logging.getLogger(__name__)


class Network:

    def __init__(self):
        self.nodes = []
        self.travel_flow_data = None
        logger.info('instantiated Network object with {len(self.nodes)} nodes')
        return


    def __str__(self) -> str:
        return(f'Network:Nodes={len(self.nodes)}')


    def load_population_file(self, filename:str):
        """
        The file county_age_matrix.5 contains 6 columns and a row for each county
        The first field is the fips county identifier from federal government 

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
        Store population data as list of nodes
        """

        for index, row in self.df_county_age_matrix.iterrows():
            this_group = list(row[1:])
            this_compartment = PopulationCompartments(this_group, high_risk_ratios)
            this_node = Node(index, this_compartment)
            self.add_node(this_node)

        logger.info(f'converted population data into {len(self.nodes)} nodes')

        return


    def add_node(self, node:Type[Node]):
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





    def number_of_stratifications(self):
        """
        if ( !_nodes.empty() ) {
            const unsigned int numberOfAgeGroups ( _nodes.front()->compartments()->numberOfAgeGroups() );
            return numberOfAgeGroups * RISK_GROUP_SIZE * VACCINATED_GROUP_SIZE;
        }
        """
        pass

    def number_of_age_groups(self):
        """
        if ( !_nodes.empty() ) {
            return _nodes.front()->compartments()->numberOfAgeGroups();
        }
        """
        pass


    def total_population(self):
        """
        double totalPopulation ( 0.0 );
    
        for ( Nodes::const_iterator iter = _nodes.begin(); iter != _nodes.end(); ++iter ) {
            Node::RefPtr node ( *iter );
    
            if ( node ) {
                const double population ( node->totalPopulation() );
                totalPopulation += population;
            }
        }
        """
        pass
