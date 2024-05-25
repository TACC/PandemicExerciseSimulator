#!/usr/bin/env python3
import argparse
import logging
import numpy as np

from baseclasses.Day import Day
from baseclasses.DiseaseModel import DiseaseModel
from baseclasses.InputSimulationProperties import InputSimulationProperties
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow
from baseclasses.Writer import Writer


parser = argparse.ArgumentParser()
parser.add_argument('-l', '--loglevel', type=str, required=False, default='WARNING',
                    help='set log level to DEBUG, INFO, WARNING, ERROR, or CRITICAL')
parser.add_argument('-d', '--days', type=int, required=False, default=365,
                    help='set number of days to simulate')
parser.add_argument('-i', '--input_filename', type=str, required=True,
                    help='path and name of json file to read in')
args = parser.parse_args()

format_str=f'[%(asctime)s] %(filename)s:%(funcName)s:%(lineno)s - %(levelname)s: %(message)s'
logging.basicConfig(level=args.loglevel, format=format_str)
logger = logging.getLogger(__name__)



def run():

    logger.debug('Entered the run function')
    # for each day of iteration...
    
    # handle distributions
    
    # apply treatments
    
    # modify stockpiles
    
    # simulate one step.  (what are node, time, parameters)
    
    # Travel
    
    # Write results

    return




def main():

    logger.info('Entered main loop')

    # Read input properties file
    # Can be pre-generated as template, or generated in GUI
    # (assume one filename input now, although C++ app supported multi file)
    simulation_properties = InputSimulationProperties(args.input_filename)
    logger.info(f'loaded in config file named {args.input_filename}')

    # Initialize Days class instances
    # 365 hardcoded in C++ app, realizations taken from simulation properties
    number_of_days_to_simulate = Day(args.days)
    logger.info(f'number_of_days_to_simulate is {number_of_days_to_simulate.number_of_days}')

    number_of_realizations = Day(simulation_properties.number_of_realizations)
    logger.info(f'number of realizations is {number_of_realizations.number_of_days}')

    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties
    parameters = ModelParameters(simulation_properties)
    parameters.load_contact_matrix(simulation_properties.contact_data_file)
    logger.info(f'model parameters loaded from simulation properties')

    # Initialize Stochastic and Deterministic disease models
    stochastic_disease_model = DiseaseModel(parameters, is_stochastic=True)
    logger.info(f'instantiated disease model {stochastic_disease_model}')

    deterministic_disease_model = DiseaseModel(parameters, is_stochastic=False)
    logger.info(f'instantiated disease model {deterministic_disease_model}')

    # Initialize Network class which will contain a list of Nodes
    network = Network()
    network.load_population_file(simulation_properties.population_data_file)
    network.population_to_nodes(parameters.high_risk_ratios)
    logger.info(f'instantiated Network model {network}')

    # Initialize Travel model
    travel = TravelFlow(network.number_of_nodes())
    travel.load_travel_flow_file(simulation_properties.flow_data_file)
    network.travel_flow_data = travel.flow_data
    logger.info(f'instantiated TravelFlowData class for {network.number_of_nodes()} nodes')
    logger.debug(f'{network.travel_flow_data.shape}')
    logger.debug(f'{network.travel_flow_data}')

    # Initialize output writer
    writer = Writer(simulation_properties.output_data_file)
    logger.info(f'instantiated Writer class - {writer}')
    
    # Set some initial conditions including number of initial infected from
    # properties input file
    #setInitialConditions(simulation_properties, network, stochastic_disease_model)
    #   for each V in the properties file
    #      get the county ID and the initial infected
    #      get the Node corresponding to that county id from the Network
    #      assume all initial infected are in age group 1 (5-24, this is hardcoded)
    #      create a GROUP struct (see DemographicGroup.h)
    #      one iteration of stochastic_disease_model.exposeNumberofPeople (node, group, initial_num_infected)

    # Stockpile strategies
    # Treatment strategies

    run()
#    run( number_of_days_to_simulate,
#         network, 
#         stochastic_disease_model,
#         deterministic_disease_model,
#         travel,
#         ### stockpile_strategy,
#         ### distribution_strategy,
#         parameters,
#         writer )



    # report summary statistics

    return


if __name__ == '__main__':
    main()

