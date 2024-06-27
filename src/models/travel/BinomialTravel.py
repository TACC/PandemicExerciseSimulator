#!/usr/bin/env python3
from copy import deepcopy
import logging
import numpy as np
from typing import Type

from .TravelModel import TravelModel
from models.disease.DiseaseModel import DiseaseModel
from baseclasses.Group import RiskGroup, VaccineGroup, Compartments, Group
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network

logger = logging.getLogger(__name__)


# TODO take out this hardcoded value
RHO = 0.39  # hardcoded in C++ - percentage of how many are travelling from group to group?

class BinomialTravel(TravelModel):

    def __init__(self):
        self.rng = np.random.default_rng()
        logger.info(f'instantiated a BinomialTravel object: {BinomialTravel}')
        return


    def __str__(self):
        return(f'BinomialTravel')


    def travel(self, network:Type[Network], disease_model:Type[DiseaseModel], parameters:Type[ModelParameters], time:int):
        """
        Simulate travel between nodes. "Sink" refers to the Node where people travel to; "Source"
        refers to the Node where people travel from.

        Args:
            network (Network): Network object containing list of Nodes
            disease_model (DiseaseModel): Model used for exposing new people following travel
            parameters (ModelParameters): simulation parameters
            time (int): the current day
        """
        logging.info('entered travel function')

        network_copy = deepcopy(network)
        logging.debug(f'network.nodes len = {len(network.nodes)} first_val = {network.nodes[0].node_id}')
        logging.debug(f'network_copy.nodes len = {len(network_copy.nodes)} first_val = {network_copy.nodes[0].node_id}')

        for node_sink_id, node_sink in enumerate(network.nodes):
            unvaccinated_probabilities = [0.0] * parameters.number_of_age_groups
            age_based_flow_reduction = [1.0] * parameters.number_of_age_groups
            age_based_flow_reduction[0] = 10 # 0-4 year olds
            age_based_flow_reduction[1] = 2  # 5-24 year olds
            age_based_flow_reduction[4] = 2  # 65+ year olds

            logging.debug(f'length of network = {len(network.nodes)}')
            logging.debug(f'travel flow data size = {len(network.travel_flow_data)} x {len(network.travel_flow_data[0])}')

            for node_source_id, node_source in enumerate(network_copy.nodes):
                
                if node_sink_id != node_source_id:
                    flow_sink_to_source = network.travel_flow_data[node_sink_id][node_source_id]
                    flow_source_to_sink = network.travel_flow_data[node_source_id][node_sink_id]

                    if flow_sink_to_source > 0 or flow_source_to_sink > 0:

                        logging.debug(f'flow happening; sink id = {node_sink_id}, source id = {node_source_id}')
                        logging.debug(f'flow sink value = {flow_sink_to_source}, flow source value = {flow_source_to_sink}')
                        for ag1 in range(parameters.number_of_age_groups):

                            number_of_infectious_contacts_sink_to_source = 0
                            number_of_infectious_contacts_source_to_sink = 0
                            this_sigma = float(parameters.relative_susceptibility[ag1])
                            this_beta_baseline = parameters.beta

                            # TODO incorporate PHA bits to modify value of beta
                            # pha_effectiveness = params.pha_effectiveness (list)
                            # pha_halflife = params.pha_halflife (list)
                            # pha_age = float('inf') if time < parameters.pha_day else time - parameters pha_day
                            #if (PHA_effectiveness.size() > a && PHA_halflife.size() > a && PHA_halflife[a] > 0) {
                            #     beta = BETA_BASELINE * (1.0 - PHA_effectiveness[a] * pow(2, -PHA_age/PHA_halflife[a]) );
                            beta = this_beta_baseline
                            #}

                            for ag2 in range(parameters.number_of_age_groups):
                                asymptomatic = node_source.compartments.asymptomatic_population_by_age(ag2)
                                transmitting = node_source.compartments.transmitting_population_by_age(ag2) # asymptomatic, treatable, and infectious
                                contact_rate = parameters.np_contact_matrix[ag1][ag2] # age group to age group contacts

                                # TODO these don't make sense - why looking at transmitting for one direction and asymptomatic for the other?
                                logging.debug(f'asymptomatic = {asymptomatic}, transmitting = {transmitting}, contact_rate = {contact_rate}')
                                number_of_infectious_contacts_sink_to_source += transmitting * beta * RHO * contact_rate * this_sigma / age_based_flow_reduction[ag1]
                                number_of_infectious_contacts_source_to_sink += asymptomatic * beta * RHO * contact_rate * this_sigma / age_based_flow_reduction[ag2]

                            unvaccinated_probabilities[ag1] += flow_sink_to_source * number_of_infectious_contacts_sink_to_source / node_source.total_population()
                            unvaccinated_probabilities[ag1] += flow_source_to_sink * number_of_infectious_contacts_source_to_sink / node_sink.total_population()

                    logging.debug(f'unvaccinated_probabilities = {unvaccinated_probabilities}')

            vaccine_effectiveness = parameters.vaccine_effectiveness
            for ag in range(parameters.number_of_age_groups):
                for rg in range(len(RiskGroup)):
                    for vg in range(len(VaccineGroup)):

                        prob = 0.0
                        if vg == VaccineGroup.V.value:
                            prob = (1-vaccine_effectiveness[ag]) * unvaccinated_probabilities[ag]
                        else:
                            prob = unvaccinated_probabilities[ag]

                        # TODO what is this continuity correction?
                        sink_S =int( node_sink.compartments.compartment_data[ag][rg][vg][Compartments.S.value] + 0.5 ) # continuity correction
                        number_of_exposures = self.rng.binomial(sink_S, prob)
                        logging.debug(f'susceptible people in sink = {sink_S}, probability = {prob}, number_of_exposures = {number_of_exposures}')

                        group = Group(ag, rg, vg)
                        disease_model.expose_number_of_people(node_sink, group, number_of_exposures)






    