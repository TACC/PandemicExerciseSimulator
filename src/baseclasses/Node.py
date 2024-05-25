#!/usr/bin/env python3
import numpy as np

from .PopulationCompartments import PopulationCompartments
from .PopulationCompartments import RiskGroup, VaccineGroup, Compartments

class Node:

    def __init__(self, node_id:int, compartments):
        self.node_id = node_id
        self.compartments = compartments
        self.vaccine_stockpile = 0
        self.antifiral_stockpile = 0
        
        # the contact counter struct is a 3-dimensional array of ints
        # the fields are [number of age groups][risk group size][vaccinated group size]
        self.contact_counter = np.zeros((self.compartments.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))
        self.unqueued_contact_counter = np.zeros((self.compartments.number_of_age_groups, len(RiskGroup), len(VaccineGroup)))

        # the event counter struct is a 4-dimensional array of ints
        # the fields are [number of age groups][risk group size][vaccinated group size][compartments size]
        self.unqueued_event_counter = np.zeros((self.compartments.number_of_age_groups, len(RiskGroup), len(VaccineGroup), len(Compartments)))
