#!/usr/bin/env python3
import logging
import numpy as np
from typing import Type

from src.baseclasses.Group import RiskGroup, VaccineGroup, Compartments, Group

logger = logging.getLogger(__name__)


class PopulationCompartments:

    def __init__(self, age_group_pops:list, high_risk_ratios:list):
        # groups and high_risk_ratios should be two lists of the same length
        self.age_group_pops = age_group_pops     # starting population from input file
        self.high_risk_ratios = high_risk_ratios

        # Get Compartments enumeration
        self.comp_index = {c.name: c.value for c in Compartments}

        self.number_of_age_groups = len(age_group_pops)
        self.total_population = sum(age_group_pops)
        logger.debug(f'instantiated a new compartments object with total_population = ' \
                     f'{self.total_population} and groups = {self.age_group_pops}')

        # the compartment_data object is a 4-D array, see bottom of this file
        self.compartment_data = np.zeros(( self.number_of_age_groups,
                                           len(RiskGroup),
                                           len(VaccineGroup),
                                           len(Compartments)
                                        ))

        for i in range(self.number_of_age_groups):
            low_risk_ratio = 1.0 - float(self.high_risk_ratios[i]) # convert high risk ratios to low
            number_of_low_risk = round(self.age_group_pops[i] * low_risk_ratio) # get an integer number of low risk
            number_of_high_risk = max((self.age_group_pops[i] - number_of_low_risk), 0.0) # diff is high risk but never negative

            self.compartment_data[i][RiskGroup.L.value][VaccineGroup.U.value][Compartments.S.value] = number_of_low_risk
            self.compartment_data[i][RiskGroup.H.value][VaccineGroup.U.value][Compartments.S.value] = number_of_high_risk

        logger.debug(f'compartment data for this compartment = {(self.compartment_data).tolist()}')
        return


    def __str__(self):
        return(str((self.compartment_data).tolist()))


    def return_list_by_age_group(self, comp:int, risk:int, vac:int) -> list:
        """
        Given a compartment (e.g. S), risk level (e.g. L), and vaccination status (e.g. U),
        return a list of values N (N=number of age groups) where each
        value is the number of people in that compartment

        Args:
            comp (int): compartment key
            risk (int): risk group key
            vac (int): vacccine status key
        """
        age_list = []
        for i in range(self.number_of_age_groups):
            age_list.append(self.compartment_data[i][risk][vac][comp])
        return age_list


    def expose_number_of_people_bulk(self, group:Type[Group], num_to_expose:int):
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

    def get_disease_compartment_sum(self) -> np.ndarray:
        """
        Return a length-[n_compartments] vector: totals across all age/risk/vax.
        Order matches the Compartments enum order (last axis of compartment_data).
        """
        arr = np.asarray(self.compartment_data, dtype=float)  # [age][risk][vax][comp]
        return arr.sum(axis=(0, 1, 2))  # -> [comp]

    '''
    def susceptible_population(self) -> float:
        """
        Return sum population of susceptible compartments across all demographic groups

        The np.sum() method, given a tuple of the first three axes (0,1,2), sums and flattens
        the 4-D matrix into a 1-D matrix with 7 elements (each compartment)
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.S.value]


    def exposed_population(self) -> float:
        """
        Return sum population of exposed compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.E.value]


    def asymptomatic_population(self) -> float:
        """
        Return sum population of asymptomatic compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.A.value]


    def treatable_population(self) -> float:
        """
        Return sum population of treatable compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.T.value]
    

    def infectious_population(self) -> float:
        """
        Return sum population of infectious compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.I.value]
    

    def recovered_population(self) -> float:
        """
        Return sum population of recovered compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.R.value]
    

    def deceased_population(self) -> float:
        """
        Return sum population of deceased compartments across all demographic groups
        """
        return self.compartment_data.sum(axis=(0,1,2))[Compartments.D.value]

    '''

    def transmitting_population(self, transmitting_compartments:dict[str, float]) -> float:
        """
        Returns weighted sum of infectious transmitting compartments for all age/risk/vax subgroups.

        Parameters
        ----------
        transmitting_compartments : dict[str, float]
            Dict of {compartment_label: fraction_traveling}.
        """
        arr = np.asarray(self.compartment_data, dtype=float)  # [age][risk][vax][comp]
        flat = arr.sum(axis=(0, 1, 2))  # collapse to [comp]
        total = 0.0
        for label, frac in transmitting_compartments.items():
            idx = self.comp_index[label]
            total += flat[idx] * float(frac)
        return float(total)

    def traveling_population(self, traveling_compartments:dict[str, float]) -> float:
        """
            Returns weighted sum of infectious traveling compartments for all age/risk/vax subgroups.

            Parameters
            ----------
            traveling_compartments : dict[str, float]
                Dict of {compartment_label: fraction_traveling}.
            """
        arr = np.asarray(self.compartment_data, dtype=float)  # [age][risk][vax][comp]
        flat = arr.sum(axis=(0, 1, 2))  # collapse to [comp]
        total = 0.0
        for label, frac in traveling_compartments.items():
            idx = self.comp_index[label]
            total += flat[idx] * float(frac)
        return float(total)

    '''
    def asymptomatic_population_by_age(self, age_group:int) -> float:
        """
        Return sum population of asymptomatic compartments across all demographic groups
        """
        # TODO this needs to be tested
        return self.compartment_data.sum(axis=(1,2))[age_group][Compartments.A.value]
    '''

    def transmitting_population_by_age(self, age_group_idx:int, transmitting_compartments:dict[str, float]) -> float:
        """
        Returns weighted sum of infectious transmitting compartments for a given age group.
        The fraction of these compartments transmit disease to those visiting their node.
        e.g. 100% of Infectious may infect others, or we could assume 50% are not interacting with visitors

        Parameters
            ----------
            age_group_idx : int
                Age group index to compute travelers for.
            transmitting_compartments : dict[str, float]
                Dict of {compartment_label: fraction_infecting_visitors}.
        """
        arr = np.asarray(self.compartment_data, dtype=float)  # [age][risk][vax][comp]
        flat = arr[age_group_idx].sum(axis=(0, 1))  # collapse [risk,vax] -> [age][comp]
        total = 0.0
        for label, frac in transmitting_compartments.items():
            idx = self.comp_index[label]
            total += flat[idx] * float(frac)
        return float(total)

    def traveling_population_by_age(self, age_group_idx:int, traveling_compartments:dict[str, float]) -> float:
        """
            Returns weighted sum of infectious traveling compartments for a given age group.
            Fraction of these compartment(s) will take a trip to other nodes.
            e.g. 100% of Infectious Asymptomatic may travel, but only 20% of Infectious Symptomatic

            Parameters
            ----------
            age_group_idx : int
                Age group index to compute travelers for.
            traveling_compartments : dict[str, float]
                Dict of {compartment_label: fraction_traveling}.
            """
        arr = np.asarray(self.compartment_data, dtype=float)  # [age][risk][vax][comp]
        flat = arr[age_group_idx].sum(axis=(0, 1))  # collapse [risk,vax] -> [age][comp]
        total = 0.0
        for label, frac in traveling_compartments.items():
            idx = self.comp_index[label]
            total += flat[idx] * float(frac)
        return float(total)

    # Adding helper function to get the subgroups into the deterministic compartmental model
    def get_all_groups(self):
        groups = []
        for age in range(self.number_of_age_groups):
            for risk in range(len(RiskGroup)):
                for vac in range(len(VaccineGroup)):
                    groups.append(Group(age, risk, vac))
        return groups

    def get_compartment_vector_for(self, group):
        return list(self.compartment_data[group.age][group.risk][group.vaccine])

    def set_compartment_vector_for(self, group, values):
        for i in range(len(Compartments)):
            self.compartment_data[group.age][group.risk][group.vaccine][i] = values[i]

    def vaccine_eligible_by_group(self, age_risk_priority_groups,
            only_unvaccinated: bool = True, only_susceptible: bool = True):
        """
        Return a list of (age, risk, value) for groups eligible for vaccination.
        Args:
            age_risk_priority_groups: list[float] of length = number_of_age_groups
            only_unvaccinated: if True, include only VaccineGroup.U
            only_susceptible: if True, count only S compartment (susceptible)

        age_risk_priority_groups[a] ∈ {0, 0.5, 1}
          0   => NOBODY in this age group is eligible
          0.5 => only HIGH-RISK in this age group is eligible
          1   => EVERYBODY in this age group is eligible

        TODO: Function doesn't consider age-specific vaccine adherence, possibly add.
        """

        if len(age_risk_priority_groups) != self.number_of_age_groups:
            raise ValueError(f"age_risk_priority_groups must have length {self.number_of_age_groups}")

        vac_idxs = [VaccineGroup.U.value] if only_unvaccinated else [VaccineGroup.U.value, VaccineGroup.V.value]

        out = []
        for age, pri in enumerate(age_risk_priority_groups):
            if pri == 0:
                continue
            elif pri == 0.5:
                risk_list = [RiskGroup.H.value]
            elif pri == 1:
                risk_list = [RiskGroup.L.value, RiskGroup.H.value]
            else:
                raise ValueError("age_risk_priority_groups values must be 0, 0.5, or 1")

            for risk in risk_list:
                block = self.compartment_data[age, risk, vac_idxs, :]
                val = float(block[..., Compartments.S.value].sum()) if only_susceptible else float(block.sum())
                if val > 0:
                    out.append((age, risk, val))
        return out

    def vaccine_eligible_population(self, age_risk_priority_groups: list,
            only_unvaccinated: bool = False, only_susceptible: bool = False) -> float:
        """
        Total eligible population per flags, implemented by summing the per-group function.
        """
        groups = self.vaccine_eligible_by_group(
            age_risk_priority_groups,
            only_unvaccinated=only_unvaccinated,
            only_susceptible=only_susceptible,
        )
        return float(sum(val for _, _, val in groups))

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
# [a][][][] 2 (25-49)                                            [*][*][*][d]
#
#                                                0 (S)  1 (E)  2 (A)  3 (T)  4 (I)  5 (R)  6 (D)
#           3 (50-64)
#                                   0 (unvac)    float  float  float  float  float  float  float
#                       [][][c][]   
#           4 (65+)                 1 (vac)      float  float  float  float  float  float  float
#
#
