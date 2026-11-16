import importlib
import sys
from types import SimpleNamespace

import numpy as np
import pytest

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

import src.models.disease.StochasticSEIHRD as StochasticSEIHRDModule
from src.baseclasses.Group import Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.disease.StochasticSEIHRD import SEITHRD_model


class FloorPoissonRng:
    def poisson(self, lam):
        return int(lam)


class HugePoissonRng:
    def poisson(self, lam):
        return 10**9


class DummyVax:
    vaccine_effectiveness = [0.0]
    vaccine_effectiveness_hosp = [0.0]


def make_params(compartments, antiviral_parameters=None):
    return SimpleNamespace(
        number_of_age_groups=1,
        np_contact_matrix=np.array([[1.0]]),
        disease_parameters={
            "compartments": compartments,
            "R0": "2.2",
            "E_to_IPandIA_days": "1.0",
            "IP_to_IS_days": "1.0",
            "IS_to_H_days": "3.0",
            "H_to_D_days": "5.0",
            "H_to_R_days": ["4.0"],
            "IS_to_R_days": "7.0",
            "IA_to_R_days": "2.0",
            "T_to_R_days": "5.0",
            "prop_E_to_IA": ["0.25"],
            "prop_IS_to_H_lowrisk": ["0.1"],
            "prop_H_to_D": ["0.05"],
            "highrisk_hosp_multiplier": "2.0",
            "rel_inf_IP_to_IS": "0.45",
            "rel_inf_IA_to_IS": "0.97",
            "rel_inf_T_to_IS": "0.0",
            "relative_susceptibility": ["1.0"],
        },
        antiviral_parameters=antiviral_parameters or {},
    )


def make_model(compartments, antiviral_parameters=None):
    net = Network(compartments)
    node = Node(
        node_index=0,
        node_id=0,
        fips_id=0,
        compartments=PopulationCompartments([100], [0.0]),
    )
    net._add_node(node)
    npis = SimpleNamespace(schedule=np.zeros((2, 1, 1)))
    parent = DiseaseModel(make_params(compartments, antiviral_parameters), npis, now=0.0)
    model = parent.get_child("seihrd-stochastic")
    model._rng = FloorPoissonRng()
    return model, node


def test_seithrd_model_caps_transitions_so_compartments_never_go_negative():
    y = np.array([3.0, 2.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0])

    daily_change = SEITHRD_model(
        y,
        999.0,
        999.0,
        0.25,
        999.0,
        999.0,
        999.0,
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


def test_seithrd_model_splits_t_to_h_and_r():
    y = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 10.0, 0.0, 0.0])

    daily_change = SEITHRD_model(
        y,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.2,
        0.5,
        rng=FloorPoissonRng(),
    )

    tomorrow = y + daily_change
    assert tomorrow[5] == 2.0
    assert tomorrow[6] == 4.0
    assert tomorrow[7] == 4.0


def test_seihrd_with_t_reduces_but_does_not_eliminate_hospitalization():
    model, node = make_model(
        ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"],
        antiviral_parameters={
            "antiviral_stockpile": [],
            "antiviral_effectiveness_hosp": "0.25",
        },
    )
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0]),
    )

    model.simulate(node, time=1, vaccine_model=DummyVax())

    result = node.compartments.get_compartment_vector_for(group)
    assert result[Compartments.H.value] > 0.0
    assert result[Compartments.H.value] < 10.0
    assert result[Compartments.T.value] > 0.0
    assert result[Compartments.R.value] > 0.0


def test_seihrd_antiviral_effectiveness_hosp_defaults_to_complete_protection():
    model, node = make_model(
        ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"],
        antiviral_parameters={"antiviral_stockpile": []},
    )
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0]),
    )

    model.simulate(node, time=1, vaccine_model=DummyVax())

    result = node.compartments.get_compartment_vector_for(group)
    assert model.antiviral_effectiveness_hosp == [1.0]
    assert result[Compartments.H.value] == 0.0
    assert result[Compartments.R.value] > 0.0


def test_stochastic_seihrd_uses_treated_variant_when_t_compartment_exists(monkeypatch):
    model, node = make_model(
        ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"],
        antiviral_parameters={"antiviral_stockpile": []},
    )
    calls = {"base": 0, "treated": 0}

    def fake_base(y, *args, rng, return_flows=False):
        calls["base"] += 1
        result = np.zeros_like(y)
        return (result, {}) if return_flows else result

    def fake_treated(y, *args, rng, return_flows=False):
        calls["treated"] += 1
        result = np.zeros_like(y)
        return (result, {}) if return_flows else result

    monkeypatch.setattr(StochasticSEIHRDModule, "SEIHRD_model", fake_base)
    monkeypatch.setattr(StochasticSEIHRDModule, "SEITHRD_model", fake_treated)

    model.simulate(node, time=1, vaccine_model=DummyVax())

    assert model.has_treated_compartment is True
    assert calls["treated"] > 0
    assert calls["base"] == 0


def test_stochastic_seihrd_uses_base_variant_without_t_compartment(monkeypatch):
    model, node = make_model(["S", "E", "IA", "IP", "IS", "H", "R", "D"])
    calls = {"base": 0, "treated": 0}

    def fake_base(y, *args, rng, return_flows=False):
        calls["base"] += 1
        result = np.zeros_like(y)
        return (result, {}) if return_flows else result

    def fake_treated(y, *args, rng, return_flows=False):
        calls["treated"] += 1
        result = np.zeros_like(y)
        return (result, {}) if return_flows else result

    monkeypatch.setattr(StochasticSEIHRDModule, "SEIHRD_model", fake_base)
    monkeypatch.setattr(StochasticSEIHRDModule, "SEITHRD_model", fake_treated)

    model.simulate(node, time=1, vaccine_model=DummyVax())

    assert model.has_treated_compartment is False
    assert calls["base"] > 0
    assert calls["treated"] == 0


def test_seihrd_t_compartment_with_antivirals_requires_t_to_r_days():
    params = make_params(
        ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"],
        antiviral_parameters={"antiviral_stockpile": []},
    )
    del params.disease_parameters["T_to_R_days"]
    npis = SimpleNamespace(schedule=np.zeros((2, 1, 1)))
    parent = DiseaseModel(params, npis, now=0.0)

    with pytest.raises(ValueError, match="T_to_R_days is required"):
        parent.get_child("seihrd-stochastic")


def test_seihrd_rejects_invalid_antiviral_effectiveness_hosp():
    params = make_params(
        ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"],
        antiviral_parameters={"antiviral_effectiveness_hosp": "1.5"},
    )
    npis = SimpleNamespace(schedule=np.zeros((2, 1, 1)))
    parent = DiseaseModel(params, npis, now=0.0)

    with pytest.raises(ValueError, match="antiviral_effectiveness_hosp"):
        parent.get_child("seihrd-stochastic")


def test_seihrd_records_incident_compartment_entries():
    model, node = make_model(["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"])
    group = GroupModule.Group(0, RiskGroup.L.value, VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(
        group,
        np.array([90.0, 0.0, 0.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    )

    model.simulate(node, time=1, vaccine_model=DummyVax())

    assert node.incident_compartment_entry_count(group, ["IS"]) == 10.0


@pytest.mark.parametrize("p", [0.0, 0.012, 0.105, 0.315, 1.0])
def test_ngm_symptomatic_duration_matches_corrected_clinical_branch_probability(p):
    split = DiseaseModel.adjust_two_way_split_proportion(
        desired_realized_fraction=p, competing_rate=1/7, target_rate=1/3,
    )
    duration = StochasticSEIHRDModule.symptomatic_duration(1/3, 1/7, split)
    # Independent identity for the intended clinical branching distribution.
    assert duration == pytest.approx(p * 3 + (1-p) * 7)


def test_risk_averaged_beta_matches_full_progression_ngm():
    compartments = ["S", "E", "IA", "IP", "IS", "H", "R", "D"]
    model, node = make_model(compartments)
    node.compartments = PopulationCompartments([100], [0.25])
    net = Network(compartments)
    net._add_node(node)
    model.set_initial_conditions([], net, DummyVax())
    assert model.baseline_high_risk_fraction == pytest.approx([0.25])

    # Construct F V^-1 independently on all eight E/IP/IS/IA x risk states.
    # The target-risk shares come from population; clinical probabilities are
    # the supplied .1/.2, rather than reusing the model's corrected splits.
    F = np.zeros((8, 8))
    V = np.zeros((8, 8))
    for risk, (share, p_hosp) in enumerate([(0.75, 0.1), (0.25, 0.2)]):
        e, ip, symptomatic, ia = range(4*risk, 4*risk+4)
        V[e, e] = 1.0
        V[ip, e] = -0.75
        V[ia, e] = -0.25
        V[ip, ip] = 1.0
        V[symptomatic, ip] = -1.0
        V[symptomatic, symptomatic] = 1 / (p_hosp*3 + (1-p_hosp)*7)
        V[ia, ia] = 1/2
        for source_risk in range(2):
            for offset, infectiousness in [(1, .45), (2, 1.0), (3, .97)]:
                F[e, 4*source_risk+offset] = share * model.beta * infectiousness
    full_r0 = max(abs(np.linalg.eigvals(F @ np.linalg.inv(V))))
    assert full_r0 == pytest.approx(model.R0)
    expected_w = .75 * (.45 + .75*6.6 + .25*6.2) + .25*.97*2
    assert model.beta == pytest.approx(model.R0 / expected_w)


def test_baseline_risk_mix_uses_demographic_counts_before_and_after_seeding():
    compartments = ["S", "E", "IA", "IP", "IS", "H", "T", "R", "D"]
    model, node = make_model(compartments, {"antiviral_effectiveness_hosp": "0.25"})
    node.compartments = PopulationCompartments([100], [0.25])
    net = Network(compartments)
    net._add_node(node)
    model.set_initial_conditions([{"county": 0, "infected": 10, "age_group": 0}], net, DummyVax())
    beta = model.beta
    assert model.baseline_high_risk_fraction == pytest.approx([0.25])
    assert node.compartments.get_disease_compartment_sum()[Compartments.E.value] == 10
    # Reinitializing the calibration uses demographic counts, not remaining S.
    model.set_initial_conditions([], net, DummyVax())
    assert model.beta == pytest.approx(beta)
