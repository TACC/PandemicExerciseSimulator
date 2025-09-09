import pytest
import warnings
import numpy as np
from types import SimpleNamespace

from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses import Group # needed to set dynamic Compartment Enum
from src.baseclasses.Group import RiskGroup, VaccineGroup, Compartments
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.treatments.Vaccination import Vaccination  # Adjust import based on your structure

# still requires calling with printing more than stdout to the screen to see these debug messages
# poetry run pytest -s test/test_AgeRiskVaccineStockpileStrategy.py

# Multiple node test
def test_distribute_vaccines_to_nodes_only_moves_stock():
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": None,
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [{"day": "0", "amount": "100"}]
        })
    compartment_labels = ["S", "E", "A", "T", "I", "R", "D"]
    net = Network(compartment_labels) #type("MockNet", (), {"nodes": [n1, n2]})
    # Two nodes, 60 & 40 people
    n1 = Node(0, 0, 0, PopulationCompartments([60], [0.0]))
    n2 = Node(1, 1, 0, PopulationCompartments([40], [0.0]))
    net._add_node(n1)
    net._add_node(n2)
    strat = Vaccination(parameters=params).get_child(params.vaccine_model, network=net)

    # Before: no per-node stock
    assert 0 not in strat.node_stockpile_by_day.get(0, {})
    assert 0 not in strat.node_stockpile_by_day.get(1, {})

    # Act: distribute to nodes for day 0; no one is vaccinated yet
    strat.distribute_vaccines_to_nodes(network=net, day=0)

    # After: all 100 left the network pool and are in node pools (split rule depends on impl)
    total_node_day0 = sum(
        strat.node_stockpile_by_day[i][0] for i in (0, 1)
    )
    assert total_node_day0 == 100.0

    # Compartment counts untouched (population moves only in distribute_vaccines_to_population)
    # Imported the module Group for dynamic compartments, so need to call the class Group by Group.Group
    assert n1.compartments.get_compartment_vector_for(Group.Group(age=0, risk_group=RiskGroup.L.value, vaccine_group=VaccineGroup.U.value))[0] == 60
    assert n2.compartments.get_compartment_vector_for(Group.Group(age=0, risk_group=RiskGroup.L.value, vaccine_group=VaccineGroup.U.value))[0] == 40

# Make a single node for tests below
def make_network_with_population(pop=100):
    compartment_labels = ["S", "E", "A", "T", "I", "R", "D"]
    net = Network(compartment_labels)
    pc   = PopulationCompartments(age_group_pops=[pop], high_risk_ratios=[0.0])
    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    net._add_node(node)
    return net

def test_adherence_ceiling_caps_usage_and_rolls_over():
    # One node, one age, low-risk only; total_grp_pop = 100
    net = make_network_with_population()
    node = net.nodes[0]

    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": None,
            "vaccine_adherence": ["0.5"],      # ceiling: at most 50% ever vaccinated
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [{"day": "0", "amount": "60"}]  # capacity not limiting
        })
    strat = Vaccination(parameters=params).get_child(params.vaccine_model, network=net)
    strat.distribute_vaccines_to_nodes(network=net, day=0)  # Move day-0 stock from network to node
    strat.distribute_vaccines_to_population(node, day=0) # Vaccinate within the node using adherence ceiling

    # Check: cumulative vaccinated (sum over all compartments in vax group) = 50
    vax_vec = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert float(vax_vec) == 50.0

    # Unvaccinated susceptibles should drop to 50
    unvax_vec = node.compartments.compartment_data[0][0][0][Compartments.S.value]
    assert float(unvax_vec) == 50.0

    # Leftover stock should roll to next day: 60 given 50 -> 10 rolls to day 1
    assert strat.node_stockpile_by_day[node.node_id][1] == 10.0

    # Fraction vaccinated now = 50/100 = 0.5 (hits adherence ceiling exactly)
    frac_vax = float(np.sum(vax_vec)) / 100.0
    assert abs(frac_vax - 0.5) < 1e-9


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
            ]})
    compartment_labels = ["S", "E", "A", "T", "I", "R", "D"]
    net = make_network_with_population()
    node = net.nodes[0]
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=net)

    # Only day 0 should exist in the dictionary
    assert 0 in strategy.network_stockpile_by_day, "Expected effective day 0 in stockpile_by_day"
    assert strategy.network_stockpile_by_day[0] == 150.0, f"Expected total of 150 at day 0, got {strategy.stockpile_by_day[0]}"

    # Run distribution
    strategy.distribute_vaccines_to_nodes(network=net, day=0)
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
            ]})
    net = make_network_with_population(pop=90) # population less than total vaccines to distribute
    node = net.nodes[0]
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=net)

    # Expect day 1 to have all 3 amounts combined
    assert strategy.network_stockpile_by_day[1] == 100.0, f"Expected 100 vaccines at day 1, got {strategy.network_stockpile_by_day[1]}"

    # Run distribution of 100 vaccines to 90 people
    strategy.distribute_vaccines_to_nodes(network=net, day=1)
    strategy.distribute_vaccines_to_population(node, day=1)
    vaccinated = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated == 90, f"Expected all 90 people vaccinated, got {vaccinated}"

def test_rollover_unused_vaccines_to_next_day():
    # Day 0: 50 vaccines available, only 30 people in the population
    # Expect 20 leftover to roll to day 1, where 40 more people are eligible
    # Day 1: 20 vaccines available, vaccinate 20 people (now 50 total), 20 ppl unvax
    # Day 2: Should not exist in dict as 0 vax rolled over
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
            ]})
    net = make_network_with_population(pop=30) # population less than total vaccines to distribute
    node = net.nodes[0]
    vaccine_parent = Vaccination(parameters=params)
    strategy = vaccine_parent.get_child(params.vaccine_model, network=net)

    # Day 0: 50 vaccines, only 30 people → 20 leftover
    strategy.distribute_vaccines_to_nodes(network=net, day=0)
    strategy.distribute_vaccines_to_population(node, day=0)
    vaccinated_day0 = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_day0 == 30, f"Expected 30 vaccinated on day 0, got {vaccinated_day0}"
    # Manually increase population for day 1
    node.compartments.compartment_data[0][0][0][Compartments.S.value] += 40  # 40 more susceptibles
    assert np.sum(node.compartments.compartment_data) == 70

    # Day 1: expect 20 leftover vaccines from day 0 to be used
    assert strategy.node_stockpile_by_day[0][1] == 20.0, f"Expected 20 vaccines left on day 1, got {strategy.node_stockpile_by_day[0][1]}"
    strategy.distribute_vaccines_to_nodes(network=net, day=1)
    strategy.distribute_vaccines_to_population(node, day=1)
    vaccinated_total = node.compartments.compartment_data[0][0][1][Compartments.S.value]
    assert vaccinated_total == 50, f"Expected 50 total vaccinated after day 1, got {vaccinated_total}"

    # Verify no doses remain in the stockpile to be rolled over to day 2
    assert 2 not in strategy.node_stockpile_by_day[0], "Day 2 unexpectedly found in stockpile"

def test_capacity_limits_day0_when_less_than_one():
    net = make_network_with_population()
    node = net.nodes[0]
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_capacity_proportion": 0.3,   # cap 30/day at most
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [{"day": "0", "amount": "100"}]
        })
    strat = Vaccination(parameters=params).get_child(params.vaccine_model, network=net)
    strat.distribute_vaccines_to_nodes(net, day=0)
    strat.distribute_vaccines_to_population(node, day=0)
    total_vax = node.compartments.get_compartment_vector_for(Group.Group(0, RiskGroup.L.value, VaccineGroup.V.value))
    assert float(sum(total_vax)) == 30.0  # capped at 30% of total pop on day 0

def test_half_life_applies_only_after_day0_and_subinteger_loss():
    net = make_network_with_population(pop=5)
    node = net.nodes[0]
    params = SimpleNamespace(
        number_of_age_groups=1,
        vaccine_model="stockpile-age-risk",
        vaccine_parameters={
            "vaccine_half_life_days": 1,  # 50% per day
            "vaccine_adherence": ["1"],
            "vaccine_effectiveness": ["1"],
            "vaccine_eff_lag_days": "0",
            "vaccine_stockpile": [{"day": "1", "amount": "1"}]
        })
    strat = Vaccination(parameters=params).get_child(params.vaccine_model, network=net)
    strat.distribute_vaccines_to_nodes(net, day=1)
    # day=1: decay happens => 0.5 dose → floor to 0 used, and comment says <1 is lost (not rolled)
    strat.distribute_vaccines_to_population(node, day=1)
    # no vaccination should occur; and no day 2 rollover created by a sub-integer
    total_vax = node.compartments.get_compartment_vector_for(Group.Group(0, RiskGroup.L.value, VaccineGroup.V.value))
    assert float(sum(total_vax)) == 0.0
    assert 2 not in strat.node_stockpile_by_day[0]