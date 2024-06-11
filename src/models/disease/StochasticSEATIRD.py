#!/usr/bin/env python3
from copy import deepcopy
import logging
import numpy as np

from .DiseaseModel import DiseaseModel
from .StochasticEvent import StochasticEvent
from baseclasses.Group import Group, RiskGroup, VaccineGroup, Compartments

logger = logging.getLogger(__name__)


class StochasticSEATIRD(DiseaseModel):

    def __init__(self, disease_model):
        self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters
        self.compartments = None
        self.mtrand = None

        logger.info(f'instantiated StochasticSEATIRD object with stochastic={self.is_stochastic}')
        logger.debug(f'{self.parameters}')
        return




    def simulate(self, node, time, parameters):
        """
        Main simulation logic for stochastic SEATIRD model
        """
        logger.debug(f'node={node}, time={time}')

        # grab PHA info

        self.now = time
        t_max = self.now + 1
        group_cache = np.zeros((self.parameters.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))
        self._demographic_sizes(node, group_cache)
        initial_compartments = deepcopy(node.compartments)

        while (len(node.events)) > 0 and (node.events[-1].time < t_max):
            _next_event(node, group_cache, initial_compartments)

        self.now = t_max
        return



    def count(self, compartments, group):
        #int count(PopulationCompartments::RefPtr C, GROUP g) {
        #    return C->demographicTotal(g);
        #}
        pass

    def epidemic_size(self):
        #return C->recoveredTotal() + C->deceasedTotal();
        pass

    def reinitialize_events(self, node):
        pass

    def transmit_disease(self, node, group, group_size_cache):
        pass

    def is_susceptible(self, x, group):
        # if (C->susceptible(g.age, g.risk, g.vaccinated) >= x) return true;
        # else return false;
        pass


    def _demographic_sizes(self, node, group_cache):
        """
        Given a node, calculate demographic percentages and fill a given cache
        """
        this_population = node.total_population()
        for i in range(self.parameters.number_of_age_groups):
            for j in range(len(RiskGroup)):
                for k in range(len(VaccineGroup)):
                    group = Group(i, j, k)
                    group_cache[i][j][k] = node.demographic_population(group) / this_population
        return


    def _next_event(self, node, group_cache, initial_compartments):
        """
        Grab the next event (last thing in the list) and act on it
        """
        this_event = deepcopy(node.events.pop())
        this_time = this_event.time
        this_type = this_event.type

        if this_type == 'EtoA':
            #_transition( COMPARTMENTS_EXPOSED, COMPARTMENTS_ASYMPTOMATIC, this_event.from )
            _transition(Compartments.E.value, Compartments.A.value, this_event.origin)
            
            pass

        elif this_type == 'AtoT':
            #_transition( COMPARTMENTS_ASYMPTOMATIC, COMPARTMENTS_TREATABLE, this_event.from )
            pass

        elif this_type == 'AtoR':
            #_transition( COMPARTMENTS_ASYMPTOMATIC, COMPARTMENTS_RECOVERED, this_event.from )
            pass

        elif this_type == 'AtoD':
            #_transition( COMPARTMENTS_ASYMPTOMATIC, COMPARTMENTS_DECEASED, this_event.from )
            pass

        elif this_type == 'TtoI':
            #if _keep_event( node, COMPARTMENTS_TREATABLE, this_event, initial_compartments ):
            #    _transition( COMPARTMENTS_TREATABLE, COMPARTMENTS_INFECTIOUS, this_event.from )
            #else: 
            #    _unqueue_event( node, COMPARTMENTS_INFECTIOUS, this_event.from )
            pass

        elif this_type == 'TtoR':
            #if _keep_event( node, COMPARTMENTS_TREATABLE, this_event, initial_compartments ):
            #    _transition( COMPARTMENTS_TREATABLE, COMPARTMENTS_RECOVERED, this_event.from )
            pass

        elif this_type == 'TtoD':
            #if _keep_event( node, COMPARTMENTS_TREATABLE, this_event, initial_compartments ):
            #    _transition( COMPARTMENTS_TREATABLE, COMPARTMENTS_DECEASED, this_event.from )
            pass

        elif this_type == 'ItoR':
            #if _keep_event( node, COMPARTMENTS_INFECTIOUS, this_event, initial_compartments ):
            #    _transition( COMPARTMENTS_INFECTIOUS, COMPARTMENTS_RECOVERED, this_event.from )
            pass

        elif this_type == 'ItoD':
            #if _keep_event( node, COMPARTMENTS_INFECTIOUS, this_event, initial_compartments ): 
            #   _transition( COMPARTMENTS_INFECTIOUS, COMPARTMENTS_DECEASED, this_event.from )
            pass

        else:
            #if _keep_contact( node, this_event.from ):
            #    GROUP to = this_event.to;
            #    int target_pop_size = node->demographicTotal(to);
            #    if (this_event.from == to):
            #        target_pop_size -= 1; // - 1 because randint includes both endpoints

            #    if (target_pop_size > 0):
            #        int contact = _rand_int(1, target_pop_size);

            #        if is_susceptible(contact, to):
            #            transmit_disease(node, to, group_cache);
            pass

        return


    def _transition(self, old_compartment, new_compartment, group):
        node.compartments.decrement(group, old_compartment)
        node.compartments.increment(group, new_compartment)
        return










