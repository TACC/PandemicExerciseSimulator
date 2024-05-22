#!/usr/bin/env python3
from typing import Type
from .Node import Node
import json
import pandas as pd


class Network:

    def __init__(self):
        self.nodes = []

    def __str__(self):
        return(f'Network:Nodes={len(self.nodes)}')



    def add_node(self, node:Type[Node]):
        self.nodes.append(node)
        pass



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

    def number_of_nodes(self):
        return(len(self.nodes))
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


    def load_population_file(self, filename):
        """
        The file county_age_matrix.5 contains 6 columns and a row for each county
        The first field is the fips county identifier from federal government 

        "fips","0-4","5-24","25-49","50-64","65+"
        1,3292,13222,23406,9535,6898             
        3,1134,4152,3997,2234,1803               
        5,6223,23990,27426,14327,10768           
        7,1314,6019,6481,5964,5454               

        """
        #filename = f'../../{filename}'

        try:
            #self.np_county_age_matrix = np.genfromtxt(filename, delimiter=',')
            self.df_county_age_matrix = pd.read_csv(filename)
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)

            


