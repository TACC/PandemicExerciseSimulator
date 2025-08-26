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
from baseclasses.Node import Node
from utils.RNGMath import rand_binomial
from models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)


class BinomialTravel(TravelModel):

    def __init__(self, travel_model:Type[TravelModel]):
        self.parameters = travel_model.parameters
        
        # extract parameters
        self.rho = float(self.parameters.travel_parameters['rho'])
        self.flow_reduction = []
        self.flow_reduction = [float(x) for x in self.parameters.travel_parameters['flow_reduction']]

        logger.info(f'instantiated a BinomialTravel object: {BinomialTravel}')
        return


    def travel(self, network:Type[Network], disease_model:Type[DiseaseModel], parameters:Type[ModelParameters], time:int,
               vaccine_model:Type[Vaccination]):
        """
        Simulate travel between nodes. "Sink" refers to the Node where people travel to; "Source"
        refers to the Node where people travel from.

        Args:
            network (Network): Network object containing list of Nodes
            disease_model (DiseaseModel): Model used for exposing new people following travel
            parameters (ModelParameters): simulation parameters
            time (int): the current day
        """
        logging.debug('entered the travel function')
        logging.debug(f'network.nodes len = {len(network.nodes)} first_val = {network.nodes[0].node_id}')

        for node_sink_id, node_sink in enumerate(network.nodes):
            probabilities = [0.0] * parameters.number_of_age_groups

            for node_source_id, node_source in enumerate(network.nodes):
                if node_sink_id != node_source_id:
                    self._calculate_flow_probability(parameters, network, node_sink, node_sink_id,
                                                     node_source, node_source_id, probabilities,
                                                     disease_model)
                    logging.debug(f'probabilities = {probabilities}')

            self._expose_from_travel(parameters, node_sink, probabilities, disease_model, vaccine_model)
        return


    def _calculate_flow_probability(self, parameters:Type[ModelParameters], network:Type[Network], node_sink:Type[Node],
                                    node_sink_id:int, node_source:Type[Node], node_source_id:int, probabilities:list,
                                    disease_model:Type[DiseaseModel]):
        """
        Given a pair of nodes, (1) identify whether travel happens between the nodes (based on
        travel flow data), (2) if so, iterate over all pairs of age groups, (3) calculate number
        of infectious contacts that happen, (4) add those contacts as a fraction of total
        population to probabilities[].

        Args:
            parameters (ModelParameters): run parameters
            network (Network): Network object containing list of nodes and travel flow data
            node_sink (Node): travel destination
            node_sink_id (int): index for sink Node
            node_source (Node): travel origin
            node_source_id (int): index for source Node
            probabilities (list): probability of transmission by age
        """
        flow_sink_to_source = network.travel_flow_data[node_sink_id][node_source_id]
        flow_source_to_sink = network.travel_flow_data[node_source_id][node_sink_id]

        if flow_sink_to_source > 0 or flow_source_to_sink > 0:

            logging.debug(f'flow happening; sink id = {node_sink_id}, source id = {node_source_id}')
            logging.debug(f'flow sink value = {flow_sink_to_source}, flow source value = {flow_source_to_sink}')

            for ag1 in range(parameters.number_of_age_groups):
                number_of_infectious_contacts_sink_to_source = 0
                number_of_infectious_contacts_source_to_sink = 0
                this_sigma = float(disease_model.relative_susceptibility[ag1])
                this_beta_baseline = disease_model.beta

                # TODO incorporate PHA bits to modify value of beta
                # pha_effectiveness = params.pha_effectiveness (list)
                # pha_halflife = params.pha_halflife (list)
                # pha_age = float('inf') if time < parameters.pha_day else time - parameters pha_day
                #if (PHA_effectiveness.size() > a && PHA_halflife.size() > a && PHA_halflife[a] > 0) {
                #     beta = BETA_BASELINE * (1.0 - PHA_effectiveness[a] * pow(2, -PHA_age/PHA_halflife[a]) );
                beta = this_beta_baseline
                #}

                for ag2 in range(parameters.number_of_age_groups):
                    #asymptomatic = node_source.compartments.asymptomatic_population_by_age(ag2)
                    transmitting = node_source.compartments.transmitting_population_by_age(ag2) # asymptomatic, treatable, and infectious
                    contact_rate = parameters.np_contact_matrix[ag1][ag2] # age group to age group contacts
                    #logging.debug(f'asymptomatic = {asymptomatic}, transmitting = {transmitting}, contact_rate = {contact_rate}')

                    number_of_infectious_contacts_sink_to_source += transmitting * beta * self.rho * contact_rate \
                                                                    * this_sigma / self.flow_reduction[ag1]
                    #number_of_infectious_contacts_source_to_sink += asymptomatic * beta * self.rho * contact_rate \
                    #                                                * this_sigma / self.flow_reduction[ag2]
                    number_of_infectious_contacts_source_to_sink += beta * self.rho * contact_rate \
                                                                    * this_sigma / self.flow_reduction[ag2]


                probabilities[ag1] += flow_sink_to_source * number_of_infectious_contacts_sink_to_source \
                                                   / node_source.total_population()
                probabilities[ag1] += flow_source_to_sink * number_of_infectious_contacts_source_to_sink \
                                                   / node_sink.total_population()
        return


    def _expose_from_travel(self, parameters:Type[ModelParameters], node_sink:Type[Node], 
                            probabilities:list, disease_model:Type[DiseaseModel],
                            vaccine_model:Type[Vaccination]):
        """
        For each age group, risk group, and vaccine group in the sink Node, use a binomial function
        to determine the actual number of exposures in the Susceptible compartments. Expose those
        people using the Disease Model.

        Args:
            parameters (ModelParameters): run parameters
            node_sink (Node): travel destination
            probabilities (list): probability of transmission by age
            disease_model (DiseaseModel): Model used for exposing new people following travel
        """
        for ag in range(parameters.number_of_age_groups):
            for rg in range(len(RiskGroup)):
                for vg in range(len(VaccineGroup)):
                    prob = ((1-vaccine_model.vaccine_effectiveness[ag]) * probabilities[ag]) \
                        if vg == VaccineGroup.V.value else probabilities[ag]
                    
                    # TODO what is this continuity correction (+ 0.5)?
                    sink_S = int( node_sink.compartments.compartment_data[ag][rg][vg][Compartments.S.value] + 0.5 )
                    prob=max(min(prob,1.0), 0.0)
                    number_of_exposures = rand_binomial(sink_S, prob)
                    if number_of_exposures > 1:
                        logging.debug(f'susceptible people in sink = {sink_S}, probability = {prob}, '
                                      f'number_of_exposures = {number_of_exposures}')
                        
                    group = Group(ag, rg, vg)
                    disease_model.expose_number_of_people(node_sink, group, number_of_exposures, vaccine_model)
        return

    