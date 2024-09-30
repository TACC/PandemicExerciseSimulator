#!/usr/bin/env python3
import json
import logging
import numpy as np
from typing import Type

from .Event import Event, EventType
from .Group import Group, RiskGroup, VaccineGroup, Compartments
from .PopulationCompartments import PopulationCompartments

logger = logging.getLogger(__name__)


class Node:

    def __init__(self, node_id:int, fips_id:int, compartments:Type[PopulationCompartments]):
        self.node_id = node_id
        self.fips_id = fips_id
        self.compartments = compartments
        self.vaccine_stockpile = 0.
        self.antiviral_stockpile = 0.
        self.stochastic = True
        self.events = []    # list of event objects
        
        # the contact counter struct is a 3-dimensional array of ints
        # the fields are [number of age groups][risk group size][vaccinated group size]
        self.contact_counter = np.zeros(( self.compartments.number_of_age_groups, 
                                          len(RiskGroup),
                                          len(VaccineGroup)
                                       ))
        self.unqueued_contact_counter = np.zeros(( self.compartments.number_of_age_groups,
                                                   len(RiskGroup),
                                                   len(VaccineGroup)
                                                ))

        # the event counter struct is a 4-dimensional array of ints
        # the fields are [number of age groups][risk group size][vaccinated group size][compartments size]
        self.unqueued_event_counter = np.zeros(( self.compartments.number_of_age_groups,
                                                 len(RiskGroup),
                                                 len(VaccineGroup),
                                                 len(Compartments)
                                              ))
        logger.debug(f'instantiated Node object with ID: {self.node_id} and FIPS: {self.fips_id}')
        return

    def __str__(self) -> str:
        data={}
        data['node_id'] = str(self.node_id)
        data['fips_id'] = str(self.fips_id)
        data['compartments'] = f'{self.compartments}'
        return(json.dumps(data))


    def add_contact_event(self, init_time:float, time:float, event_type:Type[EventType],
                                group_origin:Type[Group], group_destination:Type[Group]):
        """
        Add a new contact event to the event queue

        Args:
            init_time (float): time when event was created
            time (float): time for event to happen
            event_type (EventType): type of event from a list of possible events
            group_origin (Group): group originating the event
            group_destination (Group): group destination for the event
        """
        self.events.insert(0, Event(init_time, time, event_type, group_origin, group_destination))
        self.contact_counter[group_origin.age][group_origin.risk][group_origin.vaccine] += 1
        logger.debug(f'added EventType={event_type} to queue; length={len(self.events)}')
        return


    def add_transition_event(self, init_time:float, time:float, event_type:Type[EventType],
                                   group:Type[Group]):
        """
        Add a new transition event to the event queue

        Args:
            init_time (float): time when event was created
            time (float): time for event to happen
            event_type (EventType): type of event from a list of possible events
            group (Group): group where event happened
        """
        self.events.insert(0, Event(init_time, time, event_type, group, group))
        logger.debug(f'added EventType={event_type} to queue; length={len(self.events)}')
        return


    def return_dict(self) -> dict:
        """
        Return dictionary representation of node object for easier printing
        """
        data={}
        data['node_id'] = str(self.node_id)
        data['fips_id'] = str(self.fips_id)

        # TODO collect travel exposure data for the output
        data['travel_exposure'] = []
        data['compartment_summary'] = {}
        data['compartment_summary_percent'] = {}
        # TODO put this back in when we start to use this output data
        #data['compartments'] = {}

        # TODO this is done elsewhere too, should be a function
        data['compartment_summary']['S'] = self.compartments.susceptible_population()
        data['compartment_summary']['E'] = self.compartments.exposed_population()
        data['compartment_summary']['A'] = self.compartments.asymptomatic_population()
        data['compartment_summary']['T'] = self.compartments.treatable_population()
        data['compartment_summary']['I'] = self.compartments.infectious_population()
        data['compartment_summary']['R'] = self.compartments.recovered_population()
        data['compartment_summary']['D'] = self.compartments.deceased_population()

        total = sum(data['compartment_summary'].values())
        for comp in Compartments:
            data['compartment_summary_percent'][comp.name] = \
                round(data['compartment_summary'][comp.name] / total * 100, 2)

        # TODO put this back in when we start to use this output data
        #for comp in Compartments:
        #    data['compartments'][comp.name] = { 'U':{}, 'V':{} }

        #    for vac in VaccineGroup:
        #        for risk in RiskGroup:
        #            data['compartments'][comp.name][vac.name][risk.name] = \
        #                self.compartments.return_list_by_age_group(comp.value, vac.value, risk.value)
        return(data)


    def total_population(self) -> float:
        """
        Return total population across all groups and compartments of Node
        """
        return self.compartments.total_population

