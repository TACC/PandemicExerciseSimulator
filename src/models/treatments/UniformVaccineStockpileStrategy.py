import numpy as np
import logging
from typing import Type
from icecream import ic
ic.disable()

from baseclasses.Group import Group, VaccineGroup, Compartments
from baseclasses.Node import Node
from baseclasses.Network import Network


class UniformVaccineStockpileStrategy:
    def __init__(self, vaccination, network):
        """
        Args:
            vaccination (Vaccination): An instance of the Vaccination class
            network (Network): Network object with all nodes
        """
        self.vaccination = vaccination

        # Convert list of dicts to {day: amount}
        self.stockpile_by_day = {
            int(entry["day"]) + self.vaccination.vaccine_eff_lag_days: float(entry["amount"])
            for entry in self.vaccination.vaccine_stockpile
        }

        # Total population across all nodes
        self.total_population = sum(node.total_population() for node in network.nodes)

    # Uniform vaccination strategy only considers proportion of total population in each node
    def distribute_vaccines(self, node, day):
        """
        Called from simulate.py once per day per node.
        Allocates stockpile amount to the node and distributes among its age/risk groups.

        Args:
            node (Node): The node receiving vaccine
            day (int): Current day in simulation
        """
        if day not in self.stockpile_by_day:
            return

        if self.total_population == 0:
            logging.warning("Total population is 0; skipping vaccination.")
            return

        stockpile_today = self.stockpile_by_day[day]

        # Proportional allocation
        node_population = node.total_population()
        if node_population == 0:
            return

        # Calculate ideal share, round down to integer
        fractional_share = stockpile_today * (node_population / self.total_population)
        node_share = round(fractional_share, 0)  # round to whole doses

        if node_share == 0.0:
            return  # skip this node if its share is <1

        # Cap node share if stockpile doesn't have enough left
        node_share = min(node_share, self.stockpile_by_day[day])
        self.stockpile_by_day[day] -= node_share

        logging.debug(f"Day {day} — Node {node.node_id} gets {node_share} vaccines; "
                    f"{self.stockpile_by_day[day]:.0f} remaining")

        self._allocate_within_node(node, node_share)


    def _allocate_within_node(self, node, available_vaccines):
        # Prepare a snapshot of today's compartment state so we aren't using updated values mid-loop
        compartments_today = {
            (group.age, group.risk, group.vaccine): np.array(node.compartments.get_compartment_vector_for(group))
            for group in node.compartments.get_all_groups()
        }

        # Calculate total susceptible *unvaccinated* population across all age/risk groups in the node
        total_sus_unvax = sum(
            comp[Compartments.S.value]  # number of susceptibles in that group
            for (age, risk, vaccine), comp in compartments_today.items()
            if vaccine == VaccineGroup.U.value  # only include unvaccinated
        )
        ic(total_sus_unvax)
        # If there are no eligible people or no vaccines, skip
        if total_sus_unvax == 0 or available_vaccines <= 0:
            return

        # Create a list of all unvaccinated groups with susceptibles.
        # Each item is a tuple: (age, risk, susceptible count)
        eligible_groups = [
            (age, risk, comp[Compartments.S.value])
            for (age, risk, vaccine), comp in compartments_today.items()
            if vaccine == VaccineGroup.U.value and comp[Compartments.S.value] > 0
        ]

        # Track remaining vaccines to give out as we loop
        vaccines_left = available_vaccines
        ic(vaccines_left)
        # Loop through all eligible age/risk groups to distribute vaccines
        for i, (age, risk, sus_unvax) in enumerate(eligible_groups):

            # Get adherence for this age group (what fraction will accept a vaccine)
            ic(age)
            ic(risk)
            
            adherence = float(self.vaccination.vaccine_adherence[age])
            ic(adherence)

            # Compute this group’s "share" of the total eligible population
            proportion = sus_unvax / total_sus_unvax
            ic(sus_unvax)
            ic(total_sus_unvax)
            ic(proportion)

            # If this is the LAST group in the list, give them ALL the remaining doses
            if i == len(eligible_groups) - 1:
                num_to_vaccinate = vaccines_left
            else:
                # Compute expected vaccines for this group (share * adherence)
                num_to_vaccinate = round((vaccines_left * proportion * adherence), 0)
                ic(num_to_vaccinate)
                # Safety: don't assign more than what's left
                num_to_vaccinate = round(min(num_to_vaccinate, vaccines_left), 0)
                ic(num_to_vaccinate)

            # Cap at the number of susceptible people in this group (can't vaccinate more than exist)
            num_to_vaccinate = round(min(num_to_vaccinate, sus_unvax), 0)
            ic(num_to_vaccinate)

            ic(VaccineGroup.U.value)
            # Build the group descriptors
            unvax_group = Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.U.value)
            vax_group = Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.V.value)

            # Actually move the people between compartments
            self.vaccination.vaccinate_number_of_people(
                node, unvax_group, vax_group, num_to_vaccinate
            )

            # Subtract used vaccines from the remaining pool
            vaccines_left -= num_to_vaccinate
            ic(vaccines_left)
            # If we’ve used up all vaccines, stop early
            if vaccines_left <= 0:
                break
