#!/usr/bin/env python3
import numpy as np

import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Network import Network
from baseclasses.Node import Node

logger = logging.getLogger(__name__)

def SEATIRD_model(y, beta, tau, kappa, chi, gamma, nu):
    """
    SEATIRD compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, A, T, I, R, D]
        tau (float): 1/Latency period in days (exposed to asymptomatic)
        kappa (float): 1/Asymptomatic infectious period in days (asymptomatic to treatable)
        chi (float): 1/Treatable infectious period in days (treatable to infectious)
        gamma (float): 1/symptomatic infectious period in days (asymptomatic/treatable/infectious to recovered)
        nu (float): Mortality rate in 1/days (asymptomatic/treatable/infectious to deceased)
    Returns:
       List[float]: Derivatives [dS/dt, dE/dt, dA/dt, dT/dt, dI/dt, dR/dt, dD/dt].
   """
    N = sum(y) # need to normalize by the population in each node
    S, E, A, T, I, R, D = y

    dS_dt = -beta * (A + T + I) * S/N
    dE_dt = beta * (A + T + I) * S/N - (tau) * E

    dA_dt = (tau) * E - ((kappa) + gamma + nu) * A
    dT_dt = (kappa) * A - ((chi) + gamma + nu) * T
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

    def set_initial_conditions(self, initial:list, network:Type[Network]):
        """
        This method is invoked from the main simulator block. Read in the list of initial infected
        per location per age group, and expose 

        Args:
            initial (list): list of initial infected per age group per county from INPUT
            network (Network): network object with list of nodes
        """
        for item in initial:
            # TODO the word "county" is hardcoded here but should be made dynamic in case
            # people want to do zip codes instead. Maybe 'location_id'
            this_node_id   = int(item['county'])
            this_infected  = int(item['infected'])
            this_age_group = int(item['age_group'])

            group = Group(this_age_group, RiskGroup.L.value, VaccineGroup.U.value)

            for node in network.nodes:
                if node.node_id == this_node_id:
                    self.expose_number_of_people(node, group, this_infected)

        # TODO If this method remains the same between deterministic and stochastic,
        # then I should move it into the parent class.
        return


    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int):
        node.compartments.expose_number_of_people(group, num_to_expose)
        return

    def simulate(self, node, time):
        """
        Main simulation logic for deterministic SEATIRD model.
        Each group (age, risk, vaccine) is simulated separately via ODE.

        S = Susceptible, E = Exposed, A = Asymptomatic infectious,
        T = Treated, I = Infectious symptomatic, R = Recovered, D = Deceased
        """

        logger.debug(f'node={node}, time={time}')

        for group in node.compartments.get_all_groups():
            # print(group) # e.g. Group object: age=0, risk=0, vaccine=0
            compartments_today = np.array(node.compartments.get_compartment_vector_for(group))

            if sum(compartments_today) == 0:
                continue  # skip empty groups

            # get nu as scalar needed for the model
            nu = self.parameters.nu_values[group.age][group.risk] # nu is vector of values
            model_parameters = (
                self.parameters.beta,  # S => E
                self.parameters.tau,   # E => A
                self.parameters.kappa, # A => T
                self.parameters.chi,   # T => I
                self.parameters.gamma, # A/T/I => R
                nu                     # A/T/I => D
            )

            daily_change = SEATIRD_model(compartments_today, *model_parameters)
            compartments_tomorrow = compartments_today + daily_change
            node.compartments.set_compartment_vector_for(group, compartments_tomorrow)
        """
            if (node.node_id == 113 and group.age == 1 and group.risk == 0 and group.vaccine == 0):
                print(f"[group 1-0-0] prev = {compartments_today.astype(int)}")
                print(f"[group 1-0-0] Δ = {daily_change.astype(int)}")
                print(f"[group 1-0-0] updated = {compartments_tomorrow.astype(int)}")


        # Log summary totals for a specific node (Dallas County = 113)
        if node.node_id == 113:
            S = node.compartments.susceptible_population()
            E = node.compartments.exposed_population()
            A = node.compartments.asymptomatic_population()
            T = node.compartments.treatable_population()
            I = node.compartments.infectious_population()
            R = node.compartments.recovered_population()
            D = node.compartments.deceased_population()

            logger.info(f'Updated node 113: S={S}, E={E}, A={A}, T={T}, I={I}, R={R}, D={D}')
        """

        return


