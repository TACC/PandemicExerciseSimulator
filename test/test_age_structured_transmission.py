"""Cross-family checks against lambda_i = sum_j beta_j C_ij I*_j/N_j."""
import importlib
import sys
from types import SimpleNamespace

import numpy as np
import pytest

sys.modules["baseclasses.Group"] = importlib.import_module("src.baseclasses.Group")

from src.baseclasses.Group import Group, Compartments, RiskGroup, VaccineGroup
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.disease.DiseaseModel import DiseaseModel


def make_case(identity, treated=False):
    if 'seaitrd' in identity:
        labels = ['S', 'E', 'A', 'I', 'T', 'R', 'D']
    elif 'seihrd' in identity:
        labels = ['S', 'E', 'IA', 'IP', 'IS', 'H'] + (['T'] if treated else []) + ['R', 'D']
    else:
        labels = ['S', 'E', 'I'] + (['T'] if treated else []) + ['R']
    net = Network(labels)
    pc = PopulationCompartments([200, 800, 0], [.5, .5, .5])
    node = Node(0, 0, 0, pc)
    net._add_node(node)
    source = np.full(len(labels), 5.)
    source[labels.index('IS' if 'IS' in labels else 'I')] = 10.
    source[0] = 50. - source[1:].sum()
    for risk in RiskGroup:
        for vaccine in VaccineGroup:
            pc.set_compartment_vector_for(Group(0, risk.value, vaccine.value), source.copy())
    fields = dict(compartments=labels, R0=1.2, beta_scale=1., E_to_I_days=1., I_to_R_days=7.,
        R_to_S_days=0, T_to_R_days=5., rel_inf_T_to_I=.5, relative_susceptibility=[1.]*3,
        E_to_A_days=1., A_to_I_days=2., I_to_D_invdays=[.01]*3, highrisk_death_multiplier=2.,
        E_to_IPandIA_days=1., IP_to_IS_days=2., IS_to_H_days=3., H_to_D_days=5.,
        H_to_R_days=[4.]*3, IS_to_R_days=7., IA_to_R_days=2., prop_E_to_IA=[.25]*3,
        prop_IS_to_H_lowrisk=[.1]*3, prop_H_to_D=[.05]*3, highrisk_hosp_multiplier=2.,
        rel_inf_IP_to_IS=.4, rel_inf_IA_to_IS=.6, rel_inf_T_to_IS=.5)
    params = SimpleNamespace(number_of_age_groups=3, disease_parameters=fields,
        antiviral_parameters={}, np_contact_matrix=np.array([[1., 3., 0.], [2., 1., 9.], [0., 0., 1.]]))
    parent = DiseaseModel(params, SimpleNamespace(schedule=np.zeros((2, 1, 3))), 0.)
    model = parent.get_child(identity)
    model.set_seed(np.random.SeedSequence(1))
    return model, node, net, labels, source


@pytest.mark.parametrize('identity,treated', [
    ('seirs-deterministic', False), ('seirs-deterministic', True),
    ('seirs-stochastic', False), ('seirs-stochastic', True),
    ('seaitrd-deterministic', True), ('seihrd-stochastic', False), ('seihrd-stochastic', True),
])
def test_daily_models_use_contacted_age_population(identity, treated, monkeypatch):
    model, node, _, labels, source = make_case(identity, treated)
    module = importlib.import_module(type(model).__module__)
    captured = []

    def capture(y, pressure, *args, **kwargs):
        if np.sum(y) == 400.:  # Either susceptible target risk subgroup in age 1.
            captured.append(pressure)
        return np.zeros_like(y), {}

    stage = 'SEAITRD_model' if 'seaitrd' in identity else (
        ('SEITHRD_model' if treated else 'SEIHRD_model') if 'seihrd' in identity else
        ('SEITRS_model' if treated else 'SEIRS_model'))
    monkeypatch.setattr(module, stage, capture)
    weights = {'I': 1., 'T': .5} if 'seirs' in identity else (
        {'A': 1., 'I': 1., 'T': 1.} if 'seaitrd' in identity else {'IA': .6, 'IP': .4, 'IS': 1., 'T': .5})
    infectious = 4 * sum(weight * source[labels.index(label)] for label, weight in weights.items() if label in labels)
    hazard = model.beta * 2. * infectious / 200.
    expected = -np.expm1(-hazard) if identity.endswith('deterministic') else hazard
    model.simulate(node, 1, SimpleNamespace(vaccine_effectiveness=[0.]*3, vaccine_effectiveness_hosp=[0.]*3))
    assert captured == pytest.approx([expected, expected])


def test_event_model_uses_target_counts_over_infectious_age_population(monkeypatch):
    model, node, net, _, _ = make_case('seaitrd-stochastic', True)
    vax = SimpleNamespace(vaccine_effectiveness=[0.]*3)
    model.set_initial_conditions([], net, vax)
    rates = []
    model._calculate_beta_w_npi = lambda *args: [.02, .8, .9]

    def record(rate):
        rates.append(rate)
        return float('inf')

    monkeypatch.setattr(importlib.import_module(type(model).__module__), 'rand_exp_min1', record)
    model._initialize_contact_events(node, Group(0, 0, 0),
        SimpleNamespace(Ta=lambda: 0., Trd_ati=lambda: 1.), node.group_cache, vax)
    # C[target,source], beta[source], and target subgroup size / source-age size.
    assert sorted(rates) == pytest.approx(sorted([.02 * 1 * 50/200]*4 + [.02 * 2 * 400/200]*2))
    assert node.events == []
