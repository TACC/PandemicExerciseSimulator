#!/usr/bin/env python3
import numpy as np
from scipy.integrate import solve_ivp

import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Network import Network
from baseclasses.Node import Node

logger = logging.getLogger(__name__)


def SEATIRD_model(t, y, beta, nu, mu, tau, gamma, delta, rho):
    """
        SEATIRD compartmental model ODE function.

        Parameters:
            t (float): Time point (required by ODE solvers, but unused directly).
            y (List[float]): Current values for compartments [S, E, A, T, I, R, D].
            beta (float): Transmission rate.
            nu (float): Rate from exposed (E) to asymptomatic infectious (A).
            mu (float): Rate from asymptomatic infectious (A) to symptomatic infectious (I).
            tau (float): Rate from asymptomatic infectious (A) to treatable non-infectious(T).
            gamma (float): Recovery rate from symptomatic infectious (I) to recovered (R).
            delta (float): Mortality rate from symptomatic infectious (I) to deceased (D).
            rho (float): Recovery rate from treatable non-infectious (T) to recovered (R).

        Returns:
            List[float]: Derivatives [dS/dt, dE/dt, dA/dt, dT/dt, dI/dt, dR/dt, dD/dt].
        """
    S, E, A, T, I, R, D = y
    
    dS_dt = -beta * (A + I) * S
    dE_dt = beta * (A + I) * S - nu * E
    dA_dt = nu * E - (mu + tau) * A
    dT_dt = tau * A - rho * T
    dI_dt = mu * A - (gamma + delta) * I
    dR_dt = gamma * I + rho * T
    dD_dt = delta * I
    
    logging.debug(f'{dS_dt}, {dE_dt}, {dA_dt}, {dT_dt}, {dI_dt}, {dR_dt}, {dD_dt}')
    return [dS_dt, dE_dt, dA_dt, dT_dt, dI_dt, dR_dt, dD_dt]


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
        """
        
        """
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

        # model_parameters = (
        #    self.parameters.beta,
        #    self.parameters.nu,
        #    self.parameters.mu,
        #    self.parameters.tau,
        #    self.parameters.gamma,
        #    self.parameters.delta,
        #    self.parameters.rho,
        # )

        model_parameters = (
            0.005,  # beta, S => E
            0.50,   # nu, E => A
            0.50,   # mu, A => I
            0.50,   # tau, A => T
            0.20,   # gamma, I => R
            0.01,   # delta, I => D
            0.10,   # rho, T => R
        )

        t_span = (0, 1)         # simulate one day
        t_eval = [1]            # get result at end of day

        for group in node.compartments.get_all_groups():
            y0 = node.compartments.get_compartment_vector_for(group)

            if sum(y0) == 0:
                continue  # skip empty groups

            solution = solve_ivp(SEATIRD_model, t_span, y0,
                                 args=model_parameters, t_eval=t_eval)

            final_values = solution.y[:, -1]
            node.compartments.set_compartment_vector_for(group, final_values)

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

        return


