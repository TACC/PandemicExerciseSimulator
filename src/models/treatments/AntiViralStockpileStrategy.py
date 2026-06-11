#!/usr/bin/env python3
import logging
import numpy as np
from typing import Type

from baseclasses.Group import Group, RiskGroup, VaccineGroup, Compartments
from baseclasses.Network import Network
from baseclasses.Node import Node
from models.treatments.Antiviral import Antiviral

logger = logging.getLogger(__name__)


class AntiviralStockpileStrategy(Antiviral):
    def __init__(self, antiviral_model: Type[Antiviral], network: Type[Network]):
        self.parameters = antiviral_model.parameters

        if not hasattr(Compartments, "T"):
            raise ValueError("Antiviral stockpile strategy requires a T compartment.")

        num_age_grps = self.parameters.number_of_age_groups
        self.age_risk_priority_groups = [
            float(x) for x in self.parameters.antiviral_parameters.get(
                "age_risk_priority_groups", [1.0] * num_age_grps
            )
        ]
        if len(self.age_risk_priority_groups) != num_age_grps:
            raise ValueError(f"age_risk_priority_groups must have length {num_age_grps}")
        if any(priority not in (0.0, 0.5, 1.0) for priority in self.age_risk_priority_groups):
            raise ValueError("age_risk_priority_groups values must be 0, 0.5, or 1")

        self.eligible_compartments = [
            str(label).strip().upper()
            for label in self.parameters.antiviral_parameters.get(
                "eligible_compartments", ["E", "I"]
            )
        ]
        for label in self.eligible_compartments:
            if not hasattr(Compartments, label):
                raise ValueError(f"Eligible antiviral compartment {label} not in active compartments.")

        self.compartment_priority = [
            str(label).strip().upper()
            for label in self.parameters.antiviral_parameters.get(
                "compartment_priority", ["I", "E"]
            )
        ]
        for label in self.compartment_priority:
            if label not in self.eligible_compartments:
                raise ValueError(f"Priority compartment {label} must also be eligible.")

        self.antiviral_capacity = float(
            self.parameters.antiviral_parameters.get("antiviral_capacity_proportion", 1.0)
        )

        input_half_life = self.parameters.antiviral_parameters.get(
            "antiviral_half_life_days", None
        )
        self.antiviral_half_life_days = (
            float(input_half_life) if input_half_life is not None else None
        )
        if self.antiviral_half_life_days is not None:
            self.daily_antiviral_wastage = 0.5 ** (1 / self.antiviral_half_life_days)
        else:
            self.daily_antiviral_wastage = None

        self.antiviral_stockpile = self.parameters.antiviral_parameters.get(
            "antiviral_stockpile", []
        )
        self.network_stockpile_by_day = {}
        day_collision_tracker = {}
        for entry in self.antiviral_stockpile:
            stockpile_day = int(entry["day"])
            amount = float(entry["amount"])

            if stockpile_day < 0:
                logger.warning(f"Antiviral stockpile day {stockpile_day} is negative; reassigning to day 0")
                stockpile_day = 0

            if stockpile_day in self.network_stockpile_by_day:
                logger.warning(f"Multiple antiviral stockpile entries assigned to day {stockpile_day}; combining amounts.")
                day_collision_tracker.setdefault(stockpile_day, []).append(stockpile_day)

            self.network_stockpile_by_day.setdefault(stockpile_day, 0.0)
            self.network_stockpile_by_day[stockpile_day] += amount

        for day, original_days in day_collision_tracker.items():
            logger.warning(f"Antiviral day {day} combines stockpile from original days: {original_days}")

        self.node_stockpile_by_day = {node.node_id: {} for node in network.nodes}

    def distribute_antivirals_to_nodes(self, network: Type[Network], day: int):
        if day not in self.network_stockpile_by_day:
            return

        stockpile_today = float(self.network_stockpile_by_day[day])
        if stockpile_today <= 0:
            return

        network_eligible = sum(self._eligible_population(node) for node in network.nodes)
        if network_eligible <= 0:
            self._roll_network_stockpile(day, stockpile_today)
            self.network_stockpile_by_day[day] = 0.0
            return

        node_allocs = []
        total_floor = 0
        for node in network.nodes:
            node_eligible = self._eligible_population(node)
            if node_eligible <= 0:
                node_allocs.append({"node": node.node_id, "alloc": 0, "remainder": 0.0})
                continue

            fractional_share = stockpile_today * (node_eligible / network_eligible)
            floor_alloc = int(fractional_share)
            remainder = fractional_share - floor_alloc
            node_allocs.append({
                "node": node.node_id,
                "alloc": floor_alloc,
                "remainder": remainder,
            })
            total_floor += floor_alloc

        leftover = int(round(stockpile_today - total_floor))
        if leftover > 0:
            node_allocs.sort(key=lambda x: x["remainder"], reverse=True)
            for i in range(min(leftover, len(node_allocs))):
                node_allocs[i]["alloc"] += 1

        for alloc in node_allocs:
            amount = int(alloc["alloc"])
            if amount <= 0:
                continue
            node_id = alloc["node"]
            self.node_stockpile_by_day[node_id].setdefault(day, 0.0)
            self.node_stockpile_by_day[node_id][day] += amount

        distributed = sum(alloc["alloc"] for alloc in node_allocs)
        self.network_stockpile_by_day[day] -= distributed

    def distribute_antivirals_to_population(self, node: Type[Node], day: int):
        antivirals_in_stockpile = float(self.node_stockpile_by_day[node.node_id].get(day, 0.0))
        if antivirals_in_stockpile <= 0:
            return

        if self.daily_antiviral_wastage is not None and day > 0:
            antivirals_in_stockpile *= self.daily_antiviral_wastage
            self.node_stockpile_by_day[node.node_id][day] = antivirals_in_stockpile

        if day > 0 or self.antiviral_capacity < 1.0:
            max_antivirals_per_day = np.floor(self.antiviral_capacity * node.total_population())
            antivirals_available_today = min(max_antivirals_per_day, antivirals_in_stockpile)
        else:
            antivirals_available_today = min(node.total_population(), antivirals_in_stockpile)

        remaining_stockpile = antivirals_in_stockpile - antivirals_available_today
        leftover_not_distributed = self._allocate_within_node(node, antivirals_available_today)
        total_to_rollover = remaining_stockpile + leftover_not_distributed

        if total_to_rollover >= 1.0:
            self.node_stockpile_by_day[node.node_id].setdefault(day + 1, 0.0)
            self.node_stockpile_by_day[node.node_id][day + 1] += total_to_rollover
            logger.debug(f"Day {day}: {total_to_rollover} leftover antivirals rolled over to day {day + 1}.")

    def _allocate_within_node(self, node: Type[Node], available_antivirals: float) -> int:
        if available_antivirals <= 0:
            return int(available_antivirals)

        eligible_groups = self._eligible_by_group(node)
        total_eligible = sum(group["eligible"] for group in eligible_groups)
        if total_eligible <= 0:
            return int(available_antivirals)

        EPS = 1e-9
        for group in eligible_groups:
            expected = available_antivirals * (group["eligible"] / total_eligible)
            alloc_float = min(expected, group["eligible"])
            floor_alloc = np.floor(alloc_float + EPS)
            group["alloc"] = float(floor_alloc)
            group["remainder"] = float(expected - np.floor(expected + EPS))
            group["max_extra"] = float(max(0.0, group["eligible"] - floor_alloc))

        antivirals_given = sum(group["alloc"] for group in eligible_groups)
        raw_leftover = available_antivirals - antivirals_given
        leftover = int(max(0, np.floor(raw_leftover + EPS)))
        if leftover > 0:
            candidates = [
                group for group in eligible_groups
                if group["max_extra"] > EPS and group["remainder"] > EPS
            ]
            candidates.sort(key=lambda x: x["remainder"], reverse=True)
            for i in range(min(leftover, len(candidates))):
                candidates[i]["alloc"] += 1.0
                candidates[i]["max_extra"] = max(0.0, candidates[i]["max_extra"] - 1.0)

        for group in eligible_groups:
            self._treat_group(node, group["group"], int(group["alloc"]))

        final_given = sum(group["alloc"] for group in eligible_groups)
        return int(available_antivirals - final_given)

    def _eligible_by_group(self, node: Type[Node]) -> list[dict]:
        eligible_groups = []
        for age, priority in enumerate(self.age_risk_priority_groups):
            if priority == 0:
                continue
            elif priority == 0.5:
                risks = [RiskGroup.H.value]
            elif priority == 1:
                risks = [RiskGroup.L.value, RiskGroup.H.value]

            for risk in risks:
                for vaccine in (VaccineGroup.U.value, VaccineGroup.V.value):
                    group = Group(age, risk, vaccine)
                    eligible = self._eligible_in_group(node, group)
                    if eligible > 0:
                        eligible_groups.append({
                            "group": group,
                            "eligible": eligible,
                        })

        return eligible_groups

    def _eligible_population(self, node: Type[Node]) -> float:
        return float(sum(group["eligible"] for group in self._eligible_by_group(node)))

    def _eligible_in_group(self, node: Type[Node], group: Type[Group]) -> float:
        vector = node.compartments.get_compartment_vector_for(group)
        return float(sum(vector[getattr(Compartments, label).value] for label in self.eligible_compartments))

    def _treat_group(self, node: Type[Node], group: Type[Group], amount: int):
        if amount <= 0:
            return

        remaining = amount
        vector = node.compartments.compartment_data[group.age][group.risk][group.vaccine]
        for label in self.compartment_priority:
            if remaining <= 0:
                break
            compartment_idx = getattr(Compartments, label).value
            available = int(vector[compartment_idx])
            moving = min(remaining, available)
            if moving <= 0:
                continue
            vector[compartment_idx] -= moving
            vector[Compartments.T.value] += moving
            if node.requires_antiviral_event_reconciliation:
                node.pending_antiviral_transitions.append({
                    "group": group,
                    "source_compartment": compartment_idx,
                    "amount": moving,
                })
            remaining -= moving

    def _roll_network_stockpile(self, day: int, amount: float):
        if amount >= 1.0:
            self.network_stockpile_by_day.setdefault(day + 1, 0.0)
            self.network_stockpile_by_day[day + 1] += amount
            logger.debug(f"Day {day}: {amount} antiviral doses rolled over to day {day + 1}; no eligible people.")
