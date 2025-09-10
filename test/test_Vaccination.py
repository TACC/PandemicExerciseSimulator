import pytest
import warnings
import numpy as np
from icecream import ic
from types import SimpleNamespace

from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.Node import Node
from src.baseclasses import Group # needed to set dynamic Compartment Enum
from src.baseclasses.Group import Compartments
from src.models.treatments.Vaccination import Vaccination  # Adjust import based on your structure

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

@pytest.fixture
def dummy_vaccination():
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_parameters={}
    )
    return Vaccination(parameters=params)

def test_vaccinate_number_of_people(dummy_vaccination):
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

    # Vaccinate 3 people
    num_to_vaccinate = 3; ic("Num to vaccinate:", num_to_vaccinate)
    dummy_vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, num_to_vaccinate)

    # Check counts after vaccination
    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Final unvax count:", final_unvax); ic("Final vax count:", final_vax)

    # Assertions
    assert final_unvax == initial_unvax - num_to_vaccinate, f"Expected {initial_unvax - num_to_vaccinate}, got {final_unvax}"
    assert final_vax == initial_vax + num_to_vaccinate, f"Expected {initial_vax + num_to_vaccinate}, got {final_vax}"

def test_vaccinate_when_no_susceptibles(dummy_vaccination):
    # Setup: define 1 age group with 10 unvaccinated people, all low-risk
    # Create a Node with these compartments
    node = make_node_with_population(pop=0)
    ic("made compartments & node")

    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    initial_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Initial unvax count (should be 0):", initial_unvax); ic("Initial vax count (should be 0):", initial_vax)

    # Attempt to vaccinate 10 people when there are 0
    num_to_vaccinate = 10
    dummy_vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, num_to_vaccinate)

    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    ic("Final unvax count (should still be 0):", final_unvax); ic("Final vax count (should still be 0):", final_vax)

    # Assertions: no change in unvax or vax counts
    assert final_unvax == 0, f"Expected 0 unvax, got {final_unvax}"
    assert final_vax == 0, f"Expected 0 vax, got {final_vax}"

def test_vaccinate_non_integer_input(dummy_vaccination):
    # Setup: define 1 age group with 10 unvaccinated people, all low-risk
    node = make_node_with_population(pop=10) # Create a Node with these compartments
    ic("made compartments & node")

    unvax_group = Group(age=0, risk_group=0, vaccine_group=0)
    vax_group = Group(age=0, risk_group=0, vaccine_group=1)

    # a) Integer-valued float (3.0) should be accepted without warning
    initial_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    dummy_vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, 3.0)
    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    assert final_unvax == initial_unvax - 3

    # Reset counts to 10 unvax, 0 vax for next test
    node.compartments.compartment_data[0][0][0][Compartments.S.value] = 10
    node.compartments.compartment_data[0][0][1][Compartments.S.value] = 0

    # b) Non-integer float (3.5) should floor with warning and vaccinate 3
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        dummy_vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, 3.5)
        assert len(w) == 1, "Expected one warning for flooring non-integer float"
        assert "Flooring to" in str(w[0].message)

    final_unvax = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    final_vax = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert final_unvax == 7, f"Expected 7 unvax, got {final_unvax}"
    assert final_vax == 3, f"Expected 3 vax, got {final_vax}"

    # c) Invalid type (string) should raise ValueError
    with pytest.raises(ValueError, match="num_to_vaccinate must be an integer or integer-valued float"):
        dummy_vaccination.vaccinate_number_of_people(node, unvax_group, vax_group, "five")

    ic("Non-integer input hybrid test passed")

def test_get_child_returns_self_when_none(dummy_vaccination):
    child = dummy_vaccination.get_child(None, network=None)
    assert child is dummy_vaccination, "Expected get_child(None, ...) to return the parent vaccination object"

def test_get_child_returns_stockpile_age_risk_strategy(dummy_vaccination):
    # Create a dummy network object
    mock_network = SimpleNamespace(nodes=[])

    child = dummy_vaccination.get_child("stockpile-age-risk", network=mock_network)

    # Check that the returned object is not the same as the parent
    assert child is not dummy_vaccination
    # Check that it has expected attributes
    assert hasattr(child, 'distribute_vaccines_to_nodes'), "Expected strategy child to implement distribution methods"
    assert hasattr(child, 'node_stockpile_by_day'), "Expected strategy to have stockpile tracking"

def test_get_child_raises_on_unknown_strategy(dummy_vaccination):
    with pytest.raises(Exception, match='not recognized'):
        dummy_vaccination.get_child("not-a-real-strategy", network=None)

def test_vaccine_effectiveness_defaults_to_zeros():
    params = SimpleNamespace(
        number_of_age_groups=3,
        vaccine_parameters={}  # No VE provided
    )
    vaccination = Vaccination(parameters=params)
    assert vaccination.vaccine_effectiveness == [0.0, 0.0, 0.0], \
        f"Expected vaccine effectiveness to default to zeros, got {vaccination.vaccine_effectiveness}"

def test_vaccine_effectiveness_empty_list_defaults_to_zeros():
    params = SimpleNamespace(
        number_of_age_groups=2,
        vaccine_parameters={"vaccine_effectiveness": []}
    )
    vaccination = Vaccination(parameters=params)
    assert vaccination.vaccine_effectiveness == [0.0, 0.0], \
        f"Expected default VE of [0.0, 0.0], got {vaccination.vaccine_effectiveness}"

def test_vaccine_effectiveness_all_between_0_and_1():
    params = SimpleNamespace(
        number_of_age_groups=3,
        vaccine_parameters={"vaccine_effectiveness": ["0.0", "0.5", "1.0"]}
    )
    vaccination = Vaccination(parameters=params)

    assert all(0.0 <= ve <= 1.0 for ve in vaccination.vaccine_effectiveness), \
        f"Found invalid VE values: {vaccination.vaccine_effectiveness}"

