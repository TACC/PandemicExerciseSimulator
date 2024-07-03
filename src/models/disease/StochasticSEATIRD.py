#!/usr/bin/env python3
from copy import deepcopy
import logging
import math
import numpy as np
from typing import Type

from .DiseaseModel import DiseaseModel
from .StochasticSEATIRDUtils import EventType, StochasticEvent, Schedule
from baseclasses.Group import Group, RiskGroup, VaccineGroup, Compartments
from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node
from utils.RNGMath import rand_exp, rand_int, rand_mt


logger = logging.getLogger(__name__)


class StochasticSEATIRD(DiseaseModel):

    def __init__(self, disease_model):
        self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters

        logger.info(f'instantiated StochasticSEATIRD object with stochastic={self.is_stochastic}')
        logger.debug(f'{self.parameters}')
        return


    def set_initial_conditions(self, initial:list, network:Type[Network]):
        """
        Method called 

        Args:
            initial (list): list of initial infected per age group per county from INPUT
            network (Network): network object with list of nodes
        """
        for item in initial['v']:
            # TODO the word "county" is hardcoded here but should be made dynamic in case
            # people want to do zip codes instead
            this_node_id = int(item['county'])
            this_infected = int(item['infected'])
            this_age_group = int(item['age_group'])

            group = Group(this_age_group, RiskGroup.L.value, VaccineGroup.U.value)

            for node in network.nodes:
                if node.node_id == this_node_id:
                    self.expose_number_of_people(node, group, this_infected)
        return


    # why are we sending ModelParameters into this method since self.parameters is part of class?
    def simulate(self, node:Type[Node], time:int, parameters:Type[ModelParameters]):
        """
        Main simulation logic for stochastic SEATIRD model
        """
        logger.debug(f'node={node}, time={time}')

        # TODO grab PHA info

        self.now = time
        t_max = self.now + 1
        group_cache = np.zeros((self.parameters.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))
        self._demographic_sizes(node, group_cache)
        initial_compartments = deepcopy(node.compartments)

        while (len(node.events)) > 0 and (node.events[-1].time < t_max):
            self._next_event(node, group_cache, initial_compartments)

        self.now = t_max
        return


    def epidemic_size(self):
        #return C->recoveredTotal() + C->deceasedTotal();
        pass


    def reinitialize_events(self, node):
        pass


    def _is_susceptible(self, node, group, num):
        if (node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] > num):
            return True
        else:
            return False


    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int):
        """
        Initial infected should be moved into 'Exposed' compartment
        """

        group_cache = np.zeros((self.parameters.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))
        self._demographic_sizes(node, group_cache)
        for i in range(num_to_expose):
            self._transmit_disease(node, group, group_cache)

        return


    def _transmit_disease(self, node, group, group_cache):

        assert(node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] > 0)


        # TODO the num_to_expose value should be the min of {num_to_expose, current susceptible}
        #node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] -= 1
        #node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.E.value] += 1
        self._transition(node, Compartments.S.value, Compartments.E.value, group)

        # Is there any reason to put this functionality in the PopulationCompartments class?
        #node.compartments.expose_number_of_people(group.age, group.risk, group.vaccine)

        schedule = Schedule(self.parameters, self.now, group)
        self._initialize_exposed_transitions(node, group, schedule)
        self._initialize_contact_events(node, group, schedule, group_cache)

        return


    def _initialize_exposed_transitions(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule]):
        node.add_transition_event(self.now, schedule.Ta(), EventType.EtoA.name, group)
        self._initialize_asymptomatic_transitions(node, group, schedule)
        return
    

    def _initialize_asymptomatic_transitions(self, node, group, schedule):
        if (schedule.Tt() < schedule.Td_a() and schedule.Tt() < schedule.Tr_a()):
            # individual will progress from asymptomatic to treatable
            node.add_transition_event(schedule.Ta(), schedule.Tt(), EventType.AtoT.name, group)
            self._initialize_treatable_transitions(node, group, schedule)
        elif (schedule.Tr_a() < schedule.Td_a()):
            # individual will recover from asymptomatic
            node.add_transition_event(schedule.Ta(), schedule.Tr_a(), EventType.AtoR.name, group)
        else:
            # individual will die while asymptomatic
            node.add_transition_event(schedule.Ta(), schedule.Td_a(), EventType.AtoD.name, group)
        return


    def _initialize_treatable_transitions(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule]):
        if (schedule.Ti() < schedule.Td_ti() and schedule.Ti() < schedule.Tr_ti()):
            # individual will progress from treatable to infectious
            node.add_transition_event(schedule.Tt(), schedule.Ti(), EventType.TtoI.name, group)
            self._initialize_infectious_transitions(node, group, schedule)
        elif (schedule.Tr_ti() < schedule.Td_ti()):
            # individual will recover while treatable
            node.add_transition_event(schedule.Tt(), schedule.Tr_ti(), EventType.TtoR.name, group)
        else:
            # individual will die while treatable
            node.add_transition_event(schedule.Tt(), schedule.Td_ti(), EventType.TtoD.name, group)
        return


    def _initialize_infectious_transitions(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule]):
        if (schedule.Tr_ti() < schedule.Td_ti()):
            # individual will recover from infectious
            node.add_transition_event(schedule.Ti(), schedule.Tr_ti(), EventType.ItoR.name, group)
        else:
            # individual will die from infectious
            node.add_transition_event(schedule.Ti(), schedule.Td_ti(), EventType.ItoD.name, group)
        return


    def _initialize_contact_events(self, node, group, schedule, group_cache):
        beta = self._calculate_beta_w_pha() # this is a list
        vaccine_effectiveness = self.parameters.vaccine_effectiveness  # this is a list

        for ag in range(self.parameters.number_of_age_groups):
            sigma = float(self.parameters.relative_susceptibility[ag])
            for rg in range(len(RiskGroup)):
                for vg in range(len(VaccineGroup)):
                    to = Group(ag, rg, vg)
                    contact_rate = float(self.parameters.np_contact_matrix[group.age][to.age])
                    # If noone is vaccinated, then the transmission rate for vaccine group is 0 and causes runtime warning
                    # divide by zero eror in the rand_exp step
                    # TODO dig in to what is expected behavior of this method when group size is 0
                    if (group_cache[ag][rg][vg] == 0): continue
                    transmission_rate = ( 1.0 - float(vaccine_effectiveness[ag]) ) * beta[ag] * contact_rate * sigma * group_cache[ag][rg][vg]
                    Tc_init = schedule.Ta()
                    Tc = rand_exp(transmission_rate) + Tc_init

                    while (Tc < schedule.Trd_ati()):
                        node.add_contact_event(Tc_init, Tc, EventType.CONTACT, group, to)
                        Tc_init = Tc
                        Tc = rand_exp(transmission_rate) + Tc_init
        return


    def _calculate_beta_w_pha(self):
        # TODO fix these terms once we start account for PHA
        pha_effectiveness = [0.4, 0.4, 0.4, 0.4, 0.4]
        pha_halflife = [10.0, 10.0, 10.0, 10.0, 10.0]
        pha_day = 50

        pha_age = float('inf') if self.now < pha_day else self.now - pha_day
        beta_baseline =  self.parameters.beta
        age_group_size = self.parameters.number_of_age_groups
        beta = [beta_baseline] * age_group_size

        if (len(pha_effectiveness) == age_group_size and len(pha_halflife) == age_group_size):
            for ag in range(age_group_size):
                if (pha_halflife[ag] > 0):
                    beta[ag] = beta_baseline * (1.0 - pha_effectiveness[ag] * math.pow(2, -1*(pha_age/pha_halflife[ag])))

        return beta


    def _demographic_sizes(self, node, group_cache):
        """
        Given a node, calculate demographic percentages and fill a given cache
        """
        this_population = node.total_population()
        for i in range(self.parameters.number_of_age_groups):
            for j in range(len(RiskGroup)):
                for k in range(len(VaccineGroup)):
                    group = Group(i, j, k)
                    group_cache[i][j][k] = node.compartments.demographic_population(group) / this_population
        return


    def _next_event(self, node, group_cache, initial_compartments):
        """
        Grab the next event (last thing in the list) and act on it
        """
        # if list of events is empty, return from this method
        if not node.events: return


        this_event = deepcopy(node.events.pop())
        this_time = this_event.time
        this_type = this_event.event_type

        if this_type == 'EtoA':
            self._transition(node, Compartments.E.value, Compartments.A.value, this_event.origin)

        elif this_type == 'AtoT':
            self._transition(node, Compartments.A.value, Compartments.T.value, this_event.origin)

        elif this_type == 'AtoR':
            self._transition(node, Compartments.A.value, Compartments.R.value, this_event.origin)

        elif this_type == 'AtoD':
            self._transition(node, Compartments.A.value, Compartments.D.value, this_event.origin)

        elif this_type == 'TtoI':
            if self._keep_event(node, Compartments.T.value, this_event, initial_compartments):
                self._transition(node, Compartments.T.value, Compartments.I.value, this_event.origin)
            else:
                self._unqueue_event(node, Compartments.I.value, this_event.origin)

        elif this_type == 'TtoR':
            if self._keep_event(node, Compartments.T.value, this_event, initial_compartments):
                self._transition(node, Compartments.T.value, Compartments.R.value, this_event.origin)

        elif this_type == 'TtoD':
            if self._keep_event(node, Compartments.T.value, this_event, initial_compartments):
                self._transition(node, Compartments.T.value, Compartments.D.value, this_event.origin)

        elif this_type == 'ItoR':
            if self._keep_event(node, Compartments.I.value, this_event, initial_compartments):
                self._transition(node, Compartments.I.value, Compartments.R.value, this_event.origin)

        elif this_type == 'ItoD':
            if self._keep_event(node, Compartments.I.value, this_event, initial_compartments):
                self._transition(node, Compartments.I.value, Compartments.D.value, this_event.origin)

        else: # this_type == 'CONTACT'
            if (self._keep_contact(node, this_event.origin)):
                to = this_event.destination
                target_pop_size = node.compartments.demographic_population(to)

                if (this_event.origin == to):
                    target_pop_size -= 1 

                if (target_pop_size > 0):
                    contact = rand_int(1, target_pop_size)

                    if (self._is_susceptible(node, to, contact)):
                        self._transmit_disease(node, to, group_cache)
        
        return


    def _transition(self, node, old_compartment, new_compartment, group):
        node.compartments.decrement(group, old_compartment)
        node.compartments.increment(group, new_compartment)
        return


    def _keep_event(self, node, compartment, event, initial_compartments) -> bool:

        group = event.origin
        logging.debug(f'group = {group}')
        unqueued_event_count = node.unqueued_event_counter[group.age][group.risk][group.vaccine][compartment]
        
        if (compartment == Compartments.T.value and event.init_time == self.now):
            return True
        elif (unqueued_event_count == 0 or rand_mt() > unqueued_event_count / (unqueued_event_count \
                             + initial_compartments[group.age][group.risk][group.vaccine][compartment])):
            initial_compartments.compartment_data[group.age][group.risk][group.vaccine][compartment] -= 1
            return True
        else:
            node.unqueued_event_counter[group.age][group.risk][group.vaccine][compartment] -= 1
            return False


    def _unqueue_event(self, node, compartment, group):
        node.unqueued_event_counter[group.age][group.risk][group.vaccine][compartment] += 1
        return


    def _keep_contact(self, node, group) -> bool:

        contact_count = node.contact_counter[group.age][group.risk][group.vaccine]
        unqueued_contact_count = node.unqueued_contact_counter[group.age][group.risk][group.vaccine]

        if (contact_count > 0):
            # getting a divide by zero error on this line 
            if (rand_mt() > float(unqueued_contact_count) / float(contact_count)):
                node.contact_counter[group.age][group.risk][group.vaccine] -= 1
                return True

        node.unqueued_contact_counter[group.age][group.risk][group.vaccine] -= 1
        node.contact_counter[group.age][group.risk][group.vaccine] -= 1
        return False



