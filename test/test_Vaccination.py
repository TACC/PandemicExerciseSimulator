import pytest
import warnings
from icecream import ic

from baseclasses.PopulationCompartments import PopulationCompartments, Compartments
from baseclasses.Node import Node
from baseclasses.Group import Group
from src.models.treatments.Vaccination import Vaccination  # Adjust import based on your structure

# still requires calling with printing more than stdout to the screen to see these debug messages
# poetry run pytest -s test/test_Vaccination.py
use_ic = False  # Change to False to disable IceCream
if use_ic:
    ic("ICECREAM ENABLED")
else:
    ic.disable()
    print("ICECREAM DISABLED")

def test_vaccinate_number_of_people():
    # Setup: define 1 age group with 10 unvaccinated people
    groups = [10]
    high_risk_ratios = [0.0]  # all low-risk

    pc = PopulationCompartments(groups, high_risk_ratios)
    ic("made pop compartments")

    # Create a Node with these compartments
    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    ic("made node")

    # Define unvaccinated and vaccinated groups
    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    # Check initial counts
    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    initial_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Initial unvax count:", initial_unvax); ic("Initial vax count:", initial_vax)

    # Instantiate Vaccination class
    vaccination = Vaccination()

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
    # Setup: define 1 age group with 0 unvaccinated people
    groups = [0]  # zero people
    high_risk_ratios = [0.0]

    pc = PopulationCompartments(groups, high_risk_ratios)
    ic("made pop compartments with zero people")

    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    ic("made node")

    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    initial_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Initial unvax count (should be 0):", initial_unvax); ic("Initial vax count (should be 0):", initial_vax)

    vaccination = Vaccination()

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
    # Setup: 1 age group with 10 unvaccinated people
    groups = [10]
    high_risk_ratios = [0.0]
    pc = PopulationCompartments(groups, high_risk_ratios)
    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)
    vaccination = Vaccination()

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

