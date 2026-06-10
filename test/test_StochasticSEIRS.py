import numpy as np
import importlib
import sys
from types import SimpleNamespace

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

import src.models.disease.StochasticSEIRS as StochasticSEIRSModule
from src.baseclasses.Group import Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.disease.DiseaseModel import DiseaseModel

from src.models.disease.StochasticSEIRS import SEIRS_model, SEITRS_model


class FloorPoissonRng:
    def poisson(self, lam):
        return int(lam)


class HugePoissonRng:
    def poisson(self, lam):
        return 10**9


def test_seitrs_model_does_not_create_treated_without_antivirals():
    y = np.array([100.0, 10.0, 8.0, 5.0, 20.0])

    daily_change = SEITRS_model(
        y,
        0.0,   # S => E
        0.2,   # E => I
        0.5,   # I => R
        0.2,   # T => R
        0.1,   # R => S
        rng=FloorPoissonRng(),
    )

    np.testing.assert_allclose(
        daily_change,
        np.array([2.0, -2.0, -2.0, -1.0, 3.0]),
    )
    assert np.isclose(daily_change.sum(), 0.0)


def test_seirs_model_caps_transitions_so_compartments_never_go_negative():
    y = np.array([3.0, 2.0, 1.0, 4.0])

    daily_change = SEIRS_model(
        y,
        999.0,
        999.0,
        999.0,
        999.0,
        rng=HugePoissonRng(),
    )

    tomorrow = y + daily_change
    assert np.all(tomorrow >= 0.0)
    assert np.isclose(tomorrow.sum(), y.sum())


def test_seitrs_model_caps_transitions_so_compartments_never_go_negative():
    y = np.array([3.0, 2.0, 1.0, 5.0, 4.0])

    daily_change = SEITRS_model(
        y,
        999.0,
        999.0,
        999.0,
        999.0,
        999.0,
        rng=HugePoissonRng(),
    )

    tomorrow = y + daily_change
    assert np.all(tomorrow >= 0.0)
    assert np.isclose(tomorrow.sum(), y.sum())


def make_seirs_params(compartments, antiviral_parameters=None):
    return SimpleNamespace(
        number_of_age_groups=1,
        disease_parameters={
            "compartments": compartments,
            "R0": "1.0",
            "latent_period_days": "2.0",
            "infectious_period_days": "4.0",
            "immune_period_days": "0",
            "T_to_R_days": "2.0",
            "rel_inf_T_to_I": "0.25",
        },
        antiviral_parameters=antiviral_parameters or {},
        np_contact_matrix=np.array([[1.0]]),
    )


def make_seirs_child(compartments, antiviral_parameters=None):
    net = Network(compartments)
    node = Node(
        node_index=0,
        node_id=0,
        fips_id=0,
        compartments=PopulationCompartments([10], [0.0]),
    )
    net._add_node(node)

    npis = SimpleNamespace(schedule=np.zeros((2, 1, 1)))
    parent = DiseaseModel(make_seirs_params(compartments, antiviral_parameters), npis, now=0.0)
    child = parent.get_child("seitrs-stochastic")
    child._rng = FloorPoissonRng()
    vaccine_model = SimpleNamespace(vaccine_effectiveness=[0.0])

    return child, node, vaccine_model


def test_stochastic_seirs_uses_seitrs_model_when_t_compartment_exists(monkeypatch):
    model, node, vaccine_model = make_seirs_child(
        ["S", "E", "I", "T", "R"],
        antiviral_parameters={"antiviral_stockpile": []},
    )
    calls = {"seirs": 0, "seitrs": 0}

    def fake_seirs(y, *args, rng):
        calls["seirs"] += 1
        return np.zeros_like(y)

    def fake_seitrs(y, *args, rng):
        calls["seitrs"] += 1
        return np.zeros_like(y)

    monkeypatch.setattr(StochasticSEIRSModule, "SEIRS_model", fake_seirs)
    monkeypatch.setattr(StochasticSEIRSModule, "SEITRS_model", fake_seitrs)

    model.simulate(node, time=1, vaccine_model=vaccine_model)

    assert model.has_treated_compartment is True
    assert calls["seitrs"] > 0
    assert calls["seirs"] == 0


def test_stochastic_seirs_uses_seirs_model_without_t_compartment(monkeypatch):
    model, node, vaccine_model = make_seirs_child(["S", "E", "I", "R"])
    calls = {"seirs": 0, "seitrs": 0}

    def fake_seirs(y, *args, rng):
        calls["seirs"] += 1
        return np.zeros_like(y)

    def fake_seitrs(y, *args, rng):
        calls["seitrs"] += 1
        return np.zeros_like(y)

    monkeypatch.setattr(StochasticSEIRSModule, "SEIRS_model", fake_seirs)
    monkeypatch.setattr(StochasticSEIRSModule, "SEITRS_model", fake_seitrs)

    model.simulate(node, time=1, vaccine_model=vaccine_model)

    assert model.has_treated_compartment is False
    assert calls["seirs"] > 0
    assert calls["seitrs"] == 0


def test_t_stays_zero_without_antiviral_release_during_one_day_update():
    model, node, vaccine_model = make_seirs_child(["S", "E", "I", "T", "R"])
    group = StochasticSEIRSModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(group, np.array([80.0, 10.0, 10.0, 0.0, 0.0]))

    model.simulate(node, time=1, vaccine_model=vaccine_model)

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.T.value] == 0.0
