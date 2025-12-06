import numpy as np
import logging
from typing import Type
from icecream import ic
ic.disable()

from models.treatments.Vaccination import Vaccination
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.Group import Group, VaccineGroup, Compartments

logger = logging.getLogger(__name__)

class AgeRiskVaccineStockpileStrategy(Vaccination):
    def __init__(self, vaccine_model:Type[Vaccination], network:Type[Network]):
        """
        Args:
            vaccine_model (Vaccination):
            network (Network): Network object with all nodes
        """
        self.parameters    = vaccine_model.parameters
        # VE defined in parent class as it's needed by travel and disease model even with no vaccination, i.e. VE=0
        self.vaccine_effectiveness = vaccine_model.vaccine_effectiveness
        self.vaccine_effectiveness_hosp = vaccine_model.vaccine_effectiveness_hosp

        # If no age-risk priority groups provided then everyone is eligible for vaccination
        num_age_grps = self.parameters.number_of_age_groups
        self.age_risk_priority_groups = [
            float(x) for x in self.parameters.vaccine_parameters.get(
                "age_risk_priority_groups", [1.0] * num_age_grps  # default: everyone eligible
            )
        ]
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

        # Vaccine eligible population across all nodes
        self.network_population = sum(
            node.compartments.vaccine_eligible_population(self.age_risk_priority_groups,
                only_unvaccinated=False, only_susceptible=False)
            for node in network.nodes
        )

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
            node_population = node.compartments.vaccine_eligible_population(
                self.age_risk_priority_groups, only_unvaccinated=False, only_susceptible=False)
            if node_population <= 0:
                # still append so largest-remainder logic can run deterministically
                node_allocs.append({"node": node.node_id, "alloc": 0, "remainder": 0.0})
                continue

            fractional_share = stockpile_today * (node_population / self.network_population)
            floor_alloc = int(fractional_share)
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
        if vaccines_in_stockpile <= 0: # shouldn't be less than 0
            return
        else:
            ic(f">>>>>>>>>>>>>>>>>>>> Day {day} for Node {node.node_id} <<<<<<<<<<<<<<<<<<<<<<")
            ic(vaccines_in_stockpile)

        # Do half life daily decay if there is one for stockpile release beyond day 0
        # Day 0 is meant to be a hard N number people vaccinated before epidemic, not real time effects
        if self.daily_vaccine_wastage is not None and day > 0:
            vaccines_in_stockpile *= self.daily_vaccine_wastage
            self.node_stockpile_by_day[node.node_id][day] = vaccines_in_stockpile
            ic(f"New Stockpile count after decay: {vaccines_in_stockpile}")

        # Cap the fraction of pop that can be vaccinated
        # This could be better as a property of the node like node.max_vax_per_day() if we get node specific
        if day > 0 or self.vaccine_capacity < 1.0:
            max_vax_per_day = np.floor(self.vaccine_capacity * node.total_population())
            vax_given_today = min(max_vax_per_day, vaccines_in_stockpile)
        else:
            vax_given_today = min(node.total_population(), vaccines_in_stockpile)
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
            ic(f"Node {node.node_id}, Day {day}: {total_vax_to_rollover} leftover vaccines rolled over to day {day + 1}.")


    def _allocate_within_node(self, node, available_vaccines):
        # No vax passed to allocate
        if available_vaccines <= 0:
            return available_vaccines

        # Get total eligible & unvaccinated & susceptible
        total_eligible_s = node.compartments.vaccine_eligible_population(
            self.age_risk_priority_groups,
            only_unvaccinated=True, only_susceptible=True)
        ic(total_eligible_s)
        if total_eligible_s <= 0:
            # nobody eligible in this node today; roll everything over
            return available_vaccines

        # Returns list of (age, risk, sus_unvax)
        eligible_groups = node.compartments.vaccine_eligible_by_group(
            self.age_risk_priority_groups,
            only_unvaccinated=True, only_susceptible=True)
        ic(eligible_groups)

        EPS = 1e-9 # epsilon precision error to check numbers very close to 0
        group_allocs = []
        total_headroom = 0.0
        for (age, risk, sus_unvax) in eligible_groups:
            # Per-age adherence ceiling in [0,1]
            adherence = float(self.vaccine_adherence[age])

            # Current unvax and vax vectors
            unvax_vec = node.compartments.get_compartment_vector_for(
                Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.U.value)
            )
            vax_vec = node.compartments.get_compartment_vector_for(
                Group(age=age, risk_group=risk, vaccine_group=VaccineGroup.V.value)
            )
            cum_vax = float(np.sum(vax_vec))  # ever vaccinated so far (all compartments in V group)
            # Calculating total pop every time in case we ever have models with birth/death changing S in time
            total_grp_pop = float(np.sum(unvax_vec) + cum_vax)

            # Remaining ceiling and eligibility headroom today
            cap_remaining = max(0.0, adherence * total_grp_pop - cum_vax)
            eligible_headrm = max(0.0, min(float(sus_unvax), cap_remaining))
            total_headroom += eligible_headrm

            group_allocs.append({
                "age": age,
                "risk": risk,
                "unvax_group": Group(age, risk, VaccineGroup.U.value),
                "vax_group": Group(age, risk, VaccineGroup.V.value),
                "sus": float(sus_unvax),
                "adherence": adherence,
                "total_grp_pop": total_grp_pop,
                "cum_vax": cum_vax,
                "cap_remaining": cap_remaining,
                "eligible_headroom": eligible_headrm,
                # will fill expected/alloc/remainder below
            })

        # If no one has headroom under adherence, roll everything
        if total_headroom <= EPS:
            return available_vaccines

        # Vax proportions by adherence-aware headroom (not raw susceptibles remaining)
        for g in group_allocs:
            share = g["eligible_headroom"] / total_headroom if total_headroom > 0 else 0.0
            expected = available_vaccines * share
            # Bound by headroom
            alloc_float = min(expected, g["eligible_headroom"])
            floor_alloc = np.floor(alloc_float + EPS)

            # Remainder for fair leftover distribution (based on expected share)
            remainder = expected - np.floor(expected + EPS)

            # How many more doses this group can still take after flooring (respecting both sus & cap)
            max_extra = max(0.0, g["eligible_headroom"] - floor_alloc)
            g["expected"] = float(expected)
            g["alloc"] = float(floor_alloc)
            g["remainder"] = float(remainder)
            g["max_extra"] = float(max_extra)

        ic(group_allocs)

        # Leftovers (only if real positive remainders AND headroom exists)
        vaccines_given = sum(g["alloc"] for g in group_allocs); ic(vaccines_given)
        raw_leftover = available_vaccines - vaccines_given; ic(raw_leftover)
        leftover_node_vax = int(max(0, np.floor(raw_leftover + EPS))); ic(leftover_node_vax)

        if leftover_node_vax > 0:
            candidates = [g for g in group_allocs if g["max_extra"] > EPS and g["remainder"] > EPS]
            if candidates:
                candidates.sort(key=lambda x: x["remainder"], reverse=True)
                for i in range(min(leftover_node_vax, len(candidates))):
                    candidates[i]["alloc"] += 1.0
                    candidates[i]["max_extra"] = max(0.0, candidates[i]["max_extra"] - 1.0)

        # Move people U -> V using the strategy's vaccinate function
        for g in group_allocs:
            if g["alloc"] > 0:
                self.vaccinate_number_of_people(
                    node,
                    g["unvax_group"],  # from U
                    g["vax_group"],  # to V
                    int(g["alloc"])
                )

        # Return any remaining vaccines (if none could be used)
        final_given = sum(g["alloc"] for g in group_allocs); ic(final_given)
        return int(available_vaccines - final_given)

