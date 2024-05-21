#!/usr/bin/env python3
import argparse
import logging
import numpy as np

from baseclasses.Day import Day
from baseclasses.InputSimulationProperties import InputSimulationProperties
from baseclasses.DiseaseModel import DiseaseModel
from baseclasses.ModelParameters import ModelParameters


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

    logging.debug('Entered main loop')

    # Read in files and initialize our base classes
    number_of_days_to_simulate = Day(args.days)
    number_of_realizations = Day(1)
    logging.debug(f'number_of_days_to_simulate is {number_of_days_to_simulate}')

    # assume one filename input until we figure out why people might want to do more than one
    simulation_properties = InputSimulationProperties(args.input_filename)
    logging.debug(f'loaded in config file named {args.input_filename}')
    logging.debug(f'{simulation_properties}')


    # Based off what was read, set some defaults for other base classes
    parameters = ModelParameters(simulation_properties)
    logging.debug(f'model parameters loaded from simulation properties')
    logging.debug(f'{parameters}')

    stochastic_disease_model = DiseaseModel(parameters, is_stochastic=True)
    logging.debug(f'instantiated disease model {stochastic_disease_model}')
    logging.debug(f'{stochastic_disease_model.parameters}')

    deterministic_disease_model = DiseaseModel(parameters, is_stochastic=False)
    logging.debug(f'instantiated disease model {deterministic_disease_model}')
    logging.debug(f'{deterministic_disease_model.parameters}')

#    setInitialConditions(simulation_properties, network, stochastic_disease_model)  # does not do this for deterministic?



    # Network
    # Travel mode
    # Stockpile strategies
    # Treatment strategies


    # Create an output writer class and initialize here

	# Set up a thing to write log files
	# Call a simulator::run kind of function 
    run()
#    run( number_of_days_to_simulate,
#         ### network, 
#         stochastic_disease_model,
#         deterministic_disease_model,
#         ### travel,
#         ### stockpile_strategy,
#         ### distribution_strategy,
#         parameters,
#         ### writer )

    # report summary statistics



if __name__ == '__main__':
    main()
