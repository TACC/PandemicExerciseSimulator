import pytest
import warnings
import numpy as np
from types import SimpleNamespace
from icecream import ic

from baseclasses.PopulationCompartments import PopulationCompartments, Compartments
from baseclasses.Node import Node
from baseclasses.Group import Group
from src.models.treatments.Vaccination import Vaccination  # Adjust import based on your structure

# still requires calling with printing more than stdout to the screen to see these debug messages
# poetry run pytest -s test/test_Vaccination.py

def make_node_with_population(pop=100):
    pc = PopulationCompartments(groups=[pop], high_risk_ratios=[0.0])
    return Node(node_index=0, node_id=0, fips_id=0, compartments=pc)

def test_stockpile_combines_negative_and_day0():
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": None,
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "14",
            "vaccine_stockpile": [ # 3 entries that all collapse to day 0
                {"day": "-80", "amount": "50"},   # -> effective day = -66 → update to 0
                {"day": "-14", "amount": "100"},  # -> effective day = 0   → stays as 0
                {"day": "0", "amount": "25"}      # -> effective day = 14  → too late, skip for this test
            ]
        }
    )
    node = make_node_with_population(pop=100)
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=type("MockNet", (), {"nodes": [node]}))

    # Only day 0 should exist in the dictionary
    assert 0 in strategy.network_stockpile_by_day, "Expected effective day 0 in stockpile_by_day"
    assert strategy.network_stockpile_by_day[0] == 150.0, f"Expected total of 150 at day 0, got {strategy.stockpile_by_day[0]}"

    # Run distribution
    strategy.distribute_vaccines_to_nodes(network=type("MockNet", (), {"nodes": [node]}), day=0)
    strategy.distribute_vaccines_to_population(node, day=0)

    # Check that exactly 150 people were vaccinated
    vaccinated = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated == 100, f"Expected all 100 people vaccinated, got {vaccinated}"

def test_stockpile_combines_duplicate_days():
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": None,
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [ # 3 entries that all collapse to day 0
                {"day": "1", "amount": "30"},
                {"day": "1", "amount": "40"},
                {"day": "1", "amount": "30"}
            ]
        }
    )
    node = make_node_with_population(pop=90) # population less than total vaccines to distribute
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=type("MockNet", (), {"nodes": [node]}))

    # Expect day 1 to have all 3 amounts combined
    assert strategy.network_stockpile_by_day[1] == 100.0, f"Expected 100 vaccines at day 1, got {strategy.network_stockpile_by_day[1]}"

    # Run distribution of 100 vaccines to 90 people
    strategy.distribute_vaccines_to_nodes(network=type("MockNet", (), {"nodes": [node]}), day=1)
    strategy.distribute_vaccines_to_population(node, day=1)
    vaccinated = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated == 90, f"Expected all 90 people vaccinated, got {vaccinated}"

def test_rollover_unused_vaccines_to_next_day():
    # Day 0: 50 vaccines available, only 30 people in the population
    # Expect 20 leftover to roll to day 1, where 40 more people are eligible
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": None,
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [ # 3 entries that all collapse to day 0
                {"day": "0", "amount": "50"}
                #{"day": "1", "amount": "0"},  # Day 1 should be created by the function when rolling over
            ]
        }
    )
    node = make_node_with_population(pop=30) # population less than total vaccines to distribute
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=type("MockNet", (), {"nodes": [node]}))

    # Day 0: 50 vaccines, only 30 people → 20 leftover
    strategy.distribute_vaccines_to_nodes(network=type("MockNet", (), {"nodes": [node]}), day=0)
    strategy.distribute_vaccines_to_population(node, day=0)
    vaccinated_day0 = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_day0 == 30, f"Expected 30 vaccinated on day 0, got {vaccinated_day0}"
    # Manually increase population for day 1
    node.compartments.compartment_data[0][0][0][Compartments.S.value] += 40  # 40 more susceptibles
    assert np.sum(node.compartments.compartment_data) == 70

    # Day 1: expect 20 leftover vaccines from day 0 to be used
    assert strategy.node_stockpile_by_day[0][1] == 20.0, f"Expected 20 vaccines left on day 1, got {strategy.node_stockpile_by_day[0][1]}"
    strategy.distribute_vaccines_to_nodes(network=type("MockNet", (), {"nodes": [node]}), day=1)
    strategy.distribute_vaccines_to_population(node, day=1)
    vaccinated_total = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_total == 50, f"Expected 50 total vaccinated after day 1, got {vaccinated_total}"

    # Verify no doses remain in the stockpile to be rolled over to day 2
    assert 2 not in strategy.node_stockpile_by_day[0], "Day 2 unexpectedly found in stockpile"
