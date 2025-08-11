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

        # Vaccine half life in days, typically 60
        self.vaccine_half_life_days = self.parameters.vaccine_parameters.get('vaccine_half_life_days', None)
        if self.vaccine_half_life_days is not None:
            self.daily_vaccine_wastage  = 0.5 ** (1 / self.vaccine_half_life_days)
        else:
            self.daily_vaccine_wastage = None
        # 0.0 to 1.0 fraction of the population that can be vaccinated per day, default no limit
        self.vaccine_capacity       = float(self.parameters.vaccine_parameters.get("vaccine_capacity_proportion", 1.0))
        self.vaccine_adherence      = [ # age specific float 0.0 to 1.0, but need by any county/risk/breakout
            float(x) for x in self.parameters.vaccine_parameters.get('vaccine_adherence', []) ]
        # non-negative int of when vax is effective (14 days)
        input_vax_lag               = self.parameters.vaccine_parameters.get('vaccine_eff_lag_days', 0)
        self.vaccine_eff_lag_days   = max(int(input_vax_lag), 0)
        # list of dictionaries but in non-stockpile strategy will be CSV file with re-name from "stockpile" to vax given
        self.vaccine_stockpile      = self.parameters.vaccine_parameters.get('vaccine_stockpile', [])

        # Convert list of dicts to {day: amount}
        # Leaving in child class in case we want to take in proportions, but leaning toward count only intake
        self.network_stockpile_by_day = {}
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
            if effective_day in self.network_stockpile_by_day:
                logger.warning(
                    f"Multiple vaccine stockpile entries assigned to day {effective_day}; combining amounts.")
                day_collision_tracker.setdefault(effective_day, []).append(stockpile_day)

            self.network_stockpile_by_day.setdefault(effective_day, 0.0)
            self.network_stockpile_by_day[effective_day] += amount

        # Log all combined day mappings in as warning
        for day, original_days in day_collision_tracker.items():
            logger.warning(f"Day {day} combines stockpile from original days: {original_days}")

        # Create node specific stockpile dictionaries
        self.node_stockpile_by_day = {node.node_id: {} for node in network.nodes}

        # Total population across all nodes
        self.network_population = sum(node.total_population() for node in network.nodes)

    # Uniform vaccination strategy only considers proportion of total population in each node
    def distribute_vaccines_to_nodes(self, network, day):
        """
        Called from simulate.py once per day.
        Allocates stockpile amount to nodes in network.

        Args:
            network (Network): The network to distribute vaccines to
            day (int): Current day in simulation
        """
        if day not in self.network_stockpile_by_day:
            return

        stockpile_today = float(self.network_stockpile_by_day[day])
        if stockpile_today <= 0:
            return

        if self.network_population == 0:
            logger.warning("Total population in network is 0, define a population to continue.")
            return

        # Proportional allocation of vaccines to nodes
        node_allocs = []  # list of dicts
        total_floor = 0
        for node in network.nodes:
            node_population = node.total_population()
            fractional_share = stockpile_today * (node_population / self.network_population)
            floor_alloc = int(fractional_share)  # keep your int() rounding
            remainder = fractional_share - floor_alloc
            node_allocs.append({
                "node": node.node_id,
                "alloc": floor_alloc,
                "remainder": remainder
            })
            total_floor += floor_alloc

        # Distribute leftover vaccines by largest remainder
        leftover_vax = int(round(stockpile_today - total_floor))
        if leftover_vax > 0:
            node_allocs.sort(key=lambda x: x["remainder"], reverse=True)
            # Extra protection but leftover_vax should always be <= total nodes
            for i in range(min(leftover_vax, len(node_allocs))):
                node_allocs[i]["alloc"] += 1

        ic(node_allocs)

        # Update node-specific stockpiles
        for n in node_allocs:
            alloc = int(n["alloc"])
            if alloc <= 0:
                continue
            node_id = n["node"]
            self.node_stockpile_by_day[node_id].setdefault(day, 0.0)
            self.node_stockpile_by_day[node_id][day] += alloc

        # Stockpile today in network should be 0 as all vaccines are allocated to some node in network
        leftover_check = sum(n["alloc"] for n in node_allocs)
        self.network_stockpile_by_day[day] -= leftover_check
        ic(self.network_stockpile_by_day[day])

    def distribute_vaccines_to_population(self, node, day):
        """
        Called from simulate.py once per day per node.
        Allocates stockpile amount to the node and distributes among its age/risk groups.

        Args:
            node (Node): The node receiving vaccine
            day (int): Current day in simulation
        """
        # If no more vaccines in stockpile skip
        vaccines_in_stockpile = float(self.node_stockpile_by_day[node.node_id].get(day, 0.0))
        ic(vaccines_in_stockpile)
        if vaccines_in_stockpile <= 0: # shouldn't be less than 0
            return

        # Do half life check
        if self.daily_vaccine_wastage is not None:
            vaccines_in_stockpile *= self.daily_vaccine_wastage
            self.node_stockpile_by_day[node.node_id][day] = vaccines_in_stockpile
            ic(f"New Stockpile count after decay: {vaccines_in_stockpile}")

        # Cap the fraction of pop that can be vaccinated
        # This could be better as a property of the node like node.max_vax_per_day()
        # Might not be correct given age specific adherence, but doing this for now
        max_vax_per_day = np.floor(self.vaccine_capacity * node.total_population())
        vax_given_today = min(max_vax_per_day, vaccines_in_stockpile)
        ic(vax_given_today)
        # when stockpile less than max given the remaining will zero out, even for non-integer doses
        # i.e. any dose < 1 due to decay will be lost and not rolled over
        remaining_stockpile = vaccines_in_stockpile - vax_given_today
        ic(remaining_stockpile)

        # Allocate vaccines released on day
        leftover_vax_not_distributed = self._allocate_within_node(node, vax_given_today)
        ic(leftover_vax_not_distributed)
        total_vax_to_rollover = remaining_stockpile + leftover_vax_not_distributed
        ic(total_vax_to_rollover)
        # If any vaccines remain after trying to distribute them all then save to next day
        if total_vax_to_rollover > 0:
            self.node_stockpile_by_day[node.node_id].setdefault(day + 1, 0.0)
            self.node_stockpile_by_day[node.node_id][day + 1] += total_vax_to_rollover
            logger.debug(f"Day {day}: {total_vax_to_rollover} leftover vaccines rolled over to day {day + 1}.")
            ic(f"Day {day}: {total_vax_to_rollover} leftover vaccines rolled over to day {day + 1}.")


    def _allocate_within_node(self, node, available_vaccines):
        # Prepare a snapshot of today's compartment state so we aren't using updated values mid-loop
        compartments_today = {
            (group.age, group.risk, group.vaccine): np.array(node.compartments.get_compartment_vector_for(group))
            for group in node.compartments.get_all_groups()
        }

        # Create a list of all unvaccinated groups with susceptibles.
        # Each item is a tuple: (age, risk, susceptible count)
        eligible_groups = [
            (age, risk, comp[Compartments.S.value])
            for (age, risk, vaccine), comp in compartments_today.items()
            if vaccine == VaccineGroup.U.value and comp[Compartments.S.value] > 0
        ]

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

        group_allocs = []
        for (age, risk, sus_unvax) in eligible_groups:
            proportion = sus_unvax / total_sus_unvax
            adherence = float(self.vaccine_adherence[age])
            expected = available_vaccines * proportion * adherence
            floor_alloc = min(np.floor(expected), sus_unvax)
            remainder = expected - floor_alloc
            group_allocs.append({
                "group": Group(age, risk, VaccineGroup.U.value),
                "vax_group": Group(age, risk, VaccineGroup.V.value),
                "sus": sus_unvax,
                "alloc": floor_alloc,
                "remainder": remainder
            })

        # Distribute leftover vaccines
        vaccines_given = sum(g["alloc"] for g in group_allocs)
        leftover_node_vax = int(available_vaccines - vaccines_given)
        ic(leftover_node_vax)
        group_allocs.sort(key=lambda x: x["remainder"], reverse=True) # Sort by who had the biggest leftover (remainder)
        for i in range(min(leftover_node_vax, len(group_allocs))):
            g = group_allocs[i]
            if g["alloc"] < g["sus"]:  # still susceptibles to vaccinate
                g["alloc"] += 1

        ic(group_allocs)

        # Update compartments
        for g in group_allocs:
            self.vaccinate_number_of_people(
                node,
                g["group"],  # unvaccinated group
                g["vax_group"],  # vaccinated group
                g["alloc"]
            )

        # Return any remaining vaccines (if none could be used)
        final_given = sum(g["alloc"] for g in group_allocs)
        return int(available_vaccines - final_given)

