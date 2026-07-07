#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Node import Node
from models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)

def SEAITRD_model(y, transmission_prob, tau, kappa, chi, gamma, nu):
    """
    SEAITRD compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, A, I, T, R, D]
                         or [S, E, A, I, R, D] when T is omitted
        transmission_prob (float): beta modified by NPIs, vaccine effectiveness, contact rate, relative susceptibility (sigma),
                                   has (A+I+T)/N hidden in it to do node based proportion of population infectious
                                   Transmission rate converted to probability to keep between 0 and 1
        tau (float): 1/Latency period in days (exposed to asymptomatic)
        kappa (float): 1/Asymptomatic infectious period in days (asymptomatic to infectious)
        chi (float): Retained for input compatibility; treatment is stockpile-controlled
        gamma (float): 1/symptomatic infectious/treated period in days to recovered
        nu (float): Mortality rate in 1/days (infectious/treated to deceased)
    Returns:
       List[float]: Derivatives in the same compartment order as y.
   """
    has_treated_compartment = len(y) == 7
    if has_treated_compartment:
        S, E, A, I, T, R, D = y
    else:
        S, E, A, I, R, D = y
        T = 0.0

    # Prevent S from going negative by only removing as many people remain in the compartment
    max_new_infections = min(transmission_prob * S, S)
    e_to_a = min(tau * E, E)
    a_to_i = min(kappa * A, A)

    infectious_exit_rate = gamma + nu
    infectious_exit = min(infectious_exit_rate * I, I)
    treated_exit = min(infectious_exit_rate * T, T)
    recovery_share = gamma / infectious_exit_rate if infectious_exit_rate > 0 else 0.0

    i_to_r = recovery_share * infectious_exit
    i_to_d = infectious_exit - i_to_r
    t_to_r = recovery_share * treated_exit
    t_to_d = treated_exit - t_to_r

    dS_dt = -max_new_infections
    dE_dt = max_new_infections - e_to_a

    dA_dt = e_to_a - a_to_i
    dI_dt = a_to_i - i_to_r - i_to_d
    dT_dt = -t_to_r - t_to_d

    dR_dt = i_to_r + t_to_r
    dD_dt = i_to_d + t_to_d

    if has_treated_compartment:
        return np.array([dS_dt, dE_dt, dA_dt, dI_dt, dT_dt, dR_dt, dD_dt])
    return np.array([dS_dt, dE_dt, dA_dt, dI_dt, dR_dt, dD_dt])

class DeterministicSEAITRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]): # add antiviral_model
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

        compartment_labels = [
            str(label).upper()
            for label in self.parameters.disease_parameters.get('compartments', [])
        ]
        self.has_treated_compartment = "T" in compartment_labels
        self.compartment_index = {
            label: index
            for index, label in enumerate(compartment_labels)
        }

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

        logger.info(f'instantiated DeterministicSEAITRD object')
        logger.debug(f'{self.parameters}')
        return

    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int, vaccine_model:Type[Vaccination]):
        # this is a bulk transfer of people to move from S to E by group
        node.compartments.expose_number_of_people_bulk(group, num_to_expose)
        return

    def simulate(self, node:Type[Node], time: int, vaccine_model:Type[Vaccination]):
        """
        Main simulation logic for deterministic SEAITRD model.
        Each group (age, risk, vaccine) is simulated separately via ODE.

        S = Susceptible, E = Exposed, A = Asymptomatic infectious,
        I = Infectious symptomatic, T = Treated, R = Recovered, D = Deceased
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

            # Determine vaccine effect on focal group susceptibility
            # 1 is vaccinated subgroup, 0 unvaccinated subgroup
            if focal_group.vaccine == 1:
                vaccine_effectiveness = vaccine_model.vaccine_effectiveness[focal_group.age]
            else:
                vaccine_effectiveness = 0.0

            #### Get force of infection from each interaction subgroup ####
            # This is constant in time if we don't have an NPI schedule hitting beta each day
            transmission_rate = 0
            for contacted_group in node.compartments.get_all_groups():
                contact_rate = float(self.parameters.np_contact_matrix[focal_group.age][contacted_group.age])
                if contact_rate== 0:
                    continue

                contacted_compartments = compartments_today[
                    (contacted_group.age, contacted_group.risk, contacted_group.vaccine)
                ]
                A = contacted_compartments[self.compartment_index["A"]]
                I = contacted_compartments[self.compartment_index["I"]]
                infectious_contacted = A + I
                if self.has_treated_compartment:
                    infectious_contacted += contacted_compartments[self.compartment_index["T"]]

                # infectious_contacted/total_node_pop this captures the fraction of population we need to move from S -> E
                # NOTE: Maybe an under-weighting if we should be doing age group specific: infectious_age/total_age_pop
                transmission_rate += beta_vector[contacted_group.age] * contact_rate \
                                     * (infectious_contacted/total_node_pop)
            # Apply VE to the susceptible group (focal group)
            transmission_rate *= (1.0 - vaccine_effectiveness) * self.relative_susceptibility[focal_group.age]
            #print(f"{node.node_id}, {focal_group}, transmission_rate: {transmission_rate}")
            transmission_rate = max(transmission_rate, 0) # Can't have negative transmission_rate
            transmission_prob = 1.0 - np.exp(-transmission_rate)
            #print(f"transmission probability: {transmission_prob}")

            model_parameters = (
                transmission_prob,     # S => E
                self.tau,              # E => A
                self.kappa,            # A => I
                self.chi,              # retained; T entry is stockpile-controlled
                self.gamma,            # I/T => R
                nu                     # I/T => D
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEAITRD_model(focal_group_compartments_today, *model_parameters)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            compartments_tomorrow = np.maximum(compartments_tomorrow, 0.0)
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return
