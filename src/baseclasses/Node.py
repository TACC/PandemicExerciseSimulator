#!/usr/bin/env python3
import json
import numpy as np
from typing import Type

from .Group import Group, RiskGroup, VaccineGroup, Compartments
from models.disease.StochasticSEATIRDUtils import StochasticEvent


class Node:

    def __init__(self, node_id:int, fips_id:int, compartments):
        self.node_id = node_id
        self.fips_id = fips_id
        self.compartments = compartments
        self.vaccine_stockpile = 0.
        self.antiviral_stockpile = 0.
        self.stochastic = True
        self.events = []    # list of stochastic event objects
        
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

    def __str__(self) -> str:
        data={}
        data['node_id'] = str(self.node_id)
        data['fips_id'] = str(self.fips_id)
        data['compartments'] = f'{self.compartments}'
        return(json.dumps(data))


    def add_contact_event(self, init_time:float, time:float, event_type:Type[StochasticEvent],
                                group_origin:Type[Group], group_destination:Type[Group]):
        self.events.insert(0, StochasticEvent(init_time, time, event_type, group_origin, group_destination))
        self.contact_counter[group_origin.age][group_origin.risk][group_origin.vaccine] += 1
        return


    def add_transition_event(self, init_time:float, time:float, event_type:Type[StochasticEvent],
                                   group:Type[Group]):
        self.events.insert(0, StochasticEvent(init_time, time, event_type, group, group))
        return


    def return_dict(self) -> dict:
        data={}
        data['node_id'] = str(self.node_id)
        data['fips_id'] = str(self.fips_id)
        data['compartments'] = {}

        for comp in Compartments:
            data['compartments'][comp.name] = { 'U':{}, 'V':{} }

            for vac in VaccineGroup:
                for risk in RiskGroup:
                    data['compartments'][comp.name][vac.name][risk.name] = self.compartments.return_list_by_age_group( comp.value, vac.value, risk.value)

        
        return(data)


    def total_population(self) -> float:
        return self.compartments.total_population

    def demographic_population(self, group) -> float:
        return self.compartments.demographic_population(group)

