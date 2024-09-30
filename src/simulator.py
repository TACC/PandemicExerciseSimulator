#!/usr/bin/env python3
import argparse
import logging
from typing import Type

from baseclasses.Day import Day
from baseclasses.Group import Compartments, RiskGroup
from baseclasses.InputProperties import InputProperties
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow
from baseclasses.Writer import Writer
from models.disease.DeterministicSEATIRD import DeterministicSEATIRD
from models.disease.DiseaseModel import DiseaseModel
from models.disease.StochasticSEATIRD import StochasticSEATIRD
from models.travel.BinomialTravel import BinomialTravel
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


def run( simulation_days:Type[Day], 
         network:Type[Network],
         disease_model:Type[DiseaseModel],
         travel_model:Type[TravelModel],
         parameters:Type[ModelParameters],
         writer:Type[Writer]
       ):
    """
    Run function for simulating each day
    """

    logger.info('entered the run function')

    # Write initial conditions
    writer.write(0, network)

    # Iterate over each day, each node...
    for day in range(simulation_days.day):
        for node in network.nodes:

            # Run distributions, treatments, stockpiles, and simulation for each node
            # handle distributions
            # apply treatments
            # modify stockpiles
       
            # simulate one step.  (what are node, time, parameters)
            time=day+1
            #disease_model.reinitialize_events(node) # only for node->totalTransmitting() < 450
            disease_model.simulate(node, time)

        # Run travel model
        travel_model.travel(network, disease_model, parameters, time)

        # write output
        writer.write(day, network)
        simulation_days.snapshot(network)

    simulation_days.plot()
    logger.info('completed processes in the run function')

    return


def run_mock( simulation_days:Type[Day],
              network:Type[Network],
              parameters:Type[ModelParameters],
              writer:Type[Writer]
            ):
    """
    Mock run function for testing
    """
    for day in range(simulation_days.day):
        writer.write(day, network)

        for node in network.nodes:
            for i in range(parameters.number_of_age_groups):
                for j in range(len(RiskGroup)):
                    for k in range(len(Compartments)-1):
                        if node.compartments.compartment_data[i][j][0][k] > 1:
                            diff = node.compartments.compartment_data[i][j][0][k] * 0.05
                            node.compartments.compartment_data[i][j][0][k] -= diff
                            node.compartments.compartment_data[i][j][0][k+1] += diff
    return
 

def main():
    """
    Main entry point to PandemicExerciseSimulator
    """
    logger.info(f'entered main loop')

    # Read input properties file
    # Can be pre-generated as template, or generated in GUI
    simulation_properties = InputProperties(args.input_filename)

    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties, and contains data from a
    # few of the input files
    parameters = ModelParameters(simulation_properties)
    parameters.load_data_files(simulation_properties)
    parameters.load_contact_matrix(simulation_properties.contact_data_file)

    # Initialize Days class instances
    # Also used for exporting day-by-day summary information
    simulation_days = Day(args.days)
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
    travel_flow = TravelFlow(network.get_number_of_nodes())
    travel_flow.load_travel_flow_file(simulation_properties.flow_data_file)
    network.add_travel_flow_data(travel_flow.flow_data)

    # Initialize base disease model with stochastic flag and set number of initial
    # infected people in each node. Use this flag in future iterations to select
    # different disease model here.
    disease_model = DiseaseModel(parameters, is_stochastic=True, now=0.0)
    if disease_model.is_stochastic:
        disease_model = StochasticSEATIRD(disease_model)
        disease_model.set_initial_conditions(simulation_properties.initial, network)
    else:
        disease_model = DeterministicSEATIRD(disease_model)
        disease_model.set_initial_conditions(simulation_properties.initial, network)

    # Initialize a travel model - will default to Binomial travel
    travel_model = TravelModel()
    if True:
        travel_model = BinomialTravel()

    # Initialize non-pharmaceutical interventions
    #npis = NonPharmaInterventions(simulation_properties.non_pharma_interventions)

    # Initialize output writer
    writer = Writer(simulation_properties.output_data_file)
    
    # Vaccine distribution strategy
    # Vaccine schedule
    # Antiviral distribution

    for _ in range(realization_number):

        run( simulation_days,
             network,
             disease_model,
             travel_model,
             parameters,
             writer
           )
        
    return


if __name__ == '__main__':
    main()

