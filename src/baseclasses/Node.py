#!/usr/bin/env python3
import json
import numpy as np

#from .PopulationCompartments import PopulationCompartments
from .PopulationCompartments import RiskGroup, VaccineGroup, Compartments

class Node:

    def __init__(self, node_id:int, compartments):
        self.node_id = node_id
        self.compartments = compartments
        self.vaccine_stockpile = 0
        self.antiviral_stockpile = 0
        
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
        data['compartments'] = f'{self.compartments}'
        return(json.dumps(data))

    def return_dict(self) -> dict:
        data={}
        data['node_id'] = str(self.node_id)
        data['compartments'] = {}

        for comp in Compartments:
            data['compartments'][comp.name] = { 'U':{}, 'V':{} }

            for vac in VaccineGroup:
                for risk in RiskGroup:
                    data['compartments'][comp.name][vac.name][risk.name] = str(self.compartments.return_list_by_age_group( comp.value, vac.value, risk.value))

        
        return(data)




