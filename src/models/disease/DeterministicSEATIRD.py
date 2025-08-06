#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Network import Network
from baseclasses.Node import Node
from models.treatments.Vaccination import Vaccination

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

    def __init__(self, disease_model:Type[DiseaseModel]): # add antiviral_model
        #self.is_stochastic = disease_model.is_stochastic
        self.now = disease_model.now
        self.parameters = disease_model.parameters

        self.R0             = float(self.parameters.disease_parameters['R0'])
        self.beta_scale     = float(self.parameters.disease_parameters['beta_scale'] )   # "R0CorrectionFactor"
        self.beta           = self.R0 / self.beta_scale

        # the following four parameters are provided by users as periods (units = days),
        # but then stored here as rates (units = 1/days)
        self.tau            = 1/float(self.parameters.disease_parameters['tau'])
        self.kappa          = 1/float(self.parameters.disease_parameters['kappa'])
        self.gamma          = 1/float(self.parameters.disease_parameters['gamma'])
        self.chi            = 1/float(self.parameters.disease_parameters['chi'])

        # Mobility reduction parameter
        #self.rho            = float(simulation_properties.rho)
        #self.rho = 0.39 # this should be in travel model


        # the user enters one nu value for each age group, assumed to be low risk
        # population. use multiplier 9x to derive values for high risk population
        self.nu_values      = [[],[]]
        self.nu_values[0]   = [float(x)   for x in self.parameters.disease_parameters['nu']]
        self.nu_values[1]   = [float(x)*9 for x in self.parameters.disease_parameters['nu']]

        # transpose nu_values so that we can access values in the order we are used to
        #   e.g.:    nu_values[age][risk]
        self.nu_values = np.array(self.nu_values).transpose().tolist()

        self.relative_susceptibility = []
        self.relative_susceptibility = [float(x) for x in self.parameters.disease_parameters['sigma']]

        # this isn't used, bc _calculate_beta_w_npi uses the schedule
        self.npis_schedule = disease_model.npis_schedule

        logger.info(f'instantiated DeterministicSEATIRD object')
        logger.debug(f'{self.parameters}')
        return

    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int, vaccine_model:Type[Vaccination]):
        # this is a bulk transfer of people to move from S to E by group
        node.compartments.expose_number_of_people_bulk(group, num_to_expose)
        return

    def simulate(self, node:Type[Node], time: int, vaccine_model:Type[Vaccination]):
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
            nu = float(self.nu_values[focal_group.age][focal_group.risk]) # nu is vector of values

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
                    vaccine_effectiveness = vaccine_model.vaccine_effectiveness[contacted_group.age]
                else: # if you're not vaccinated, it has no effectiveness
                    vaccine_effectiveness = 0
                sigma              = float(self.relative_susceptibility[contacted_group.age])
                # infectious_contacted/total_node_pop this captures the fraction of population we need to move from S -> E
                transmission_rate += (1.0 - vaccine_effectiveness) * beta_vector[contacted_group.age] * contact_rate \
                                    * sigma * (infectious_contacted/total_node_pop)
            # Can't have negative transmission_rate
            transmission_rate = max(transmission_rate, 0)

            model_parameters = (
                transmission_rate,     # S => E
                self.tau,   # E => A
                self.kappa, # A => T
                self.chi,   # T => I
                self.gamma, # A/T/I => R
                nu                     # A/T/I => D
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEATIRD_model(focal_group_compartments_today, *model_parameters)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return


