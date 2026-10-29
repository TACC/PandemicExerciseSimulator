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
from numpy.random import SeedSequence

from baseclasses.Day import Day
from baseclasses.InputProperties import InputProperties
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.TravelFlow import TravelFlow
from baseclasses.Writer import Writer, RealizationWriter
from utils.Execution import choose_workers

from utils.ConfigExport import build_executed_config, write_metadata_json

from models.disease.DiseaseModel import DiseaseModel
from models.travel.TravelModel import TravelModel
from models.treatments.NonPharmaInterventions import NonPharmaInterventions
from models.treatments.Antiviral import Antiviral
from models.treatments.Vaccination import Vaccination

format_str=f'[%(asctime)s] %(filename)s:%(funcName)s:%(lineno)s - %(levelname)s: %(message)s'
logger = logging.getLogger(__name__)


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('-l', '--loglevel', type=str, required=False, default='WARNING',
                        help='set log level to DEBUG, INFO, WARNING, ERROR, or CRITICAL')
    parser.add_argument('-d', '--days', type=int, required=False, default=365,
                        help='set number of days to simulate')
    parser.add_argument('-i', '--input_filename', type=str, required=True,
                        help='path and name of input simulation properties json file')
    return parser


def parse_args(argv=None):
    return build_parser().parse_args(argv)


def run( simulation_days:Type[Day],
         parameters:Type[ModelParameters],
         network:Type[Network],
         antiviral_model:Type[Antiviral],
         vaccine_model:Type[Vaccination],
         disease_model: Type[DiseaseModel],
         travel_model:Type[TravelModel],
         writer:Type[Writer]
       ):
    """
    Run function for simulating each day
    """

    logger.info('entered the run function')
    antivirals_use_incident_entries = getattr(
        antiviral_model,
        "uses_incident_compartment_entries",
        False,
    )

    # Distribute any day 0 or less vaccines to nodes and within populations
    vaccine_model.distribute_vaccines_to_nodes(network, day=0)
    antiviral_model.distribute_antivirals_to_nodes(network, day=0)
    for node in network.nodes:
        vaccine_model.distribute_vaccines_to_population(node, day=0)
        if not antivirals_use_incident_entries:
            antiviral_model.distribute_antivirals_to_population(node, day=0)

    # Write initial conditions
    writer.write_csv(0, network) if writer.total_sims > 1 else writer.write_json(0, network)
    simulation_days.snapshot(network)

    # Iterate over each day, each node...
    for day in range(1, simulation_days.day+1):
        # Distribute vaccines from network stockpile to individual nodes and zero-out
        vaccine_model.distribute_vaccines_to_nodes(network, day)
        if not antivirals_use_incident_entries:
            antiviral_model.distribute_antivirals_to_nodes(network, day)

        # Run distributions, treatments, stockpiles, and disease simulation for each node
        for node in network.nodes:
            # Distribute current day's vaccines and modify node stockpiles
            vaccine_model.distribute_vaccines_to_population(node, day)

            # apply antivirals
            if not antivirals_use_incident_entries:
                antiviral_model.distribute_antivirals_to_population(node, day)

            # simulate one step
            disease_model.simulate(node, day, vaccine_model)

        if antivirals_use_incident_entries:
            antiviral_model.distribute_antivirals_to_nodes(network, day)
            for node in network.nodes:
                antiviral_model.distribute_antivirals_to_population(node, day)

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


# Each spawned worker receives an untouched model graph once, then copies it for
# each realization. Copying the graph together preserves internal references and
# prevents stockpiles/model state from leaking between realizations.
_worker_state = None


def _initialize_worker(state, loglevel):
    global _worker_state
    from baseclasses.Group import set_compartments

    # spawn starts a fresh interpreter; the parent's dynamic enum is not inherited.
    set_compartments(list(state[1].comp_index))
    _worker_state = state
    logging.basicConfig(level=loglevel, format=format_str)


def _run_realization(state, sim_id, seed, days, output_dir, total_sims, batch_num,
                     sharded=False):
    start_time = time.perf_counter()
    parameters, network, antiviral, vaccine, disease, travel = copy.deepcopy(state)
    disease.set_seed(seed)
    writer_class = RealizationWriter if sharded else Writer
    writer = writer_class(output_dir_path=output_dir, realization_index=sim_id,
                          total_sims=total_sims, batch_num=batch_num)
    try:
        run(Day(days), parameters, network, antiviral, vaccine, disease, travel, writer)
    finally:
        if sharded:
            writer.close()
    return sim_id, time.perf_counter() - start_time, writer.output_dir if sharded else output_dir


def _worker_realization(task):
    return _run_realization(_worker_state, *task, sharded=True)


def _accept_realization(result, output_dir, batch_num, sharded):
    """Only the parent writes shared network and timing CSVs."""
    sim_id, elapsed, staging = result
    output_dir = Path(output_dir)
    if sharded:
        staging = Path(staging)
        network_path = output_dir / f'network_batch-{batch_num}.csv'
        with (staging / 'network.csv').open(newline='') as source:
            with network_path.open('a', newline='') as target:
                header = next(source)
                if target.tell() == 0:
                    target.write(header)
                shutil.copyfileobj(source, target)
        # Existing node_.*_batch-*.csv ingestion reads these combined county rows.
        (staging / 'nodes.csv').replace(
            output_dir / f'node_realization-{sim_id}_batch-{batch_num}.csv')
        (staging / 'network.csv').unlink()
        staging.rmdir()
    csv_time_path = output_dir / f'simulation_times_batch-{batch_num}.csv'
    with csv_time_path.open('a', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=['sim_id', 'time_seconds'])
        if handle.tell() == 0:
            writer.writeheader()
        writer.writerow({'sim_id': sim_id, 'time_seconds': elapsed})
    logger.info('Completed realization %s in %.2f seconds', sim_id, elapsed)


def main(cli_args=None):
    """
    Main entry point to PandemicExerciseSimulator
    """
    args = cli_args if cli_args is not None else parse_args()
    logging.basicConfig(level=args.loglevel, format=format_str)
    logger.info(f'entered main loop')

    # Read input properties file
    # Can be pre-generated from template, or generated in GUI
    simulation_properties = InputProperties(args.input_filename)
    workers = choose_workers(simulation_properties.execution,
                             len(simulation_properties.realization_indices))
    sharded = simulation_properties.execution['mode'] == 'parallel' and len(simulation_properties.realization_indices) > 1
    if sharded:
        # Spawned interpreters read these before importing NumPy/BLAS.
        for name in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS',
                     'VECLIB_MAXIMUM_THREADS', 'NUMEXPR_NUM_THREADS'):
            os.environ[name] = '1'
    logger.warning('Execution mode=%s; realization workers=%s',
                   simulation_properties.execution['mode'], workers)

    # Also used for exporting day-by-day summary information
    realization_indices = simulation_properties.realization_indices
    realization_number = int(len(realization_indices))
    batch_num = simulation_properties.batch_num
    
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
    antiviral_parent = Antiviral(parameters)
    antiviral_model = antiviral_parent.get_child(simulation_properties.antiviral_model, network)

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

    # Create output directory
    executed_config = build_executed_config(
        simulation_properties=simulation_properties,
        parameters=parameters,
        disease_model=disease_model,
        travel_model=travel_model,
        npi_model=npis,
        antiviral_model=antiviral_model,
        vaccine_model=vaccine_model,
        node_count=network.get_number_of_nodes(),
        base_seed=base_seed,
        cli_args=args
    )

    executed_config['execution'] = {
        **simulation_properties.execution,
        'resolved_workers': workers,
        'output_layout': 'realization_csv' if sharded else 'legacy',
    }

    # Create output directory
    if simulation_properties.output_dir_path.upper() == "GENERATE":
        simulation_properties.output_dir_path = executed_config["output_dir_path"]
    os.makedirs(simulation_properties.output_dir_path, exist_ok=True)
    logger.info(f'Created output directory: {simulation_properties.output_dir_path}')

    if sharded:
        output = Path(simulation_properties.output_dir_path)
        if (any(output.glob(f'*batch-{batch_num}.*')) or
                (output / f'.realizations_batch-{batch_num}').exists()):
            raise FileExistsError('This batch already has output; use a new batch_num/output directory.')
        # Atomic reservation also rejects simultaneous parallel launches of a batch.
        (output / f'.realizations_batch-{batch_num}').mkdir()

    # Copy original input file to output directory with batch-specific name
    input_file_path = os.path.abspath(args.input_filename)
    copied_input_path = os.path.join(
        simulation_properties.output_dir_path,
        f"input_batch-{simulation_properties.batch_num}.json"
    )
    shutil.copyfile(input_file_path, copied_input_path)
    logger.info(f"Copied input file to: {copied_input_path}")

    # Write canonical input file based on resolved parameters actually used
    write_metadata_json(
        executed_config=executed_config,
        output_dir=simulation_properties.output_dir_path,
        batch_num=simulation_properties.batch_num,
        logger=logger
    )

    state = (parameters, network, antiviral_model, vaccine_model, disease_model, travel_model)
    tasks = [(r, child_seedseq[i], args.days, simulation_properties.output_dir_path,
              realization_number, batch_num) for i, r in enumerate(realization_indices)]
    if sharded:
        from concurrent.futures import ProcessPoolExecutor, as_completed
        from multiprocessing import get_context

        # spawn works on macOS and Linux without inheriting RNGs or open handles.
        # Completion order never determines a realization's random seed.
        with ProcessPoolExecutor(max_workers=workers, mp_context=get_context('spawn'),
                                 initializer=_initialize_worker,
                                 initargs=(state, args.loglevel)) as pool:
            futures = [pool.submit(_worker_realization, task) for task in tasks]
            try:
                for future in as_completed(futures):
                    _accept_realization(future.result(), simulation_properties.output_dir_path,
                                        batch_num, sharded=True)
            except BaseException:
                for future in futures:
                    future.cancel()
                raise
        (Path(simulation_properties.output_dir_path) / f'.realizations_batch-{batch_num}').rmdir()
    else:
        for task in tasks:
            result = _run_realization(state, *task)
            _accept_realization(result, simulation_properties.output_dir_path, batch_num, sharded=False)
    return


if __name__ == '__main__':
    main()
