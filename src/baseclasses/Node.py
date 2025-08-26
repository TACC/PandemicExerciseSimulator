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

    def __init__(self, node_index:int, node_id:int, fips_id:int, compartments:Type[PopulationCompartments]):
        self.node_index = node_index
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
        data['node_index'] = str(self.node_index)
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
        data = {}
        data['node_index'] = str(self.node_index)
        data['node_id']    = str(self.node_id)
        data['fips_id']    = str(self.fips_id)

        # TODO collect travel exposure data for the output
        data['travel_exposure'] = []
        data['compartment_summary'] = {}
        data['compartment_summary_percent'] = {}

        # Use enum compartment labels + totals vector
        labels = [c.name for c in Compartments]  # order must match last axis of compartment_data
        vec = np.asarray(self.compartments.get_disease_compartment_sum(), dtype=float)  # shape: [comp]

        # Per-node totals, keyed by compartment name
        data['compartment_summary'] = {lab: float(val) for lab, val in zip(labels, vec)}

        # Percent by compartment
        total = float(vec.sum())
        if total > 0.0:
            data['compartment_summary_percent'] = {
                lab: round(data['compartment_summary'][lab] / total * 100.0, 2) for lab in labels
            }
        else:
            data['compartment_summary_percent'] = {lab: 0.0 for lab in labels}

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

