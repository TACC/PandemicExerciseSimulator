#!/usr/bin/env python3
from copy import deepcopy
import logging
import numpy as np
import numpy.typing as npt
from typing import Type

from .DiseaseModel import DiseaseModel
from src.baseclasses.Event import EventType
from src.baseclasses.Group import Group, RiskGroup, VaccineGroup, Compartments
from src.baseclasses.ModelParameters import ModelParameters
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions
from src.models.treatments.Vaccination import Vaccination
from src.utils.RNGMath import rand_exp, rand_int, rand_mt, rand_exp_min1

logger = logging.getLogger(__name__)


class Schedule:

    def __init__(self, disease_model:type[DiseaseModel], now:float, group:Type[Group]):
        """
        TAU      # Latency period in days (exposed to asymptomatic)
        KAPPA    # Asymptomatic infectious period in days (asymptomatic to treatable)
        CHI      # Treatable infectious period in days (treatable to infectious)
        GAMMA    # Total infectious period in days (asymptomatic/treatable/infectious to recovered)
        NU       # Mortality rate in 1/days (asymptomatic/treatable/infectious to deceased)

        self._Ta         # Time from exposed to asymptomatic
        self._Tt         # Time from asymptomatic to treatable
        self._Ti         # Time from treatable to infectious
        self._Td_a       # Time from asymptomatic to death
        self._Td_ti      # Time from treatable/infectious to death
        self._Tr_a       # Time from asymptomatic to recovered
        self._Tr_ti      # Time from treatable/infectious to recovered
        self._Trd_ati    # Time from A/T/I to R/D
        """

        self._Ta    = rand_exp_min1(disease_model.tau) + now
        self._Tt    = rand_exp_min1(disease_model.kappa) + self._Ta
        self._Ti    = disease_model.chi + self._Tt
        self._Td_a  = rand_exp_min1(disease_model.nu_values[group.age][group.risk]) + self._Ta
        self._Td_ti = rand_exp_min1(disease_model.nu_values[group.age][group.risk]) + self._Tt
        self._Tr_a  = rand_exp_min1(disease_model.gamma) + self._Ta
        self._Tr_ti = rand_exp_min1(disease_model.gamma) + self._Tt

        # exit_asymptomatic_time means via recovery or death, not progression to symptomatic stage
        self.exit_asymptomatic_time = min(self._Td_a, self._Tr_a)
        if (self._Tt < self.exit_asymptomatic_time): self.exit_asymptomatic_time = float('inf')
        self.exit_infectious_time = min(self._Td_ti, self._Tr_ti)

        self._Trd_ati = min(self.exit_asymptomatic_time, self.exit_infectious_time)

        return
       

    def update(self, disease_model:type[DiseaseModel], now:float, group:Type[Group], compartment_num:int):
        """
        Used only when reinitializing events (e.g. deterministic to stochastic transition)
        S=0, E=1, A=2, T=3, I=4, R=5, D=6
        """
        assert int(compartment_num) > 0 and int(compartment_num) < 5
        self._Ta    = (rand_exp_min1(disease_model.tau) + now) if compartment_num < 2 else now
        self._Tt    = (rand_exp_min1(disease_model.kappa) + self._Ta) if compartment_num < 3 else self._Ta
        self._Ti    = (self._Tt + disease_model.chi) if compartment_num < 4 else self._Tt
        self._Td_a  = (rand_exp_min1(disease_model.nu_values[group.age][group.risk])) + self._Ta if compartment_num < 3 else float('inf')
        self._Td_ti = rand_exp_min1(disease_model.nu_values[group.age][group.risk]) + self._Tt
        self._Tr_a  = (rand_exp_min1(disease_model.gamma)) if compartment_num < 3 else float('inf')
        self._Tr_ti = rand_exp_min1(disease_model.gamma) + self._Tt
        
        self.exit_asymptomatic_time = min(self._Td_a, self._Tr_a)
        if (self._Tt < self.exit_asymptomatic_time): self.exit_asymptomatic_time = float('inf')
        self.exit_infectious_time = min(self._Td_ti, self._Tr_ti)

        self._Trd_ati = min(self.exit_asymptomatic_time, self.exit_infectious_time)

        return


    def Ta(self):      return(self._Ta)
    def Tt(self):      return(self._Tt)
    def Ti(self):      return(self._Ti)
    def Td_a(self):    return(self._Td_a)
    def Td_ti(self):   return(self._Td_ti)
    def Tr_a(self):    return(self._Tr_a)
    def Tr_ti(self):   return(self._Tr_ti)
    def Trd_ati(self): return(self._Trd_ati)



class StochasticSEATIRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]):
        #self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters
        
        self.R0             = float(self.parameters.disease_parameters['R0'])
        self.beta_scale     = float(self.parameters.disease_parameters['beta_scale'] )   # "R0CorrectionFactor"
        self.beta           = self.R0 / self.beta_scale

        # the following four parameters are provided by users as periods (units = days),
        # but then stored here as rates (units = 1/days)
        self.tau            = 1/float(self.parameters.disease_parameters['tau'])
        self.kappa          = 1/float(self.parameters.disease_parameters['kappa'])
        self.gamma          = 1/float(self.parameters.disease_parameters['gamma'])
        self.chi            = 1/float(self.parameters.disease_parameters['chi'])

        # Mobility reduction parameter
        #self.rho            = float(simulation_properties.rho)
        #self.rho = 0.39 # this should be in travel model


        # the user enters one nu value for each age group, assumed to be low risk
        # population. use multiplier 9x to derive values for high risk population
        self.nu_values      = [[],[]]
        self.nu_values[0]   = [float(x)   for x in self.parameters.disease_parameters['nu']]
        self.nu_values[1]   = [float(x)*9 for x in self.parameters.disease_parameters['nu']]

        # transpose nu_values so that we can access values in the order we are used to
        #   e.g.:    nu_values[age][risk]
        self.nu_values = np.array(self.nu_values).transpose().tolist()

        self.relative_susceptibility = []
        self.relative_susceptibility = [float(x) for x in self.parameters.disease_parameters['sigma']]

        self.npis_schedule = disease_model.npis_schedule

        logger.info(f'instantiated StochasticSEATIRD object')
        logger.debug(f'{self.parameters}')
        return


    def simulate(self, node:Type[Node], time:int, vaccine_model:Type[Vaccination]):
        """
        Main simulation logic for stochastic SEATIRD model

        Args:
            node (Node): Movement between compartments happens within the given node
            time (int): Simulation day
        """
        logger.debug(f'node={node}, time={time}')

        self.now = time
        t_max = self.now + 1
        #group_cache = np.zeros((self.parameters.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))
        #self._demographic_sizes(node, group_cache)
        group_cache = node.group_cache
        initial_compartments = deepcopy(node.compartments)

        node.events.sort(key=lambda x: x.time, reverse=True)

        #if node.node_id == 1:
        #    logging.debug(f'PRE EVENT LENGTH = {len(node.events)}, t_max = {t_max}')
        #    for item in node.events:
        #        logging.debug(f'EVENT: init_time={item.init_time}, time={item.time}')

        while (len(node.events)) > 0 and (node.events[-1].time < t_max):
            self._next_event(node, group_cache, initial_compartments, vaccine_model)

        self.now = t_max

        #if node.node_id == 1:
        #    logging.debug(f'POST EVENT LENGTH = {len(node.events)}, t_max = {t_max}')
        #    for item in node.events:
        #        logging.debug(f'EVENT: init_time={item.init_time}, time={item.time}')

        return


    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int, vaccine_model:Type[Vaccination]):
        """
        Initial infected are moved from 'Susceptible' into 'Exposed' compartment and drawn their schedule of events
        Args:
            node (Node): The node where people will be exposed
            group (Group): Compartment descriptor including age group, risk group, vaccine status
            num_to_expose (int): The number of people to expose
        """
        group_cache = node.group_cache
        current_susceptible = int(node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value])
        logging.debug(f'current_susceptible={current_susceptible}')

        for _ in range(min(num_to_expose, current_susceptible)):
            self._transmit_disease(node, group, group_cache, vaccine_model)
        return


    def reinitialize_events(self, node:Type[Node]):
        """
        Used for transition from deterministic to stochastic computation. Not currently implemented
        """
        pass


    ###### Private Methods ######
    def _transmit_disease(self, node:Type[Node], group:Type[Group], group_cache:npt.ArrayLike, vaccine_model:Type[Vaccination]):
        """
        Given a node and a group, move one individual from 'Susceptible' to 'Exposed'. Then, since a
        new individual has been exposed, initialize exposed transitions and contact events
        """
        assert(node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] > 0)
        self._transition(node, Compartments.S.value, Compartments.E.value, group)

        schedule = Schedule(self, self.now, group)
        self._initialize_exposed_transitions(node, group, schedule)
        self._initialize_contact_events(node, group, schedule, group_cache, vaccine_model)
        return


    def _transition(self, node:Type[Node], old_compartment:int, new_compartment:int, group:Type[Group]):
        """
        Given a node, a group, and two compartments (old and new), use the methods in the 
        PopulationCompartments class to move one individual
        """
        node.compartments.decrement(group, old_compartment)
        node.compartments.increment(group, new_compartment)
        return


    def _initialize_exposed_transitions(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule]):
        """
        When an individual moves into Exposed, queue a new EtoA event
        """
        node.add_transition_event(self.now, schedule.Ta(), EventType.EtoA.name, group)
        self._initialize_asymptomatic_transitions(node, group, schedule)
        return


    def _initialize_asymptomatic_transitions(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule]):
        """
        When an individual moves into Asymptomatic, they can either move to Treatable, Recovered, or
        Deceased based on given Schedule
        """
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
        """
        When an individual moves into Treatable, they can either move to Infectious, Recovered, or 
        Deceased based on given Schedule
        """
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
        """
        When an individual moves into Infectious, then can either move to Recovered or Deceased
        based on given Schedule
        """
        if (schedule.Tr_ti() < schedule.Td_ti()):
            # individual will recover from infectious
            node.add_transition_event(schedule.Ti(), schedule.Tr_ti(), EventType.ItoR.name, group)
        else:
            # individual will die from infectious
            node.add_transition_event(schedule.Ti(), schedule.Td_ti(), EventType.ItoD.name, group)
        return


    def _initialize_contact_events(self, node:Type[Node], group:Type[Group], schedule:Type[Schedule], 
                                   group_cache:npt.ArrayLike, vaccine_model:Type[Vaccination]):
        """
        This method is called when exposing Susceptible individuals for the first time. The exposed
        individual contacts other susceptible individuals and queues new contact events.
        """
        beta = self._calculate_beta_w_npi(node.node_index, node.node_id)

        for ag in range(self.parameters.number_of_age_groups):
            sigma = float(self.relative_susceptibility[ag])

            for rg in range(len(RiskGroup)):
                for vg in range(len(VaccineGroup)):
                    to = Group(ag, rg, vg)
                    contact_rate = float(self.parameters.np_contact_matrix[group.age][to.age])

                    # If no one is vaccinated, then the transmission rate for vaccine group is 0 and
                    # causes runtime warning divide by zero error in the rand_exp step
                    # TODO dig in to what is expected behavior of this method when group size is 0
                    if (group_cache[ag][rg][vg] == 0): continue
                    
                    # TODO we should really only be using vaccine_effectiveness[] in this 
                    # Cannot have vaccine effectiveness hitting beta unless in vaccinated group
                    if vg == 1:  # vaccinated then get effectiveness by age group
                        vaccine_effectiveness =  vaccine_model.vaccine_effectiveness[ag]
                    else:  # if you're not vaccinated, it has no effectiveness
                        vaccine_effectiveness = 0
                    # group_cache is weighting the force of infection
                    transmission_rate = (1.0 - vaccine_effectiveness) * beta[ag] * contact_rate \
                                        * sigma * group_cache[ag][rg][vg]
                    # if the rate is zero (VE=1 or other reasons), do not schedule contacts
                    if transmission_rate <= 0.0:
                        continue

                    Tc_init = schedule.Ta()
                    Tc = rand_exp_min1(transmission_rate) + Tc_init

                    while (Tc < schedule.Trd_ati()):
                        node.add_contact_event(Tc_init, Tc, EventType.CONTACT, group, to)
                        Tc_init = Tc
                        Tc = rand_exp_min1(transmission_rate) + Tc_init
        return

    def _next_event(self, node:Type[Node], group_cache:npt.ArrayLike, initial_compartments:Type[PopulationCompartments],
                    vaccine_model:Type[Vaccination]):
        """
        Grab the next event from the queue (last thing in the list) and act on it
        """
        if not node.events: return # if list of events is empty, return from this method

        this_event = deepcopy(node.events.pop())
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

        else: # this_type == 'CONTACT':
            if (self._keep_contact(node, this_event.origin)):
                to = this_event.destination
                target_pop_size = node.compartments.demographic_population(to)

                if (this_event.origin == to):
                    target_pop_size -= 1 

                #if (target_pop_size > 0): 
                if (target_pop_size > 1):

                    contact = rand_int(1, target_pop_size)

                    if (self._is_susceptible(node, to, contact)):
                        self._transmit_disease(node, to, group_cache, vaccine_model)
        return


    def _keep_event(self, node:Type[Node], compartment:int, event:Type[EventType],
                    initial_compartments:Type[PopulationCompartments]) -> bool:
        """
        Stochastic check to see whether an event occurs
        """
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


    def _unqueue_event(self, node:Type[Node], compartment:int, group:Type[Group]):
        """
        An event was discarded so increment the counter
        """
        node.unqueued_event_counter[group.age][group.risk][group.vaccine][compartment] += 1
        return


    def _keep_contact(self, node:Type[Node], group:Type[Group]) -> bool:
        """
        If the ratio of unqueued contact counts to total contact counts for this group is low,
        then keep the contact
        """
        contact_count = node.contact_counter[group.age][group.risk][group.vaccine]
        unqueued_contact_count = node.unqueued_contact_counter[group.age][group.risk][group.vaccine]

        if (contact_count > 0):
            # occasionally getting a divide by zero error on this line 
            if (rand_mt() > float(unqueued_contact_count) / float(contact_count)):
                node.contact_counter[group.age][group.risk][group.vaccine] -= 1
                return True
        node.unqueued_contact_counter[group.age][group.risk][group.vaccine] -= 1
        node.contact_counter[group.age][group.risk][group.vaccine] -= 1
        return False


    def _is_susceptible(self, node:Type[Node], group:Type[Group], num:int) -> bool:
        """
        Return True if the size of the Susceptible compartment is greater than the input num
        """
        if (node.compartments.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] > num):
            return True
        else:
            return False