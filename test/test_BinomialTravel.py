from types import SimpleNamespace
import copy
import logging

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
        self.rng = np.random.default_rng(123)

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

    def fake_binomial(population, probability, rng):
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
        lambda population, probability, rng: 1 if population > 0 and probability > 0 else 0,
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


@pytest.mark.parametrize('travel_weights,transmit_weights', [
    ({'I': '0.2'}, {'I': '1.0'}),
    ({'I': '0.2', 'E': '0.4'}, {'I': '1.0'}),
    ({'S': '0.1'}, {'E': '0.8', 'I': '0.3'}),
])
def test_cached_travel_matches_debug_reference_across_steps(caplog, travel_weights, transmit_weights):
    parameters = make_parameters(traveling_compartments=travel_weights,
                                 transmitting_compartments=transmit_weights,
                                 flow_reduction=['2', '3'])
    parameters.number_of_age_groups = 2
    parameters.np_contact_matrix = np.array([[4.0, 1.3], [2.7, 5.0]])
    network = Network(['S', 'E', 'I', 'R'])
    for index in range(3):
        compartments = PopulationCompartments([100, 80], [0.2, 0.3])
        for age in range(2):
            infected = 10 + index + age
            compartments.compartment_data[age, 0, 0, Compartments.S.value] -= infected
            compartments.compartment_data[age, 0, 0, Compartments.I.value] += infected
        network._add_node(Node(index, index, index, compartments))
    network.add_travel_flow_data(np.array([[0, 1.2, 0], [0.7, 0, 3.1], [2.3, 0, 0]]))
    results = []
    for level in (logging.WARNING, logging.DEBUG):
        current_network = copy.deepcopy(network)
        model = make_model(parameters)
        disease = ExposingDiseaseModel()
        disease.relative_susceptibility = [0.8, 1.1]
        pressures = []
        expose = model._expose_from_travel

        def capture(parameters, node, probabilities, disease_model, vaccine_model):
            pressures.append(tuple(probabilities))
            return expose(parameters, node, probabilities, disease_model, vaccine_model)

        model._expose_from_travel = capture
        with caplog.at_level(level):
            for day in (1, 2):
                model.travel(current_network, disease, parameters, day,
                             SimpleNamespace(vaccine_effectiveness=[0.2, 0.5]))
                # Disease changes between steps must invalidate the prior cache.
                disease.beta *= 1.5
                current_network.nodes[1].compartments.compartment_data[1, 0, 0, Compartments.S.value] -= 2
                current_network.nodes[1].compartments.compartment_data[1, 0, 0, Compartments.I.value] += 2
        results.append((pressures, [node.compartments.compartment_data.copy()
                                   for node in current_network.nodes]))

    assert results[0][0] == results[1][0]  # Exact probabilities, not just tolerance.
    for cached, reference in zip(results[0][1], results[1][1]):
        np.testing.assert_array_equal(cached, reference)
    assert 'flow happening; sink id' in caplog.text
    assert 'traveling =' in caplog.text


def test_weighted_populations_are_computed_once_per_source_age(monkeypatch, caplog):
    network = make_two_node_network()
    network._add_node(Node(2, 2, 2, PopulationCompartments([100], [0.0])))
    network.add_travel_flow_data(np.ones((3, 3)) - np.eye(3))
    model = make_model()
    counts = {'traveling': 0, 'transmitting': 0}
    for name in counts:
        method_name = f'{name}_population_by_age'
        original = getattr(PopulationCompartments, method_name)

        def count(*args, _name=name, _original=original, **kwargs):
            counts[_name] += 1
            return _original(*args, **kwargs)

        monkeypatch.setattr(PopulationCompartments, method_name, count)
    with caplog.at_level(logging.WARNING):
        model.travel(network, ExposingDiseaseModel(), model.parameters, 1,
                     SimpleNamespace(vaccine_effectiveness=[0.0]))
    assert counts == {'traveling': 3, 'transmitting': 3}
