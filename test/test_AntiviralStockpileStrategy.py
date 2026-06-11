import importlib
import sys
from types import SimpleNamespace

import numpy as np
import pytest

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

from src.baseclasses.Group import Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.treatments.Antiviral import Antiviral


def make_network_with_t(pop=100):
    net = Network(["S", "E", "I", "T", "R"])
    node = Node(
        node_index=0,
        node_id=0,
        fips_id=0,
        compartments=PopulationCompartments([pop], [0.0]),
    )
    net._add_node(node)
    return net


def make_params(stockpile):
    return SimpleNamespace(
        number_of_age_groups=1,
        antiviral_model="stockpile-age-risk",
        antiviral_parameters={
            "age_risk_priority_groups": ["1"],
            "eligible_compartments": ["E", "I"],
            "compartment_priority": ["I", "E"],
            "antiviral_stockpile": stockpile,
        },
    )


def test_antiviral_stockpile_moves_capped_e_and_i_to_t():
    net = make_network_with_t()
    node = net.nodes[0]
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([80.0, 10.0, 10.0, 0.0, 0.0]))

    strat = Antiviral(make_params([{"day": "0", "amount": "12"}])).get_child(
        "stockpile-age-risk",
        network=net,
    )

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.I.value] == 0.0
    assert result[Compartments.E.value] == 8.0
    assert result[Compartments.T.value] == 12.0


def test_no_antiviral_stockpile_means_no_one_enters_t():
    net = make_network_with_t()
    node = net.nodes[0]
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([80.0, 10.0, 10.0, 0.0, 0.0]))

    strat = Antiviral(make_params([])).get_child("stockpile-age-risk", network=net)

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.E.value] == 10.0
    assert result[Compartments.I.value] == 10.0
    assert result[Compartments.T.value] == 0.0


def test_antiviral_stockpile_distributes_to_nodes_by_eligible_population():
    net = Network(["S", "E", "I", "T", "R"])
    n1 = Node(0, 0, 0, PopulationCompartments([100], [0.0]))
    n2 = Node(1, 1, 1, PopulationCompartments([100], [0.0]))
    net._add_node(n1)
    net._add_node(n2)

    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    n1.compartments.set_compartment_vector_for(group, np.array([70.0, 10.0, 20.0, 0.0, 0.0]))
    n2.compartments.set_compartment_vector_for(group, np.array([60.0, 5.0, 5.0, 0.0, 0.0]))

    strat = Antiviral(make_params([{"day": "0", "amount": "40"}])).get_child(
        "stockpile-age-risk",
        network=net,
    )

    strat.distribute_antivirals_to_nodes(net, day=0)

    assert strat.node_stockpile_by_day[0][0] == 30.0
    assert strat.node_stockpile_by_day[1][0] == 10.0
    assert strat.network_stockpile_by_day[0] == 0.0


def test_antiviral_stockpile_combines_negative_and_duplicate_days():
    net = make_network_with_t()

    strat = Antiviral(make_params([
        {"day": "-3", "amount": "10"},
        {"day": "0", "amount": "15"},
        {"day": "2", "amount": "4"},
        {"day": "2", "amount": "6"},
    ])).get_child("stockpile-age-risk", network=net)

    assert strat.network_stockpile_by_day[0] == 25.0
    assert strat.network_stockpile_by_day[2] == 10.0


def test_antiviral_half_life_accepts_numeric_string():
    net = make_network_with_t()
    params = make_params([])
    params.antiviral_parameters["antiviral_half_life_days"] = "60"

    strategy = Antiviral(params).get_child("stockpile-age-risk", network=net)

    assert strategy.antiviral_half_life_days == 60.0
    assert strategy.daily_antiviral_wastage == pytest.approx(0.5 ** (1 / 60.0))


def test_antivirals_roll_over_when_no_eligible_people():
    net = make_network_with_t()
    node = net.nodes[0]
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([100.0, 0.0, 0.0, 0.0, 0.0]))

    strat = Antiviral(make_params([{"day": "0", "amount": "12"}])).get_child(
        "stockpile-age-risk",
        network=net,
    )

    strat.distribute_antivirals_to_nodes(net, day=0)

    assert strat.network_stockpile_by_day[0] == 0.0
    assert strat.network_stockpile_by_day[1] == 12.0
    assert strat.node_stockpile_by_day[node.node_id] == {}


def test_antiviral_capacity_limits_treatment_and_rolls_remaining_stock():
    net = make_network_with_t()
    node = net.nodes[0]
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([80.0, 10.0, 10.0, 0.0, 0.0]))

    params = make_params([{"day": "0", "amount": "20"}])
    params.antiviral_parameters["antiviral_capacity_proportion"] = 0.1
    strat = Antiviral(params).get_child("stockpile-age-risk", network=net)

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.I.value] == 0.0
    assert result[Compartments.E.value] == 10.0
    assert result[Compartments.T.value] == 10.0
    assert strat.node_stockpile_by_day[node.node_id][1] == 10.0


def test_antiviral_priority_can_treat_exposed_before_infectious():
    net = make_network_with_t()
    node = net.nodes[0]
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([80.0, 10.0, 10.0, 0.0, 0.0]))

    params = make_params([{"day": "0", "amount": "12"}])
    params.antiviral_parameters["compartment_priority"] = ["E", "I"]
    strat = Antiviral(params).get_child("stockpile-age-risk", network=net)

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.E.value] == 0.0
    assert result[Compartments.I.value] == 8.0
    assert result[Compartments.T.value] == 12.0


def test_antiviral_strategy_requires_t_compartment():
    net = Network(["S", "E", "I", "R"])
    node = Node(0, 0, 0, PopulationCompartments([100], [0.0]))
    net._add_node(node)

    with pytest.raises(ValueError, match="requires a T compartment"):
        Antiviral(make_params([{"day": "0", "amount": "1"}])).get_child(
            "stockpile-age-risk",
            network=net,
        )


def test_antiviral_age_risk_priority_can_limit_to_high_risk():
    net = make_network_with_t()
    node = net.nodes[0]
    low = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    high = GroupModule.Group(0, RiskGroup.H.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(low, np.array([80.0, 0.0, 10.0, 0.0, 0.0]))
    node.compartments.set_compartment_vector_for(high, np.array([80.0, 0.0, 10.0, 0.0, 0.0]))

    params = make_params([{"day": "0", "amount": "10"}])
    params.antiviral_parameters["age_risk_priority_groups"] = ["0.5"]
    strat = Antiviral(params).get_child("stockpile-age-risk", network=net)

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    assert node.compartments.get_compartment_vector_for(low)[Compartments.I.value] == 10.0
    assert node.compartments.get_compartment_vector_for(low)[Compartments.T.value] == 0.0
    assert node.compartments.get_compartment_vector_for(high)[Compartments.I.value] == 0.0
    assert node.compartments.get_compartment_vector_for(high)[Compartments.T.value] == 10.0


@pytest.mark.parametrize("invalid_priority", ["0.25", -1, 2])
def test_antiviral_rejects_invalid_age_risk_priority(invalid_priority):
    net = make_network_with_t()
    params = make_params([])
    params.antiviral_parameters["age_risk_priority_groups"] = [invalid_priority]

    with pytest.raises(
        ValueError,
        match="age_risk_priority_groups values must be 0, 0.5, or 1",
    ):
        Antiviral(params).get_child("stockpile-age-risk", network=net)


@pytest.mark.parametrize(
    ("configured_priority", "normalized_priority"),
    [
        ("0", 0.0),
        (0, 0.0),
        ("0.5", 0.5),
        (0.5, 0.5),
        ("1", 1.0),
        (1, 1.0),
    ],
)
def test_antiviral_normalizes_age_risk_priority_to_float(
    configured_priority,
    normalized_priority,
):
    net = make_network_with_t()
    params = make_params([])
    params.antiviral_parameters["age_risk_priority_groups"] = [configured_priority]

    strategy = Antiviral(params).get_child("stockpile-age-risk", network=net)

    assert strategy.age_risk_priority_groups == [normalized_priority]
    assert isinstance(strategy.age_risk_priority_groups[0], float)


def test_antiviral_can_treat_seihrd_eligible_compartments():
    net = Network(["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"])
    node = Node(0, 0, 0, PopulationCompartments([100], [0.0]))
    net._add_node(node)
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([50.0, 2.0, 3.0, 4.0, 5.0, 0.0, 0.0, 0.0, 0.0]),
    )

    params = make_params([{"day": "0", "amount": "14"}])
    params.antiviral_parameters["eligible_compartments"] = ["E", "IA", "IP", "IS"]
    params.antiviral_parameters["compartment_priority"] = ["IS", "IP", "IA", "E"]
    strat = Antiviral(params).get_child("stockpile-age-risk", network=net)

    strat.distribute_antivirals_to_nodes(net, day=0)
    strat.distribute_antivirals_to_population(node, day=0)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.E.value] == 0.0
    assert result[Compartments.IA.value] == 0.0
    assert result[Compartments.IP.value] == 0.0
    assert result[Compartments.IS.value] == 0.0
    assert result[Compartments.T.value] == 14.0
