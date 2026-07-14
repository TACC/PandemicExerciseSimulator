#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from .DiseaseModel import DiseaseModel
from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Node import Node
from models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)

def SEAITRD_model(
    y,
    transmission_prob,
    E_to_A_rate,
    A_to_I_rate,
    T_to_I_rate,
    I_to_R_rate,
    T_to_R_rate,
    I_to_D_rate,
    T_to_D_rate,
):
    """
    SEAITRD compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, A, I, T, R, D]
        transmission_prob (float): beta modified by NPIs, vaccine effectiveness, contact rate, relative susceptibility (sigma),
                                   has (A+I+T)/N hidden in it to do node based proportion of population infectious
                                   Transmission rate converted to probability to keep between 0 and 1
        E_to_A_rate (float): Exposed to asymptomatic rate in 1/days
        A_to_I_rate (float): Asymptomatic to infectious rate in 1/days
        T_to_I_rate (float): Retained for input compatibility; treatment is stockpile-controlled
        I_to_R_rate (float): Infectious recovery rate in 1/days
        T_to_R_rate (float): Treated recovery rate in 1/days
        I_to_D_rate (float): Infectious mortality rate in 1/days
        T_to_D_rate (float): Treated mortality rate in 1/days
    Returns:
       List[float]: Derivatives in the same compartment order as y.
   """
    if len(y) != 7:
        raise ValueError("SEAITRD requires compartments [S, E, A, I, T, R, D].")
    S, E, A, I, T, R, D = y

    # Prevent S from going negative by only removing as many people remain in the compartment
    max_new_infections = min(transmission_prob * S, S)
    e_to_a = min(E_to_A_rate * E, E)
    a_to_i = min(A_to_I_rate * A, A)

    infectious_exit_rate = I_to_R_rate + I_to_D_rate
    infectious_exit = min(infectious_exit_rate * I, I)
    infectious_recovery_share = I_to_R_rate / infectious_exit_rate if infectious_exit_rate > 0 else 0.0

    treated_exit_rate = T_to_R_rate + T_to_D_rate
    treated_exit = min(treated_exit_rate * T, T)
    treated_recovery_share = T_to_R_rate / treated_exit_rate if treated_exit_rate > 0 else 0.0

    i_to_r = infectious_recovery_share * infectious_exit
    i_to_d = infectious_exit - i_to_r
    t_to_r = treated_recovery_share * treated_exit
    t_to_d = treated_exit - t_to_r

    dS_dt = -max_new_infections
    dE_dt = max_new_infections - e_to_a

    dA_dt = e_to_a - a_to_i
    dI_dt = a_to_i - i_to_r - i_to_d
    dT_dt = -t_to_r - t_to_d

    dR_dt = i_to_r + t_to_r
    dD_dt = i_to_d + t_to_d

    return np.array([dS_dt, dE_dt, dA_dt, dI_dt, dT_dt, dR_dt, dD_dt])

class DeterministicSEAITRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]): # add antiviral_model
        self.now = disease_model.now
        self.parameters = disease_model.parameters

        self.R0             = float(self.parameters.disease_parameters['R0'])
        self.beta_scale     = float(self.parameters.disease_parameters['beta_scale'] )   # "R0CorrectionFactor"
        self.beta           = self.R0 / self.beta_scale

        # the following four parameters are provided by users as periods (units = days),
        # but then stored here as rates (units = 1/days)
        self.E_to_A_rate    = 1/float(self.parameters.disease_parameters['E_to_A_days'])
        self.A_to_I_rate    = 1/float(self.parameters.disease_parameters['A_to_I_days'])
        self.I_to_R_rate    = 1/float(self.parameters.disease_parameters['I_to_R_days'])
        self.T_to_I_rate    = 1/float(self.parameters.disease_parameters['T_to_I_days'])

        compartment_labels = [
            str(label).upper()
            for label in self.parameters.disease_parameters.get('compartments', [])
        ]
        if "T" not in compartment_labels:
            raise ValueError("SEAITRD requires the T compartment.")
        self.compartment_index = {
            label: index
            for index, label in enumerate(compartment_labels)
        }
        if 'T_to_R_days' in self.parameters.disease_parameters:
            self.T_to_R_rate = 1 / float(self.parameters.disease_parameters['T_to_R_days'])
        else:
            antiviral_parameters = getattr(self.parameters, "antiviral_parameters", {})
            if antiviral_parameters:
                raise ValueError("T_to_R_days is required when antiviral treatment can create T.")
            logger.warning(
                "T compartment specified without T_to_R_days; defaulting T_to_R_days to I_to_R_days."
            )
            self.T_to_R_rate = self.I_to_R_rate

        # the user enters one I_to_D rate value for each age group, assumed to be low risk
        # population. use multiplier 9x to derive values for high risk population
        self.I_to_D_rates_by_risk      = [[],[]]
        self.I_to_D_rates_by_risk[0]   = [float(x)   for x in self.parameters.disease_parameters['I_to_D_invdays']]
        self.I_to_D_rates_by_risk[1]   = [float(x)*9 for x in self.parameters.disease_parameters['I_to_D_invdays']]

        # Transpose rates so that we can access values as rates[age][risk].
        self.I_to_D_rates_by_risk = np.array(self.I_to_D_rates_by_risk).transpose().tolist()

        antiviral_parameters = getattr(self.parameters, "antiviral_parameters", {})
        if antiviral_parameters and 'antiviral_effectiveness_death' not in antiviral_parameters:
            raise ValueError("antiviral_effectiveness_death is required when antiviral treatment can create T.")
        self.antiviral_effectiveness_death = DiseaseModel.age_values(
            antiviral_parameters.get('antiviral_effectiveness_death', 0.0),
            self.parameters.number_of_age_groups,
        )
        if not all(0.0 <= eff <= 1.0 for eff in self.antiviral_effectiveness_death):
            raise ValueError(
                f"Found invalid antiviral_effectiveness_death values: {self.antiviral_effectiveness_death}"
            )
        self.T_to_D_rates_by_risk = [
            [
                I_to_D_rate * (1.0 - self.antiviral_effectiveness_death[age])
                for I_to_D_rate in age_rates
            ]
            for age, age_rates in enumerate(self.I_to_D_rates_by_risk)
        ]

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

            I_to_D_rate = float(self.I_to_D_rates_by_risk[focal_group.age][focal_group.risk])
            T_to_D_rate = float(self.T_to_D_rates_by_risk[focal_group.age][focal_group.risk])

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
                T = contacted_compartments[self.compartment_index["T"]]
                infectious_contacted = A + I + T

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
                self.E_to_A_rate,      # E => A
                self.A_to_I_rate,      # A => I
                self.T_to_I_rate,      # retained; T entry is stockpile-controlled
                self.I_to_R_rate,      # I => R
                self.T_to_R_rate,      # T => R
                I_to_D_rate,           # I => D
                T_to_D_rate            # T => D
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEAITRD_model(focal_group_compartments_today, *model_parameters)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            compartments_tomorrow = np.maximum(compartments_tomorrow, 0.0)
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return
