import numpy as np
import logging
from typing import Type
from icecream import ic
ic.disable()

from .Vaccination import Vaccination
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.Group import Group, VaccineGroup, Compartments

logger = logging.getLogger(__name__)

class UniformVaccineStockpileStrategy(Vaccination):
    def __init__(self, vaccine_model:Type[Vaccination], network:Type[Network]):
        """
        Args:
            vaccine_model (Vaccination):
            network (Network): Network object with all nodes
        """
        self.parameters    = vaccine_model.parameters
        # VE defined in parent class as it's needed by travel and disease model even with no vaccination, i.e. VE=0
        self.vaccine_effectiveness = vaccine_model.vaccine_effectiveness

        # need to re-name, it is int days of vaccine half life (60 days)
        self.vaccine_wastage_factor = float(self.parameters.vaccine_parameters.get('vaccine_wastage_factor', 0))
        self.vaccine_adherence      = [ # age specific float 0.0 to 1.0, but need by any county/risk/breakout
            float(x) for x in self.parameters.vaccine_parameters.get('vaccine_adherence', []) ]

        # non-negative int of when vax is effective (14 days)
        input_vax_lag               = self.parameters.vaccine_parameters.get('vaccine_eff_lag_days', 0)
        self.vaccine_eff_lag_days   = max(int(input_vax_lag), 0)

        # list of dictionaries but in non-stockpile strategy will be CSV file with re-name from "stockpile" to vax given
        self.vaccine_stockpile      = self.parameters.vaccine_parameters.get('vaccine_stockpile', [])

        # Convert list of dicts to {day: amount}
        # Leaving in child class in case we want to take in proportions, but leaning toward count only intake
        self.stockpile_by_day = {}
        day_collision_tracker = {}
        for entry in self.vaccine_stockpile:
            stockpile_day = int(entry["day"])
            amount = float(entry["amount"])

            # Shift by effectiveness lag
            effective_day = stockpile_day + self.vaccine_eff_lag_days

            # Set any negative effective days to day 0, allows for easy shifting of vax release date
            if effective_day < 0:
                logger.warning(
                    f"Effective day {effective_day} is negative (stockpile day {stockpile_day}); reassigning to day 0")
                effective_day = 0

            # Check if this day already has an entry
            if effective_day in self.stockpile_by_day:
                logger.warning(
                    f"Multiple vaccine stockpile entries assigned to day {effective_day}; combining amounts.")
                day_collision_tracker.setdefault(effective_day, []).append(stockpile_day)

            self.stockpile_by_day.setdefault(effective_day, 0.0)
            self.stockpile_by_day[effective_day] += amount

        # Optionally log all combined day mappings at once
        for day, original_days in day_collision_tracker.items():
            logger.debug(f"Day {day} combines stockpile from original days: {original_days}")

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
            logger.warning("Total population is 0; skipping vaccination.")
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

        logger.debug(f"Day {day} — Node {node.node_id} gets {node_share} vaccines; "
                    f"{self.stockpile_by_day[day]:.0f} remaining")
        ic(f"Day {day} — Node {node.node_id} gets {node_share} vaccines; "
                    f"{self.stockpile_by_day[day]:.0f} remaining")

        # Allocate vaccines released on day
        leftover_vax = self._allocate_within_node(node, node_share)
        ic(leftover_vax)
        # If any vaccines remain after trying to distribute them all then save to next day
        if leftover_vax > 0:
            self.stockpile_by_day.setdefault(day + 1, 0.0)
            self.stockpile_by_day[day + 1] += leftover_vax
            logger.debug(f"Day {day}: {leftover_vax} leftover vaccines rolled over to day {day + 1}.")
            ic(f"Day {day}: {leftover_vax} leftover vaccines rolled over to day {day + 1}.")

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
            # still need vaccines_left to be an integer on return
            return 0

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
            
            adherence = float(self.vaccine_adherence[age])
            ic(adherence)

            # Compute this group’s "share" of the total eligible population
            proportion = sus_unvax / total_sus_unvax
            ic(sus_unvax)
            ic(total_sus_unvax)
            ic(proportion)

            # Debating this, may just keep all the same and stick with rollover
            '''
            # If this is the LAST group in the list, give them ALL the remaining doses
            if i == len(eligible_groups) - 1:
                num_to_vaccinate = vaccines_left
            else:
            '''
            # Compute expected vaccines for this group (share * adherence)
            num_to_vaccinate = round((vaccines_left * proportion * adherence), 0)
            ic("First calc:", num_to_vaccinate)
            # Safety: don't assign more than what's left
            num_to_vaccinate = round(min(num_to_vaccinate, vaccines_left), 0)
            ic("Vaccines left cap:", num_to_vaccinate)

            # Cap at the number of susceptible people in this group (can't vaccinate more than exist)
            num_to_vaccinate = round(min(num_to_vaccinate, sus_unvax), 0)
            ic("Sus Unvax cap:", num_to_vaccinate)

            ic(VaccineGroup.U.value) # 0 as this is the unvax group
            ic(VaccineGroup.V.value) # 1 as it's vaccinated group
            # Build the group descriptors
            unvax_group = Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.U.value)
            vax_group   = Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.V.value)

            # Actually move the people between compartments
            self.vaccinate_number_of_people(
                node, unvax_group, vax_group, num_to_vaccinate
            )

            # Subtract used vaccines from the remaining pool
            vaccines_left -= num_to_vaccinate
            ic(vaccines_left)
            # If we’ve used up all vaccines, stop early
            if vaccines_left <= 0:
                break

        return vaccines_left
