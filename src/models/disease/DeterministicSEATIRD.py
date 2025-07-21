#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Network import Network
from baseclasses.Node import Node

logger = logging.getLogger(__name__)

def SEATIRD_model(y, transmission_rate, tau, kappa, chi, gamma, nu):
    """
    SEATIRD compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, A, T, I, R, D]
        transmission_rate (float): beta modified by NPIs, vaccine effectiveness, contact rate, relative susceptibility (sigma),
                                   has (A+T+I)/N hidden in it to do node based proportion of population infectious
        tau (float): 1/Latency period in days (exposed to asymptomatic)
        kappa (float): 1/Asymptomatic infectious period in days (asymptomatic to treatable)
        chi (float): 1/Treatable infectious period in days (treatable to infectious)
        gamma (float): 1/symptomatic infectious period in days (asymptomatic/treatable/infectious to recovered)
        nu (float): Mortality rate in 1/days (asymptomatic/treatable/infectious to deceased)
    Returns:
       List[float]: Derivatives [dS/dt, dE/dt, dA/dt, dT/dt, dI/dt, dR/dt, dD/dt].
   """
    S, E, A, T, I, R, D = y

    # Prevent S from going negative by only removing as many people remain in the compartment
    max_new_infections = min(transmission_rate * S, S)
    dS_dt = -max_new_infections
    dE_dt = max_new_infections - (tau) * E

    dA_dt = (tau) * E - (kappa + gamma + nu) * A
    dT_dt = (kappa) * A - (chi + gamma + nu) * T
    dI_dt = (chi) * T - (gamma + nu) * I

    dR_dt = gamma * (A + T + I)
    dD_dt = nu * (A + T + I)

    return np.array([dS_dt, dE_dt, dA_dt, dT_dt, dI_dt, dR_dt, dD_dt])

class DeterministicSEATIRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]):
        self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters
        self.npis_schedule = disease_model.npis_schedule

        logger.info(f'instantiated DeterministicSEATIRD object with stochastic={self.is_stochastic}')
        logger.debug(f'{self.parameters}')
        return

    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int):
        node.compartments.expose_number_of_people(group, num_to_expose)
        return

    def simulate(self, node: Type[Node], time: int):
        """
        Main simulation logic for deterministic SEATIRD model.
        Each group (age, risk, vaccine) is simulated separately via ODE.

        S = Susceptible, E = Exposed, A = Asymptomatic infectious,
        T = Treated, I = Infectious symptomatic, R = Recovered, D = Deceased
        """

        logger.debug(f'node={node}, time={time}')

        # Need to update the node sense of time to get NPIs to take effect
        self.now = time

        # Snapshot: all compartments at start of the day so we don't call the updated subgroups
        compartments_today = {
            (group.age, group.risk, group.vaccine): np.array(node.compartments.get_compartment_vector_for(group))
            for group in node.compartments.get_all_groups()
        }

        # Get the total population of node
        total_node_pop = node.total_population()

        # beta is set for all age groups by node and day, so calc before loop over groups in node
        beta_vector = self._calculate_beta_w_npi(node.node_index, node.node_id)

        # focal_group is the group we are simulating forward in time
        # contacted_group is the group causing disease spread interaction
        for focal_group in node.compartments.get_all_groups():
            # print(focal_group)  # e.g. Group object: age=0, risk=0, vaccine=0
            focal_group_compartments_today = np.array(node.compartments.get_compartment_vector_for(focal_group))
            if sum(focal_group_compartments_today) == 0:
                continue  # skip empty groups

            # Get nu as scalar needed for the model based on age and risk group
            nu = float(self.parameters.nu_values[focal_group.age][focal_group.risk]) # nu is vector of values

            #### Get force of infection from each interaction subgroup ####
            # This is constant in time if we don't have an NPI schedule hitting beta each day
            transmission_rate = 0
            for contacted_group in node.compartments.get_all_groups():
                contact_rate = float(self.parameters.np_contact_matrix[focal_group.age][contacted_group.age])
                if contact_rate== 0:
                    continue

                # contacted_group_compartments_today
                S, E, A, T, I, R, D = compartments_today[(contacted_group.age, contacted_group.risk, contacted_group.vaccine)]
                infectious_contacted = A + T + I

                # 1 is vaccinated subgroup, 0 unvaccinated subgroup
                if contacted_group.vaccine == 1: # vaccinated then get effectiveness by age group
                    vaccine_effectiveness = self.parameters.vaccine_effectiveness[contacted_group.age]
                else: # if you're not vaccinated, it has no effectiveness
                    vaccine_effectiveness = 0
                sigma              = float(self.parameters.relative_susceptibility[contacted_group.age])
                # infectious_contacted/total_node_pop this captures the fraction of population we need to move from S -> E
                transmission_rate += (1.0 - vaccine_effectiveness) * beta_vector[contacted_group.age] * contact_rate \
                                    * sigma * (infectious_contacted/total_node_pop)
            # Can't have negative transmission_rate
            transmission_rate = max(transmission_rate, 0)

            model_parameters = (
                transmission_rate,     # S => E
                self.parameters.tau,   # E => A
                self.parameters.kappa, # A => T
                self.parameters.chi,   # T => I
                self.parameters.gamma, # A/T/I => R
                nu                     # A/T/I => D
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEATIRD_model(focal_group_compartments_today, *model_parameters)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return


