#!/usr/bin/env python3
import argparse
import logging
import numpy as np

from baseclasses.Day import Day
from baseclasses.InputSimulationProperties import InputSimulationProperties



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

#what are these
#    Network::RefPtr network,
#    IDiseaseModel::RefPtr stochasticDiseaseModel,
#    IDiseaseModel::RefPtr deterministicDiseaseModel,
#    ITravelModel::RefPtr travelModel,
#    const InterventionStockpileStrategies& distributions,
#    const InterventionTreatments& actions,
#    ModelParameters::RefPtr parameters,
#    IWriter::RefPtr writer

    # Read in files and initialize our base classes
    number_of_days_to_simulate = Day(args.days)
    logging.debug(f'number_of_days_to_simulate is {number_of_days_to_simulate}')

    # assume one filename input until we figure out why people might want to do more than one
    simulation_properties = InputSimulationProperties(args.input_filename)
    logging.debug(f'loaded in config file named {args.input_filename}')
    logging.debug(f'{simulation_properties}')


	# Set up a thing to write log files
	# Call a simulator::run kind of function 
    run()

    # report summary statistics



if __name__ == '__main__':
    main()
