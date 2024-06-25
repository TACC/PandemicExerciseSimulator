#!/usr/bin/env python3
import logging
import numpy as np
from typing import Type

from .Group import RiskGroup, VaccineGroup, Compartments, Group

logger = logging.getLogger(__name__)


class PopulationCompartments:

    def __init__(self, groups:list, high_risk_ratios:list):
        # groups and high_risk_ratios should be two lists of the same length
        self.groups = groups     # starting population from input file
        self.high_risk_ratios = high_risk_ratios

        self.number_of_age_groups = len(groups)
        self.total_population = sum(groups)
        logger.debug(f'instantiated a new compartments object with total_population = ' \
                     f'{self.total_population} and groups = {self.groups}')

        # the compartment_data object is a 4-D array, see bottom of this file
        self.compartment_data = np.zeros(( len(groups),
                                           len(RiskGroup),
                                           len(VaccineGroup),
                                           len(Compartments)
                                        ))

        for i in range(len(self.groups)):
            number_of_low_risk = (self.groups[i] * (1.0-float(self.high_risk_ratios[i])))
            number_of_high_risk = (self.groups[i] - number_of_low_risk)

            self.compartment_data[i][RiskGroup.L.value][VaccineGroup.U.value][Compartments.S.value] = number_of_low_risk
            self.compartment_data[i][RiskGroup.H.value][VaccineGroup.U.value][Compartments.S.value] = number_of_high_risk

        logger.debug(f'compartment data for this compartment = {(self.compartment_data).tolist()}')
        return


    def __str__(self):
        return(str((self.compartment_data).tolist()))


    def return_list_by_age_group(self, comp:int, vac:int, risk:int) -> list:
        """
        Given a compartment (e.g. S), vaccination status (e.g. U), and risk level
        (e.g. L), return a list of values 0..N (N=number of age groups) where each
        value is the number of people in that compartment

        Args:
            comp (int): compartment key
            vac (int): vacccine status key
            risk (int): risk group key
        """
        age_list = []
        for i in range(len(self.groups)):
            age_list.append(self.compartment_data[i][risk][vac][comp])
        return age_list


    def expose_number_of_people(self, group:Type[Group], num_to_expose:int):
        """
        When entering this function, move people from Susceptible => Exposed

        Args:
            group (Group): group where transition should happen
            num_to_expose (int): number of people to move from S=>E

        Note: Not currently used in StochasticSEATIRD; a similarly named method
              exists in that class for this functionality
        """
        self.compartment_data[group.age][group.risk][group.vaccine][Compartments.S.value] -= num_to_expose
        self.compartment_data[group.age][group.risk][group.vaccine][Compartments.E.value] += num_to_expose
        return


    def decrement(self, group:Type[Group], compartment:int):
        """
        Decrement compartment by 1

        Args:
            group (Group): group where decrement should happen
            compartment (int): compartment ID where decrement should happen
        """
        self.compartment_data[group.age][group.risk][group.vaccine][compartment] -= 1
        return


    def increment(self, group:Type[Group], compartment:int):
        """
        Increment compartment by 1

        Args:
            group (Group): group where increment should happen
            compartment (int): compartment ID where increment should happen
        """
        self.compartment_data[group.age][group.risk][group.vaccine][compartment] += 1
        return


    def demographic_population(self, group:Type[Group]) -> float:
        """
        Return sum population of all compartments for a given Group
        """
        return sum(self.compartment_data[group.age][group.risk][group.vaccine])


# Compartment data object is a 4-dimensional array of floats. The four dimensions are:
# [Group (N=5)] [Risk status (N=2)] [Vaccinated status (N=2)] [Compartment (N=7)]
#
# Age groups for Texas data are 0-4, 5-24, 25-49, 50-64, 65+
# Risk status is either low risk or high risk
# Vaccination status is either unvaccinated or vaccinated
# Compartments are Susceptible, Exposed, Asymptomatic, Treatable, Infectious, Recovered, Deceased
#
#
#                                       [][b][][]
#
#                         0 (low risk)             1 (high risk)
#
#                        --------------
#           0 (0-4)      | 2x7 matrix |-------------------------------
#                        |            |                              |
#                        --------------                              |
#           1 (5-24)                                                 |
#                                                                    V
#
# [a][][][] 2 (25-49)                                            [][][][d]
#
#                                                0 (S)  1 (E)  2 (A)  3 (T)  4 (I)  5 (R)  6 (D)
#           3 (50-64)
#                                   0 (unvac)    float  float  float  float  float  float  float
#                       [][][c][]   
#           4 (65+)                 1 (vac)      float  float  float  float  float  float  float
#
#

