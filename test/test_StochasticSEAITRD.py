import importlib
import sys
from copy import deepcopy
from types import SimpleNamespace

import numpy as np
import pytest

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

import src.models.disease.StochasticSEAITRD as StochasticSEAITRDModule
from src.baseclasses.Event import EventType
from src.baseclasses.Group import Compartments, Group, RiskGroup, VaccineGroup
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
            "compartments": ["S", "E", "A", "I", "T", "R", "D"],
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
    network = Network(["S", "E", "A", "I", "T", "R", "D"])
    node = Node(
        node_index=0,
        node_id=0,
        fips_id=0,
        compartments=PopulationCompartments([pop], [0.0]),
    )
    network._add_node(node)

    npis = SimpleNamespace(schedule=np.zeros((3, 1, 1)))
    parent = DiseaseModel(make_params(antiviral_parameters), npis, now=0.0)
    model = parent.get_child("seaitrd-stochastic")
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

    monkeypatch.setattr(StochasticSEAITRDModule, "Schedule", FakeSchedule)
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
    node.add_transition_event(0.0, 0.25, EventType.AtoI.name, group)
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
        Compartments.I.value,
    ] == 1
    assert_population_invariants(node, 1)


def test_stale_t_event_is_skipped_before_new_antiviral_t_event():
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0]),
    )
    node.unqueued_event_counter[
        group.age,
        group.risk,
        group.vaccine,
        Compartments.T.value,
    ] = 1

    node.add_transition_event(-1.0, 0.25, EventType.TtoD.name, group)
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
        "compartment_priority": ["I", "A", "E"],
        "antiviral_stockpile": [{"day": "0", "amount": "10"}],
    }
    model, network, node, group = make_model(
        pop=10,
        antiviral_parameters=antiviral_parameters,
    )
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 2.0, 3.0, 5.0, 0.0, 0.0, 0.0]),
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

        def Td_ti(self):
            return self.now + 3

        def Tr_ti(self):
            return self.now + 0.5

    monkeypatch.setattr(StochasticSEAITRDModule, "Schedule", TreatedSchedule)

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
            "compartment_priority": ["I"],
            "antiviral_stockpile": [],
        },
    )
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 2.0, 3.0, 5.0, 0.0, 0.0, 0.0]),
    )
    antiviral = Antiviral(model.parameters).get_child("stockpile-age-risk", network)

    antiviral.distribute_antivirals_to_nodes(network, day=0)
    antiviral.distribute_antivirals_to_population(node, day=0)

    assert compartment_vector(node, group)[Compartments.T.value] == 0
    assert node.pending_antiviral_transitions == []
    assert node.events == []
    assert_population_invariants(node, 10)


def test_antiviral_effectiveness_death_defaults_to_no_reduction():
    model, _, _, _ = make_model()

    assert model.antiviral_effectiveness_death == [0.0]


def test_antiviral_effectiveness_death_rejects_invalid_values():
    with pytest.raises(ValueError, match="antiviral_effectiveness_death"):
        make_model(antiviral_parameters={"antiviral_effectiveness_death": "1.5"})


def test_treated_schedule_reduces_death_rate(monkeypatch):
    model, _, _, group = make_model(
        antiviral_parameters={"antiviral_effectiveness_death": "0.25"}
    )
    schedule = StochasticSEAITRDModule.Schedule(model, now=0.0, group=group)
    draws = []

    def fake_draw_exit_time(rate, start_time):
        draws.append((rate, start_time))
        return start_time + 1.0

    monkeypatch.setattr(
        StochasticSEAITRDModule,
        "_draw_exit_time",
        fake_draw_exit_time,
    )

    schedule.update(model, now=10.0, group=group, compartment_num=Compartments.T.value)

    assert draws[0] == pytest.approx((0.0075, 10.0))
    assert draws[1] == pytest.approx((0.25, 10.0))


def test_schedule_draws_complete_competing_event_times(monkeypatch):
    model, _, _, group = make_model()
    draws = iter([2.0, 3.0, 8.0, 9.0])
    monkeypatch.setattr(
        StochasticSEAITRDModule,
        "rand_exp_min1",
        lambda rate: next(draws),
    )

    schedule = StochasticSEAITRDModule.Schedule(model, now=1.0, group=group)

    assert schedule.Ta() == 3.0
    assert schedule.Ti() == 6.0
    assert schedule.Tt() == 6.0
    assert schedule.Td_ti() == 14.0
    assert schedule.Tr_ti() == 15.0
    assert schedule.exit_asymptomatic_time == float("inf")
    assert schedule.Trd_ati() == 14.0


@pytest.mark.parametrize("compartment", [1, 2, 3, 4])
def test_schedule_update_accepts_each_infected_compartment(monkeypatch, compartment):
    model, _, _, group = make_model()
    monkeypatch.setattr(StochasticSEAITRDModule, "rand_exp_min1", lambda rate: 2.0)
    schedule = StochasticSEAITRDModule.Schedule(model, now=0.0, group=group)

    schedule.update(model, now=10.0, group=group, compartment_num=compartment)

    assert schedule.Ta() >= 10.0
    assert schedule.Ti() >= schedule.Ta()
    assert schedule.Trd_ati() == schedule.exit_infectious_time


@pytest.mark.parametrize("compartment", [0, 5])
def test_schedule_update_rejects_noninfected_compartments(compartment):
    model, _, _, group = make_model()
    schedule = StochasticSEAITRDModule.Schedule(model, now=0.0, group=group)

    with pytest.raises(AssertionError):
        schedule.update(model, now=0.0, group=group, compartment_num=compartment)


class FixedSchedule:
    def __init__(self, *, ta=1.0, tt=2.0, ti=3.0, td_ti=5.0,
                 tr_ti=7.0, trd=8.0):
        self.values = {
            "Ta": ta,
            "Tt": tt,
            "Ti": ti,
            "Td_ti": td_ti,
            "Tr_ti": tr_ti,
            "Trd_ati": trd,
        }

    def __getattr__(self, name):
        if name in self.values:
            return lambda: self.values[name]
        raise AttributeError(name)


@pytest.mark.parametrize(
    ("schedule", "expected_type"),
    [
        (FixedSchedule(ti=2), EventType.AtoI.name),
    ],
)
def test_asymptomatic_exit_selection(
    monkeypatch,
    schedule,
    expected_type,
):
    model, _, node, group = make_model()
    downstream = []
    monkeypatch.setattr(
        model,
        "_initialize_infectious_transitions",
        lambda *args: downstream.append(True),
    )

    model._initialize_asymptomatic_transitions(node, group, schedule)

    assert [event.event_type for event in node.events] == [expected_type]
    assert bool(downstream)


@pytest.mark.parametrize(
    ("schedule", "expected_type"),
    [
        (FixedSchedule(ti=8, td_ti=7, tr_ti=5), EventType.TtoR.name),
        (FixedSchedule(ti=8, td_ti=5, tr_ti=7), EventType.TtoD.name),
    ],
)
def test_treatable_exit_selection(
    monkeypatch,
    schedule,
    expected_type,
):
    model, _, node, group = make_model()

    model._initialize_treatable_transitions(node, group, schedule)

    assert [event.event_type for event in node.events] == [expected_type]


@pytest.mark.parametrize(
    ("schedule", "expected_type"),
    [
        (FixedSchedule(td_ti=7, tr_ti=5), EventType.ItoR.name),
        (FixedSchedule(td_ti=5, tr_ti=7), EventType.ItoD.name),
    ],
)
def test_infectious_exit_selection(schedule, expected_type):
    model, _, node, group = make_model()

    model._initialize_infectious_transitions(node, group, schedule)

    assert [event.event_type for event in node.events] == [expected_type]


def test_contact_initialization_skips_empty_groups_and_uses_vaccine_effectiveness(
    monkeypatch,
):
    model, _, node, group = make_model()
    model._calculate_beta_w_npi = lambda node_index, node_id: [1.0]
    node.group_cache[:] = 0.0
    node.group_cache[0, RiskGroup.L.value, VaccineGroup.U.value] = 1.0
    draws = iter([0.2, 0.2, 10.0])
    monkeypatch.setattr(
        StochasticSEAITRDModule,
        "rand_exp_min1",
        lambda rate: next(draws),
    )

    model._initialize_contact_events(
        node,
        group,
        FixedSchedule(ta=1.0, trd=1.5),
        node.group_cache,
        DummyVax(),
    )

    assert sorted(event.time for event in node.events) == pytest.approx([1.2, 1.4])
    assert all(event.event_type.name == "CONTACT" for event in node.events)

    node.events.clear()
    node.group_cache[:] = 0.0
    node.group_cache[0, RiskGroup.L.value, VaccineGroup.V.value] = 1.0
    model._initialize_contact_events(
        node,
        group,
        FixedSchedule(ta=1.0, trd=2.0),
        node.group_cache,
        SimpleNamespace(vaccine_effectiveness=[1.0]),
    )
    assert node.events == []


@pytest.mark.parametrize(
    ("event_type", "source_label", "destination_label"),
    [
        (EventType.AtoI.name, "A", "I"),
        (EventType.TtoR.name, "T", "R"),
        (EventType.TtoD.name, "T", "D"),
        (EventType.ItoR.name, "I", "R"),
        (EventType.ItoD.name, "I", "D"),
    ],
)
def test_each_progression_event_moves_exactly_one_person(
    event_type,
    source_label,
    destination_label,
):
    model, _, node, group = make_model(pop=1)
    source = getattr(Compartments, source_label).value
    destination = getattr(Compartments, destination_label).value
    values = np.zeros(len(Compartments))
    values[source] = 1.0
    node.compartments.set_compartment_vector_for(group, values)
    node.add_transition_event(0.0, 0.25, event_type, group)
    initial = deepcopy(node.compartments)

    model._next_event(node, node.group_cache, initial, DummyVax())

    result = compartment_vector(node, group)
    assert result[source] == 0
    assert result[destination] == 1
    assert_population_invariants(node, 1)


def test_stale_exposed_event_unqueues_downstream_asymptomatic_event():
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0]),
    )
    node.unqueued_event_counter[
        group.age, group.risk, group.vaccine, Compartments.E.value
    ] = 1
    node.add_transition_event(0.0, 0.25, EventType.EtoA.name, group)

    model._next_event(node, node.group_cache, deepcopy(node.compartments), DummyVax())

    assert node.unqueued_event_counter[
        group.age, group.risk, group.vaccine, Compartments.A.value
    ] == 1
    assert_population_invariants(node, 1)


def test_contact_event_can_expose_target_without_changing_population(monkeypatch):
    model, _, node, group = make_model(pop=5)
    node.add_contact_event(0.0, 0.25, EventType.CONTACT, group, group)
    initial = deepcopy(node.compartments)
    transmitted = []
    monkeypatch.setattr(model, "_keep_contact", lambda *args: True)
    monkeypatch.setattr(StochasticSEAITRDModule, "rand_int", lambda low, high: 1)
    monkeypatch.setattr(model, "_is_susceptible", lambda *args: True)
    monkeypatch.setattr(
        model,
        "_transmit_disease",
        lambda *args: transmitted.append(args[1]),
    )

    model._next_event(node, node.group_cache, initial, DummyVax())

    assert transmitted == [group]
    assert_population_invariants(node, 5)


def test_keep_event_can_retain_one_original_queued_person(monkeypatch):
    model, _, node, group = make_model(pop=1)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]),
    )
    initial = deepcopy(node.compartments)
    node.unqueued_event_counter[
        group.age, group.risk, group.vaccine, Compartments.A.value
    ] = 1
    event = SimpleNamespace(origin=group, init_time=-1.0)
    monkeypatch.setattr(StochasticSEAITRDModule, "rand_mt", lambda: 0.75)

    assert model._keep_event(node, Compartments.A.value, event, initial)
    assert initial.compartment_data[
        group.age, group.risk, group.vaccine, Compartments.A.value
    ] == 0


def test_keep_contact_updates_counters_for_kept_and_discarded_contacts(monkeypatch):
    model, _, node, group = make_model()
    index = (group.age, group.risk, group.vaccine)

    node.contact_counter[index] = 2
    node.unqueued_contact_counter[index] = 1
    monkeypatch.setattr(StochasticSEAITRDModule, "rand_mt", lambda: 0.75)
    assert model._keep_contact(node, group)
    assert node.contact_counter[index] == 1
    assert node.unqueued_contact_counter[index] == 1

    node.contact_counter[index] = 2
    node.unqueued_contact_counter[index] = 1
    monkeypatch.setattr(StochasticSEAITRDModule, "rand_mt", lambda: 0.25)
    assert not model._keep_contact(node, group)
    assert node.contact_counter[index] == 1
    assert node.unqueued_contact_counter[index] == 0


def test_susceptibility_check_and_reinitialize_placeholder():
    model, _, node, group = make_model(pop=2)

    assert model._is_susceptible(node, group, 1)
    assert not model._is_susceptible(node, group, 2)
    assert model.reinitialize_events(node) is None
