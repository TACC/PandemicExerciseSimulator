#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from src.models.disease.DiseaseModel import DiseaseModel
from src.baseclasses.Group import Group, RiskGroup, VaccineGroup
from src.baseclasses.Node import Node
from src.models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)

def SEIRS_model(y, transmission_prob, sigma, gamma, omega):
    """
    SEIRS compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, I, R]
        transmission_prob (float): beta modified by NPIs, vaccine effectiveness, contact rate,
                                   has I/N hidden in it to do node based proportion of population infectious
                                   Transmission rate converted to probability to keep between 0 and 1
        sigma (float): 1/Latency period in days (exposed to infectious E->I)
        gamma (float): 1/infectious period in days (infectious to recovered)
        omega (float): 1/time to lose immunity in days (recovered to susceptible)
    Returns:
       List[float]: Derivatives [dS/dt, dE/dt, dI/dt, dR/dt].
   """
    S, E, I, R = y

    # Prevent S from going negative by only removing as many people remain in the compartment
    max_new_infections = min(transmission_prob * S, S)
    dS_dt = -max_new_infections + omega * R
    dE_dt = max_new_infections - sigma * E
    dI_dt = sigma * E - gamma * I
    dR_dt = gamma * I - omega * R

    return np.array([dS_dt, dE_dt, dI_dt, dR_dt])

class DeterministicSEIRS(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]): # add antiviral_model
        self.now = disease_model.now
        self.parameters = disease_model.parameters

        self.R0    = float(self.parameters.disease_parameters['R0'])
        self.sigma = 1 / float(self.parameters.disease_parameters['latent_period_days'])
        self.gamma = 1 / float(self.parameters.disease_parameters['infectious_period_days'])
        immune_period = float(self.parameters.disease_parameters.get('immune_period_days', 0))
        if immune_period == 0 or not immune_period:
            self.omega = 0
        else:
            self.omega = 1 / immune_period

        # beta is a required name for _calculate_beta_w_npi
        self.beta  = self.R0 * self.gamma

        # Relative susceptibility required for travel model, make 1's if not specified
        num_age_grps = self.parameters.number_of_age_groups
        self.relative_susceptibility = [
            float(x) for x in self.parameters.disease_parameters.get(
                "relative_susceptibility", [1.0] * num_age_grps
            )]

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
        Main simulation logic for deterministic SEIR model.
        Each group (age, risk, vaccine) is simulated separately via ODE.

        S = Susceptible, E = Exposed, I = Infectious, R = Recovered
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

                # contacted_group_compartments_today
                S, E, I, R = compartments_today[(contacted_group.age, contacted_group.risk, contacted_group.vaccine)]
                infectious_contacted = I

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
                self.sigma,            # E => I
                self.gamma,            # I => R
                self.omega             # R => S
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEIRS_model(focal_group_compartments_today, *model_parameters)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return


