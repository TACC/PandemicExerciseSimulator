import importlib
import sys
from types import SimpleNamespace

import numpy as np

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules.setdefault("baseclasses.Group", GroupModule)

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
