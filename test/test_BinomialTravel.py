from types import SimpleNamespace

import numpy as np
import pytest

from baseclasses.Group import Compartments, Group, RiskGroup, VaccineGroup
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.PopulationCompartments import PopulationCompartments
from models.travel.BinomialTravel import BinomialTravel


def make_parameters(**overrides):
    travel_parameters = {
        "rho": "0.5",
        "flow_reduction": ["2"],
        "traveling_compartments": {"I": "0.2"},
        "transmitting_compartments": {"I": "1.0"},
    }
    travel_parameters.update(overrides)
    return SimpleNamespace(
        travel_parameters=travel_parameters,
        number_of_age_groups=1,
        np_contact_matrix=[[4.0]],
    )


def make_model(parameters=None):
    parameters = parameters or make_parameters()
    return BinomialTravel(SimpleNamespace(parameters=parameters))


def make_two_node_network():
    network = Network(["S", "E", "I", "R"])
    for index in range(2):
        compartments = PopulationCompartments([100], [0.0])
        network._add_node(Node(index, index, index, compartments))
    network.add_travel_flow_data(np.array([[0.0, 0.0], [1.0, 0.0]]))
    return network


class ExposingDiseaseModel:
    beta = 0.1
    relative_susceptibility = [1.0]

    def __init__(self):
        self.exposures = []

    def expose_number_of_people(self, node, group, number, vaccine_model):
        self.exposures.append((node.node_id, group, number))
        node.compartments.expose_number_of_people_bulk(group, number)


def test_init_converts_string_parameters():
    model = make_model()

    assert model.rho == 0.5
    assert model.flow_reduction == [2.0]
    assert model.travel_dict == {"I": 0.2}
    assert model.transmit_dict == {"I": 1.0}


@pytest.mark.parametrize(
    "missing_key",
    ["traveling_compartments", "transmitting_compartments"],
)
def test_init_requires_compartment_weights(missing_key):
    parameters = make_parameters()
    parameters.travel_parameters[missing_key] = {}

    with pytest.raises(ValueError, match=missing_key):
        make_model(parameters)


def test_flow_probability_uses_both_travel_directions():
    network = make_two_node_network()
    source = network.nodes[1]
    source_group = Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    source.compartments.expose_number_of_people_bulk(source_group, 0)
    source.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.S.value
    ] = 80
    source.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.I.value
    ] = 20

    model = make_model()
    disease_model = ExposingDiseaseModel()
    probabilities = [0.0]

    model._calculate_flow_probability(
        model.parameters,
        network,
        network.nodes[0],
        0,
        source,
        1,
        probabilities,
        disease_model,
    )

    # One source-to-sink traveler flow. Twenty infectious people * 20% travel,
    # then beta, rho, contacts, and flow reduction are applied over sink N=100.
    assert probabilities[0] == pytest.approx(
        1.0 * (20 * 0.2) * 0.1 * 0.5 * 4.0 / 2.0 / 100
    )


def test_exposure_clamps_probability_and_applies_vaccine_effectiveness(monkeypatch):
    network = make_two_node_network()
    sink = network.nodes[0]
    sink.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.S.value
    ] = 10
    sink.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.V.value, Compartments.S.value
    ] = 10

    draws = []

    def fake_binomial(population, probability):
        draws.append((population, probability))
        return 0

    monkeypatch.setattr(
        "models.travel.BinomialTravel.rand_binomial",
        fake_binomial,
    )
    disease_model = ExposingDiseaseModel()
    vaccine_model = SimpleNamespace(vaccine_effectiveness=[0.25])

    make_model()._expose_from_travel(
        make_parameters(),
        sink,
        [2.0],
        disease_model,
        vaccine_model,
    )

    assert (10, 1.0) in draws
    # The raw vaccinated probability is 1.5 and is also capped at one.
    assert draws.count((10, 1.0)) == 2
    assert len(disease_model.exposures) == len(RiskGroup) * len(VaccineGroup)


def test_travel_creates_sink_exposure_without_moving_node_populations(monkeypatch):
    network = make_two_node_network()
    source = network.nodes[1]
    source.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.S.value
    ] = 90
    source.compartments.compartment_data[
        0, RiskGroup.L.value, VaccineGroup.U.value, Compartments.I.value
    ] = 10

    monkeypatch.setattr(
        "models.travel.BinomialTravel.rand_binomial",
        lambda population, probability: 1 if population > 0 and probability > 0 else 0,
    )

    before = [
        node.compartments.get_disease_compartment_sum().copy()
        for node in network.nodes
    ]
    disease_model = ExposingDiseaseModel()
    vaccine_model = SimpleNamespace(vaccine_effectiveness=[0.0])

    make_model().travel(
        network,
        disease_model,
        make_parameters(),
        time=1,
        vaccine_model=vaccine_model,
    )

    after = [
        node.compartments.get_disease_compartment_sum()
        for node in network.nodes
    ]
    assert after[0][Compartments.S.value] == before[0][Compartments.S.value] - 1
    assert after[0][Compartments.E.value] == before[0][Compartments.E.value] + 1
    assert np.array_equal(after[1], before[1])
    assert [values.sum() for values in after] == [values.sum() for values in before]
