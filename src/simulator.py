#!/usr/bin/env python3
import argparse
import logging
import numpy as np

from baseclasses.Day import Day
from baseclasses.InputSimulationProperties import InputSimulationProperties
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow
from baseclasses.Writer import Writer
from models.disease.DiseaseModel import DiseaseModel
from models.disease.StochasticSEATIRD import StochasticSEATIRD
from models.travel.TravelModel import TravelModel

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


def run( number_of_days_to_simulate, 
         network,
         disease_model,
         travel_model,
         parameters,
         writer
       ):
    """
    Run function for simulating each day
    """

    logger.info('Entered the run function')

    # for each day of iteration...
    for day in range(number_of_days_to_simulate.day):
        for node in network.nodes:

            # implement these later
            # handle distributions
            # apply treatments
            # modify stockpiles
       
            # simulate one step.  (what are node, time, parameters)
            time=day+1
            stochastic_seatird = StochasticSEATIRD(disease_model)
            stochastic_seatird.reinitialize_events(node)
            stochastic_seatird.simulate(node, time, parameters)
    
            # Travel
            # Write output

    return


def run_mock(number_of_days_to_simulate, network, parameters, writer):
    
    for day in range(number_of_days_to_simulate.day):
        writer.write(day, network)

        for node in network.nodes:
            for i in range(5):
                for j in range(2):
                    for k in range(6):
                        if node.compartments.compartment_data[i][j][0][k] > 1:
                            diff = node.compartments.compartment_data[i][j][0][k] * 0.05
                            node.compartments.compartment_data[i][j][0][k] -= diff
                            node.compartments.compartment_data[i][j][0][k+1] += diff

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

    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties, and contains data from a
    # few of the input files
    parameters = ModelParameters(simulation_properties)
    parameters.load_data_files(simulation_properties)
    parameters.load_contact_matrix(simulation_properties.contact_data_file)

    # Initialize Days class instances
    # 365 hardcoded in C++ app, realizations taken from simulation properties
    # Realization number is the number of times to perform the simulation
    number_of_days_to_simulate = Day(args.days)
    realization_number = int(simulation_properties.number_of_realizations)

    # Initialize Network class which will contain a list of Nodes
    # There is one Node for each row in the population data (e.g. one Node
    # per county), and each Node contains Compartment data
    network = Network()
    network.load_population_file(simulation_properties.population_data_file)
    network.population_to_nodes(parameters.high_risk_ratios)
    logger.debug(f'total population is {network.get_total_population()}')

    # Load in travel flow data - an NxN matrix where N is the number of Nodes
    # in the Network
    travel_flow = TravelFlow(network.number_of_nodes())
    travel_flow.load_travel_flow_file(simulation_properties.flow_data_file)
    network.add_travel_flow_data(travel_flow.flow_data)

    # Initialize base disease model with stochastic flag and set number of initial
    # infected people in each node
    disease_model = DiseaseModel(parameters, is_stochastic=True, now=0.0)
    disease_model.set_initial_conditions(simulation_properties.initial, network)

    # Initialize a travel model - will default to Binomial travel
    travel_model = TravelModel()

    # Initialize output writer
    writer = Writer(simulation_properties.output_data_file)
    

    # Vaccine distribution strategy
    # Vaccine schedule
    # Antiviral distribution
    # Public health announcements


    for _ in range(realization_number):

        #run_mock( number_of_days_to_simulate,
        #          network,
        #          parameters,
        #          writer
        #        )

        run( number_of_days_to_simulate,
             network,
             disease_model,
             travel_model,
             parameters,
             writer
           )

    # report summary statistics

    return


if __name__ == '__main__':
    main()

