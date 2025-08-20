#!/usr/bin/env python3
import argparse
import logging
import shutil
import os
from typing import Type
from icecream import ic

from baseclasses.Day import Day
#from baseclasses.Group import Compartments, RiskGroup
from baseclasses.InputProperties import InputProperties
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow
from baseclasses.Writer import Writer

from models.disease.DiseaseModel import DiseaseModel
from models.travel.TravelModel import TravelModel
from models.treatments.NonPharmaInterventions import NonPharmaInterventions
from models.treatments.Vaccination import Vaccination

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
         parameters:Type[ModelParameters],
         network:Type[Network],
         vaccine_model:Type[Vaccination],
         disease_model: Type[DiseaseModel],
         travel_model:Type[TravelModel],
         writer:Type[Writer]
       ):
    """
    Run function for simulating each day
    """

    logger.info('entered the run function')

    # Write initial conditions
    writer.write(0, network)
    simulation_days.snapshot(network)

    # Distribute any day 0 or less vaccines to nodes and within populations
    vaccine_model.distribute_vaccines_to_nodes(network, day=0)
    for node in network.nodes:
        vaccine_model.distribute_vaccines_to_population(node, day=0)

    # Iterate over each day, each node...
    for day in range(1, simulation_days.day+1):
        # Distribute vaccines from network stockpile to individual nodes and zero-out
        vaccine_model.distribute_vaccines_to_nodes(network, day)

        # Run distributions, treatments, stockpiles, and disease simulation for each node
        for node in network.nodes:
            # Distribute current day's vaccines and modify node stockpiles
            vaccine_model.distribute_vaccines_to_population(node, day)

            # apply antivirals

            # simulate one step
            disease_model.simulate(node, day, vaccine_model)

        # Run travel model
        travel_model.travel(network, disease_model, parameters, day, vaccine_model)

        # write output
        writer.write(day, network)

        # Early termination if no more infectious or soon to be people
        compartment_totals = simulation_days.snapshot(network)
        total_eati = sum(compartment_totals[1:5]) # Sum E, A, T, I
        tolerance = 1e-1
        if total_eati <= tolerance:
            logger.info(f"All E, A, T, I are below {tolerance:.1e} on day {day}, ending simulation early.")
            break

    simulation_days.plot()
    logger.info('completed processes in the run function')

    return


def main():
    """
    Main entry point to PandemicExerciseSimulator
    """
    logger.info(f'entered main loop')

    # Read input properties file
    # Can be pre-generated from template, or generated in GUI
    simulation_properties = InputProperties(args.input_filename)

    # Get full paths
    input_file_path   = os.path.abspath(args.input_filename)
    output_file_path  = os.path.abspath(simulation_properties.output_data_file)
    output_dir        = os.path.dirname(output_file_path)
    copied_input_path = os.path.join(output_dir, 'INPUT.json')

    # Ensure output directory exists
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir, exist_ok=True)
        logger.info(f'Created output directory: {output_dir}')

    # Copy input file to output directory (if not already there), to remember which file generated output
    if not os.path.exists(copied_input_path):
        shutil.copyfile(input_file_path, copied_input_path)
        logger.info(f'Copied input file to: {copied_input_path}')
    else:
        logger.info(f'Skipping copy; input file already exists at: {copied_input_path}')

    # Initialize Days class instances
    # Also used for exporting day-by-day summary information
    simulation_days = Day(args.days)
    realization_number = int(simulation_properties.number_of_realizations)
    
    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties, and contains data from a
    # few of the input files
    parameters = ModelParameters(simulation_properties)

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

    # Initialize non-pharmaceutical interventions
    npis = NonPharmaInterventions(simulation_properties.non_pharma_interventions,
                                  simulation_days.day,
                                  network.get_number_of_nodes(),
                                  parameters.number_of_age_groups
                                 )
    npis.pre_process(network)

    # Initialize antiviral model

    # Initialize vaccine model
    vaccine_parent = Vaccination(parameters)
    vaccine_model  = vaccine_parent.get_child(simulation_properties.vaccine_model, network)


    # Initialize disease model
    disease_parent = DiseaseModel(parameters,
                                  npis,
                                  now=0.0
                                 )
    disease_model  = disease_parent.get_child(simulation_properties.disease_model)
    # The Gillespie algorithm needs vaccine effectiveness
    disease_model.set_initial_conditions(simulation_properties.initial, network, vaccine_model)

    # Initialize a travel model - will default to Binomial travel
    travel_parent = TravelModel(parameters)
    travel_model  = travel_parent.get_child(simulation_properties.travel_model)

    # Initialize output writer
    writer = Writer(simulation_properties.output_data_file)

    for _ in range(realization_number):

        run( simulation_days,
             parameters,
             network,
             vaccine_model,
             disease_model,
             travel_model,
             writer
           )
        
    return


if __name__ == '__main__':
    main()

