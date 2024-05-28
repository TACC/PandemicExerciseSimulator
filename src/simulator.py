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
                    help='path and name of input simulation properties json file')
args = parser.parse_args()

format_str=f'[%(asctime)s] %(filename)s:%(funcName)s:%(lineno)s - %(levelname)s: %(message)s'
logging.basicConfig(level=args.loglevel, format=format_str)
logger = logging.getLogger(__name__)


def run():
    """
    Run function for simulating each day
    """

    logger.info('Entered the run function')
    # for each day of iteration...
    
    # handle distributions
    
    # apply treatments
    
    # modify stockpiles
    
    # simulate one step.  (what are node, time, parameters)
    
    # Travel
    
    # Write results

    return


def main():
    """
    Main entry point to PandemicExerciseSimulator
    """
    logger.info(f'Entered main loop')

    # Read input properties file
    # Can be pre-generated as template, or generated in GUI
    # (assume one filename input now, although C++ app supported multi file)
    simulation_properties = InputSimulationProperties(args.input_filename)

    # Initialize Days class instances
    # 365 hardcoded in C++ app, realizations taken from simulation properties
    number_of_days_to_simulate = Day(args.days)
    number_of_realizations = Day(simulation_properties.number_of_realizations)

    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties, and contains data from a
    # few of the input files
    parameters = ModelParameters(simulation_properties)
    parameters.load_contact_matrix(simulation_properties.contact_data_file)

    # Initialize Stochastic and Deterministic disease models
    stochastic_disease_model = DiseaseModel(parameters, is_stochastic=True)
    deterministic_disease_model = DiseaseModel(parameters, is_stochastic=False)

    # Initialize Network class which will contain a list of Nodes
    # There is one Node for each row in the population data (e.g. one Node
    # per county), and each Node contains Compartment data
    network = Network()
    network.load_population_file(simulation_properties.population_data_file)
    network.population_to_nodes(parameters.high_risk_ratios)

    # Initialize Travel model - an NxN matrix where N is the number of
    # Nodes in the Network
    travel = TravelFlow(network.number_of_nodes())
    travel.load_travel_flow_file(simulation_properties.flow_data_file)
    network.add_travel_flow_data(travel.flow_data)

    # Initialize output writer
    writer = Writer(simulation_properties.output_data_file)
    
    # Set some initial conditions including number of initial infected from
    # properties input file
    #setInitialConditions(simulation_properties, network, stochastic_disease_model)
    #   for each V in the properties file
    #      get the county ID and the initial infected
    #      get the Node corresponding to that county id from the Network
    #      assume all initial infected are in age group 1 (5-24, this is hardcoded)
    #      create a GROUP struct (see DemographicGroup.h)
    #      one iteration of stochastic_disease_model.exposeNumberofPeople (node, group, initial_num_infected)


    total_population = network.get_total_population()
    logger.debug(f'total population is {total_population}')
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

