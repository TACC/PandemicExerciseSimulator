#!/usr/bin/env python3
import argparse
import copy
import logging
import shutil
import os
from typing import Type
import time
import csv
from pathlib import Path
from secrets import token_bytes
from numpy.random import SeedSequence, default_rng

from baseclasses.Day import Day
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

    # Distribute any day 0 or less vaccines to nodes and within populations
    vaccine_model.distribute_vaccines_to_nodes(network, day=0)
    for node in network.nodes:
        vaccine_model.distribute_vaccines_to_population(node, day=0)

    # Write initial conditions
    writer.write_csv(0, network) if writer.total_sims > 1 else writer.write_json(0, network)
    simulation_days.snapshot(network)

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
        writer.write_csv(day, network) if writer.total_sims > 1 else writer.write_json(day, network)

        # Early termination if no more infectious or soon to be people
        tolerance = 0.99 # less than 1 person
        compartment_totals = simulation_days.snapshot(network)
        names_to_sum = ('E', *travel_model.transmit_dict.keys())
        total_exposed_plus_inf = sum(
            compartment_totals[network.comp_index[nm]]
            for nm in names_to_sum
        )
        if total_exposed_plus_inf <= tolerance:
            logger.info(f"All exposed and infectious compartments are below "
                        f"{tolerance:.1e} on day {day}, ending simulation early.")
            break

    if writer.total_sims == 1:
        simulation_days.plot(writer.output_dir)
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

    # Create output directory
    output_dir = simulation_properties.output_dir_path
    os.makedirs(output_dir, exist_ok=True)
    logger.info(f'Created output directory: {output_dir}')

    # Copy input file to output directory to remember which file generated output
    input_file_path = os.path.abspath(args.input_filename)
    copied_input_path = os.path.join(output_dir, 'input.json')
    shutil.copyfile(input_file_path, copied_input_path)
    logger.info(f'Copied input file to: {copied_input_path}')

    # Also used for exporting day-by-day summary information
    realization_indices = simulation_properties.realization_indices
    realization_number = int(len(realization_indices))
    batch_num = int(simulation_properties.batch_num)
    
    # Initialize Model Parameters class instance
    # This is a subset of the simulation properties, and contains data from a
    # few of the input files
    parameters = ModelParameters(simulation_properties)

    # Initialize Network class which will contain a list of Nodes
    # There is one Node for each row in the population data (e.g. one Node
    # per county), and each Node contains Compartment data
    compartment_labels = parameters.disease_parameters["compartments"]  # e.g., ["S","E","I","R"]
    network = Network(compartment_labels)
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
                                  args.days,
                                  network.get_number_of_nodes(),
                                  parameters.number_of_age_groups
                                 )
    npis.pre_process(network)

    # Initialize antiviral model

    # Initialize vaccine model
    vaccine_parent = Vaccination(parameters)
    vaccine_model  = vaccine_parent.get_child(simulation_properties.vaccine_model, network)

    # Initialize disease model
    disease_parent = DiseaseModel(parameters, npis, now=0.0)
    disease_model  = disease_parent.get_child(simulation_properties.disease_model)
    # The Gillespie algorithm needs vaccine effectiveness
    disease_model.set_initial_conditions(simulation_properties.initial, network, vaccine_model)

    # Initialize a travel model - will default to Binomial travel
    travel_parent = TravelModel(parameters)
    travel_model  = travel_parent.get_child(simulation_properties.travel_model)

    # New random seed per realization num
    base_seed = int.from_bytes(token_bytes(16), "little")  # 128-bit
    parent_seedseq = SeedSequence(base_seed)
    child_seedseq = parent_seedseq.spawn(realization_number)

    # Run time output file
    csv_time_path = Path(simulation_properties.output_dir_path) / f"simulation_times_batch-{batch_num}.csv"
    for i, r in enumerate(realization_indices):
        start_time = time.perf_counter()
        # Initialize Days class instance, resets snapshot
        simulation_days = Day(args.days)

        # Set the random number generator seed for this realization num
        disease_model.set_seed(child_seedseq[i])

        # Need to pass original network each iteration
        network_copy = copy.deepcopy(network)

        # Initialize output writer
        writer = Writer(output_dir_path   = simulation_properties.output_dir_path,
                        realization_index = r, total_sims = realization_number,
                        batch_num = batch_num)
        logger.info(f'Began Simulation {r}; {i+1} of {realization_number} ')
        run( simulation_days,
             parameters,
             network_copy,
             vaccine_model,
             disease_model,
             travel_model,
             writer
           )
        # capture elapsed time
        elapsed = time.perf_counter() - start_time

        # Write a time results as soon as sim completes to handle unfinished jobs
        with open(csv_time_path, "a", newline="") as f:
            fieldnames = ["sim_num", "time_seconds"]
            csv_writer = csv.DictWriter(f, fieldnames=fieldnames)
            # write header if file is empty
            if f.tell() == 0:
                csv_writer.writeheader()
            csv_writer.writerow({"sim_num": r, "time_seconds": elapsed})
    return


if __name__ == '__main__':
    main()

