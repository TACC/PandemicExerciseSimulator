#!/usr/bin/env python3
import argparse
import logging
import numpy as np

from baseclasses.Day import Day
from baseclasses.InputSimulationProperties import InputSimulationProperties
from baseclasses.DiseaseModel import DiseaseModel
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow


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



def run():

    logging.debug('Entered the run function')
    # for each day of iteration...
    
    # handle distributions
    
    # apply treatments
    
    # modify stockpiles
    
    # simulate one step.  (what are node, time, parameters)
    
    # Travel
    
    # Write results





def main():

    logging.info('Entered main loop')

    # Read input properties file
    # Can be pre-generated as template, or generated in GUI
    # (assume one filename input now, although C++ app supported multi file)
    simulation_properties = InputSimulationProperties(args.input_filename)
    logging.info(f'loaded in config file named {args.input_filename}')
    logging.debug(f'{simulation_properties}')

    # Initialize Days class instances
    # 365 hardcoded in C++ app, realizations taken from simulation properties
    number_of_days_to_simulate = Day(args.days)
    logging.info(f'number_of_days_to_simulate is {number_of_days_to_simulate.number_of_days}')
    logging.debug(f'{number_of_days_to_simulate}')

    number_of_realizations = Day(simulation_properties.number_of_realizations)
    logging.info(f'number of realizations is {number_of_realizations.number_of_days}')
    logging.debug(f'{number_of_realizations}')

    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties
    parameters = ModelParameters(simulation_properties)
    parameters.load_contact_matrix(simulation_properties.contact_data_file)
    logging.info(f'model parameters loaded from simulation properties')
    logging.debug(f'{parameters}')
    logging.info(f'model parameter-associated contact matrix:')
    logging.debug(f'{parameters.np_contact_matrix}')
    logging.debug(f'vaccine_effectiveness: {parameters.vaccine_effectiveness}')
    logging.debug(f'vaccine_adherence: {parameters.vaccine_adherence}')
    logging.debug(f'high_risk_ratios: {parameters.high_risk_ratios}')

    # Initialize Stochastic and Deterministic disease models
    stochastic_disease_model = DiseaseModel(parameters, is_stochastic=True)
    logging.info(f'instantiated disease model {stochastic_disease_model}')
    logging.debug(f'{stochastic_disease_model.parameters}')

    deterministic_disease_model = DiseaseModel(parameters, is_stochastic=False)
    logging.info(f'instantiated disease model {deterministic_disease_model}')
    logging.debug(f'{deterministic_disease_model.parameters}')

    # Initialize Network class which will contain a list of Nodes
    network = Network()
    network.load_population_file(simulation_properties.population_data_file)
    network.population_to_nodes(parameters.high_risk_ratios)
    logging.info(f'instantiated Network model {network}')
    logging.debug(f'{network.df_county_age_matrix}')

#    setInitialConditions(simulation_properties, network, stochastic_disease_model)


    # Initialize Travel model
    travel = TravelFlow(network.number_of_nodes())
    travel.load_travel_flow_file(simulation_properties.flow_data_file)
    network.travel_flow_data = travel.flow_data
    logging.info(f'instantiated TravelFlowData class for {network.number_of_nodes()} nodes')
    logging.info(f'{network.travel_flow_data.shape}')
    logging.info(f'{network.travel_flow_data}')

    # Stockpile strategies
    # Treatment strategies
    # Writer

    run()
#    run( number_of_days_to_simulate,
#         network, 
#         stochastic_disease_model,
#         deterministic_disease_model,
#         travel,
#         ### stockpile_strategy,
#         ### distribution_strategy,
#         parameters,
#         ### writer )



    # report summary statistics

    return


if __name__ == '__main__':
    main()

