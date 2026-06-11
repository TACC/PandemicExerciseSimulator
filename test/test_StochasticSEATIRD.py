import importlib
import sys
from copy import deepcopy
from types import SimpleNamespace

import numpy as np
import pytest

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

import src.models.disease.StochasticSEATIRD as StochasticSEATIRDModule
from src.baseclasses.Event import EventType
from src.baseclasses.Group import Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.treatments.Antiviral import Antiviral


class DummyVax:
    vaccine_effectiveness = [0.0]


def make_params(antiviral_parameters=None):
    return SimpleNamespace(
        number_of_age_groups=1,
        np_contact_matrix=np.array([[1.0]]),
        disease_parameters={
            "compartments": ["S", "E", "A", "T", "I", "R", "D"],
            "R0": "1.0",
            "beta_scale": "1.0",
            "tau": "2.0",
            "kappa": "2.0",
            "gamma": "4.0",
            "chi": "2.0",
            "nu": ["0.01"],
            "sigma": ["1.0"],
        },
        antiviral_parameters=antiviral_parameters or {},
    )


def make_model(pop=10, antiviral_parameters=None):
    network = Network(["S", "E", "A", "T", "I", "R", "D"])
    node = Node(
        node_index=0,
        node_id=0,
        fips_id=0,
        compartments=PopulationCompartments([pop], [0.0]),
    )
    network._add_node(node)

    npis = SimpleNamespace(schedule=np.zeros((3, 1, 1)))
    parent = DiseaseModel(make_params(antiviral_parameters), npis, now=0.0)
    model = parent.get_child("seatird-stochastic")
    model.set_initial_conditions([], network, DummyVax())
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    return model, network, node, group


def compartment_vector(node, group):
    return np.array(node.compartments.get_compartment_vector_for(group))


def assert_population_invariants(node, expected_total):
    data = np.asarray(node.compartments.compartment_data)
    assert np.all(data >= 0)
    assert np.isclose(data.sum(), expected_total)


def test_transition_preserves_population_and_never_allows_negative_source():
    model, _, node, group = make_model(pop=3)

    before = compartment_vector(node, group).sum()
    model._transition(node, Compartments.S.value, Compartments.E.value, group)

    assert_population_invariants(node, before)
    assert compartment_vector(node, group)[Compartments.S.value] == 2
    assert compartment_vector(node, group)[Compartments.E.value] == 1

    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0]),
    )
    with pytest.raises(RuntimeError, match="empty compartment"):
        model._transition(node, Compartments.E.value, Compartments.A.value, group)

    assert_population_invariants(node, 3)


def test_exposure_moves_only_available_people_and_queues_trajectories(monkeypatch):
    model, _, node, group = make_model(pop=2)

    class FakeSchedule:
        def __init__(self, disease_model, now, scheduled_group):
            self.now = now

        def Ta(self):
            return self.now + 1

    monkeypatch.setattr(StochasticSEATIRDModule, "Schedule", FakeSchedule)
    monkeypatch.setattr(model, "_initialize_asymptomatic_transitions", lambda *args: None)
    monkeypatch.setattr(model, "_initialize_contact_events", lambda *args: None)

    model.expose_number_of_people(node, group, 5, DummyVax())

    result = compartment_vector(node, group)
    assert result[Compartments.S.value] == 0
    assert result[Compartments.E.value] == 2
    assert len(node.events) == 2
    assert all(event.event_type == EventType.EtoA.name for event in node.events)
    assert_population_invariants(node, 2)


def test_valid_queued_events_preserve_population():
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    )
    node.add_transition_event(0.0, 0.25, EventType.EtoA.name, group)
    initial = deepcopy(node.compartments)

    model._next_event(node, node.group_cache, initial, DummyVax())

    result = compartment_vector(node, group)
    assert result[Compartments.E.value] == 0
    assert result[Compartments.A.value] == 1
    assert_population_invariants(node, 1)


def test_stale_asymptomatic_event_is_skipped_without_negative_compartments():
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]),
    )
    node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.A.value,
    ] = 1
    node.add_transition_event(0.0, 0.25, EventType.AtoT.name, group)
    initial = deepcopy(node.compartments)

    model._next_event(node, node.group_cache, initial, DummyVax())

    assert node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.A.value,
    ] == 0
    assert node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.T.value,
    ] == 1
    assert_population_invariants(node, 1)


def test_stale_t_event_is_skipped_before_new_antiviral_t_event():
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]),
    )
    node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.T.value,
    ] = 1

    node.add_transition_event(-1.0, 0.25, EventType.TtoI.name, group)
    node.add_transition_event(0.0, 0.75, EventType.TtoR.name, group)

    model.simulate(node, time=0, vaccine_model=DummyVax())

    result = compartment_vector(node, group)
    assert result[Compartments.T.value] == 0
    assert result[Compartments.I.value] == 0
    assert result[Compartments.R.value] == 1
    assert node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.T.value,
    ] == 0
    assert_population_invariants(node, 1)


def test_antiviral_allocation_replaces_old_queue_with_t_trajectories(monkeypatch):
    antiviral_parameters = {
        "age_risk_priority_groups": ["1"],
        "eligible_compartments": ["E", "A", "I"],
        "compartment_priority": ["I", "A", "E"],
        "antiviral_stockpile": [{"day": "0", "amount": "10"}],
    }
    model, network, node, group = make_model(
        pop=10,
        antiviral_parameters=antiviral_parameters,
    )
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 2.0, 3.0, 0.0, 5.0, 0.0, 0.0]),
    )

    antiviral = Antiviral(make_params(antiviral_parameters)).get_child(
        "stockpile-age-risk",
        network,
    )
    antiviral.distribute_antivirals_to_nodes(network, day=0)
    antiviral.distribute_antivirals_to_population(node, day=0)

    class TreatedSchedule:
        def __init__(self, disease_model, now, scheduled_group):
            self.now = now

        def update(self, disease_model, now, scheduled_group, compartment_num):
            assert compartment_num == Compartments.T.value

        def Tt(self):
            return self.now

        def Ti(self):
            return self.now + 2

        def Td_ti(self):
            return self.now + 3

        def Tr_ti(self):
            return self.now + 0.5

    monkeypatch.setattr(StochasticSEATIRDModule, "Schedule", TreatedSchedule)

    result_after_allocation = compartment_vector(node, group)
    assert result_after_allocation[Compartments.E.value] == 0
    assert result_after_allocation[Compartments.A.value] == 0
    assert result_after_allocation[Compartments.I.value] == 0
    assert result_after_allocation[Compartments.T.value] == 10
    assert len(node.pending_antiviral_transitions) == 3
    assert_population_invariants(node, 10)

    model.simulate(node, time=0, vaccine_model=DummyVax())

    result_after_events = compartment_vector(node, group)
    assert result_after_events[Compartments.T.value] == 0
    assert result_after_events[Compartments.R.value] == 10
    assert node.pending_antiviral_transitions == []
    assert_population_invariants(node, 10)


def test_no_antiviral_release_leaves_queue_and_t_unchanged():
    model, network, node, group = make_model(
        pop=10,
        antiviral_parameters={
            "age_risk_priority_groups": ["1"],
            "eligible_compartments": ["E", "A", "I"],
            "compartment_priority": ["I", "A", "E"],
            "antiviral_stockpile": [],
        },
    )
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 2.0, 3.0, 0.0, 5.0, 0.0, 0.0]),
    )
    antiviral = Antiviral(model.parameters).get_child("stockpile-age-risk", network)

    antiviral.distribute_antivirals_to_nodes(network, day=0)
    antiviral.distribute_antivirals_to_population(node, day=0)

    assert compartment_vector(node, group)[Compartments.T.value] == 0
    assert node.pending_antiviral_transitions == []
    assert node.events == []
    assert_population_invariants(node, 10)
