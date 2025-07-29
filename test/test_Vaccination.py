import pytest
import warnings
import numpy as np
from icecream import ic

from baseclasses.PopulationCompartments import PopulationCompartments, Compartments
from baseclasses.Node import Node
from baseclasses.Group import Group
from src.models.treatments.Vaccination import Vaccination  # Adjust import based on your structure
from src.models.treatments.UniformVaccineStockpileStrategy import UniformVaccineStockpileStrategy

# still requires calling with printing more than stdout to the screen to see these debug messages
# poetry run pytest -s test/test_Vaccination.py
use_ic = False  # Change to False to disable IceCream
if use_ic:
    ic.enable()
    ic("ICECREAM ENABLED")
else:
    ic.disable()
    print("ICECREAM DISABLED")

def make_node_with_population(pop=100):
    pc = PopulationCompartments(groups=[pop], high_risk_ratios=[0.0])
    return Node(node_index=0, node_id=0, fips_id=0, compartments=pc)

def test_vaccinate_number_of_people():
    # Setup: define 1 age group with 10 unvaccinated people, all low-risk
    # Create a Node with these compartments
    node = make_node_with_population(pop=10)
    ic("made compartments & node")

    # Define unvaccinated and vaccinated groups
    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    # Check initial counts
    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    initial_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Initial unvax count:", initial_unvax); ic("Initial vax count:", initial_vax)

    # Instantiate Vaccination class, pass dummy values, but not calling a strategy
    vaccination = Vaccination(
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=14,
        vaccine_stockpile=[
            {"day": "0", "amount": "0"},  # -> effective day = -66 → update to 0
        ])

    # Vaccinate 3 people
    num_to_vaccinate = 3; ic("Num to vaccinate:", num_to_vaccinate)
    vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, num_to_vaccinate)

    # Check counts after vaccination
    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Final unvax count:", final_unvax); ic("Final vax count:", final_vax)

    # Assertions
    assert final_unvax == initial_unvax - num_to_vaccinate, f"Expected {initial_unvax - num_to_vaccinate}, got {final_unvax}"
    assert final_vax == initial_vax + num_to_vaccinate, f"Expected {initial_vax + num_to_vaccinate}, got {final_vax}"

def test_vaccinate_when_no_susceptibles():
    # Setup: define 1 age group with 10 unvaccinated people, all low-risk
    # Create a Node with these compartments
    node = make_node_with_population(pop=0)
    ic("made compartments & node")

    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    initial_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Initial unvax count (should be 0):", initial_unvax); ic("Initial vax count (should be 0):", initial_vax)

    # Pass dummy values, but not calling a strategy
    vaccination = Vaccination(
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=14,
        vaccine_stockpile=[
        {"day": "0", "amount": "0"},   # -> effective day = -66 → update to 0
    ])

    # Attempt to vaccinate 10 people when there are 0
    num_to_vaccinate = 10
    vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, num_to_vaccinate)

    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Final unvax count (should still be 0):", final_unvax); ic("Final vax count (should still be 0):", final_vax)

    # Assertions: no change in unvax or vax counts
    assert final_unvax == 0, f"Expected 0 unvax, got {final_unvax}"
    assert final_vax == 0, f"Expected 0 vax, got {final_vax}"

def test_vaccinate_non_integer_input():
    # Setup: define 1 age group with 10 unvaccinated people, all low-risk
    node = make_node_with_population(pop=10) # Create a Node with these compartments
    ic("made compartments & node")

    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)
    vaccination = Vaccination( # Pass dummy values, but not calling a strategy
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=14,
        vaccine_stockpile=[
            {"day": "0", "amount": "0"},  # -> effective day = -66 → update to 0
        ])

    # a) Integer-valued float (3.0) should be accepted without warning
    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, 3.0)
    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    assert final_unvax == initial_unvax - 3

    # Reset counts to 10 unvax, 0 vax for next test
    node.compartments.compartment_data[0][0][0][Compartments.S.value] = 10
    node.compartments.compartment_data[0][0][1][Compartments.S.value] = 0

    # b) Non-integer float (3.5) should floor with warning and vaccinate 3
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, 3.5)
        assert len(w) == 1, "Expected one warning for flooring non-integer float"
        assert "Flooring to" in str(w[0].message)

    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert final_unvax == 7, f"Expected 7 unvax, got {final_unvax}"
    assert final_vax == 3, f"Expected 3 vax, got {final_vax}"

    # c) Invalid type (string) should raise ValueError
    with pytest.raises(ValueError, match="num_to_vaccinate must be an integer or integer-valued float"):
        vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, "five")

    ic("Non-integer input hybrid test passed")

def test_stockpile_combines_negative_and_day0():
    # 3 entries that all collapse to day 0
    stockpile_dict = [
        {"day": "-80", "amount": "50"},   # -> effective day = -66 → update to 0
        {"day": "-14", "amount": "100"},  # -> effective day = 0   → stays as 0
        {"day": "0", "amount": "25"},     # -> effective day = 14  → too late, skip for this test
    ]
    vaccination = Vaccination(
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=14,
        vaccine_stockpile=stockpile_dict, # trailing common optional for adding more lines easily if needed
    )

    node = make_node_with_population(pop=100)
    strategy = UniformVaccineStockpileStrategy(vaccination, network=type("MockNet", (), {"nodes": [node]}))

    # Only day 0 should exist in the dictionary
    assert 0 in strategy.stockpile_by_day, "Expected effective day 0 in stockpile_by_day"
    assert strategy.stockpile_by_day[0] == 150.0, f"Expected total of 150 at day 0, got {strategy.stockpile_by_day[0]}"

    # Run distribution
    strategy.distribute_vaccines(node, day=0)

    # Check that exactly 150 people were vaccinated
    vaccinated = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated == 100, f"Expected all 100 people vaccinated, got {vaccinated}"

def test_stockpile_combines_duplicate_days():
    stockpile = [
        {"day": "1", "amount": "30"},
        {"day": "1", "amount": "40"},
        {"day": "1", "amount": "30"},
    ]
    vaccination = Vaccination(
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=0,
        vaccine_stockpile=stockpile,
    )

    node = make_node_with_population(pop=90) # population less than total vaccines to distribute
    strategy = UniformVaccineStockpileStrategy(vaccination, network=type("MockNet", (), {"nodes": [node]}))

    # Expect day 1 to have all 3 amounts combined
    assert strategy.stockpile_by_day[1] == 100.0, f"Expected 100 vaccines at day 1, got {strategy.stockpile_by_day[1]}"

    # Run distribution
    strategy.distribute_vaccines(node, day=1)

    vaccinated = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated == 90, f"Expected all 90 people vaccinated, got {vaccinated}"

def test_rollover_unused_vaccines_to_next_day():
    # Day 0: 50 vaccines available, only 30 people in the population
    # Expect 20 leftover to roll to day 1, where 40 more people are eligible

    stockpile = [
        {"day": "0", "amount": "50"},
        #{"day": "1", "amount": "0"},  # Day 1 should be created by the function when rolling over
    ]
    vaccination = Vaccination(
        vaccine_wastage_factor=None,
        vaccine_pro_rata="uniform-stockpile",
        vaccine_adherence=["1"],
        vaccine_effectiveness=["1"],
        vaccine_eff_lag_days=0,
        vaccine_stockpile=stockpile,
    )

    # Setup: node starts with 30 people, we’ll manually add 40 more on day 1
    node = make_node_with_population(pop=30)
    strategy = UniformVaccineStockpileStrategy(vaccination, network=type("MockNet", (), {"nodes": [node]}))

    # Day 0: 50 vaccines, only 30 people → 20 leftover
    strategy.distribute_vaccines(node, day=0)
    vaccinated_day0 = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_day0 == 30, f"Expected 30 vaccinated on day 0, got {vaccinated_day0}"

    # Manually increase population for day 1
    node.compartments.compartment_data[0][0][0][Compartments.S.value] += 40  # 40 more susceptibles
    ic(node.compartments.compartment_data)
    assert np.sum(node.compartments.compartment_data) == 70

    # Day 1: expect 20 leftover vaccines from day 0 to be used
    strategy.distribute_vaccines(node, day=1)
    vaccinated_total = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_total == 50, f"Expected 50 total vaccinated after day 1, got {vaccinated_total}"

    # Verify no doses remain in the stockpile
    assert strategy.stockpile_by_day[1] == 0.0, f"Expected no vaccines left on day 1, got {strategy.stockpile_by_day[1]}"
