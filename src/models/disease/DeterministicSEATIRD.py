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
    S, E, A, T, I, R, D = y
    
    dS_dt = -beta * (A + I) * S
    dE_dt = beta * (A + I) * S - nu * E
    dA_dt = nu * E - (mu + tau) * A
    dT_dt = tau * A - rho * T
    dI_dt = mu * A - (gamma + delta) * I
    dR_dt = gamma * I + rho * T
    dD_dt = delta * I
    
    logging.info(f'{dS_dt}, {dE_dt}, {dA_dt}, {dT_dt}, {dI_dt}, {dR_dt}, {dD_dt}')
    return [dS_dt, dE_dt, dA_dt, dT_dt, dI_dt, dR_dt, dD_dt]


class DeterministicSEATIRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]):
        self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters

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
            this_node_id = int(item['county'])
            this_infected = int(item['infected'])
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
        Main simulation logic for deterministic SEATIRD model

        E = Exposed, S = Susceptible, A = Asymptomatic infectious,
        T = Treated, I = Infectious symptomatic, R = Recovered, D = Deceased
        """
        logger.debug(f'node={node}, time={time}')

        initial_conditions = [
            node.compartments.susceptible_population(),
            node.compartments.exposed_population(),
            node.compartments.asymptomatic_population(),
            node.compartments.treatable_population(),
            node.compartments.infectious_population(),
            node.compartments.recovered_population(),
            node.compartments.deceased_population(),
        ]

        model_parameters = (
            0.3,
            0.2,
            0.1,
            0.05,
            0.1,
            0.01,
            0.1,
        )

        #model_parameters = (
        #    self.parameters.beta,
        #    self.parameters.nu,
        #    self.parameters.mu,
        #    self.parameters.tau,
        #    self.parameters.gamma,
        #    self.parameters.delta,
        #    self.parameters.rho,
        #)

        t_span = (0, 1)
        t_eval = np.linspace(*t_span, 1)

        # Solve ODE
        solution = solve_ivp(SEATIRD_model, t_span, initial_conditions, args=model_parameters, t_eval=t_eval, vectorized=True)

        # Extract solutions
        #S, E, A, T, I, R, D = solution.y
        #logger.info(f'solution.y = {solution.y}')
        return





