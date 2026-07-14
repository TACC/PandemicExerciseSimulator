import numpy as np
import pytest
import importlib
import sys
from types import SimpleNamespace

GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules["baseclasses.Group"] = GroupModule

from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses import Group # needed to set dynamic Compartment Enum
from src.baseclasses.Group import RiskGroup, VaccineGroup, Compartments
from src.baseclasses.Node import Node
from src.baseclasses.Network import Network
from src.baseclasses.Day import Day
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.disease.DeterministicSEIRS import DeterministicSEIRS, SEIRS_model, SEITRS_model

#////////////////////
#### Helper Funs ####

# Make a single node for tests below
def make_network_with_population(pop=1000, compartment_labels=None):
    if compartment_labels is None:
        compartment_labels = ["S", "E", "I", "R"]
    net  = Network(compartment_labels)
    pc   = PopulationCompartments(age_group_pops=[pop], high_risk_ratios=[0.0])
    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    net._add_node(node)
    return net

def make_params(*, num_age=1, R0=2.0, E_to_I_days=3.0, I_to_R_days=4.0,
                R_to_S_days=0, compartments=None, antiviral_parameters=None):
    if compartments is None:
        compartments = ["S", "E", "I", "R"]
    return SimpleNamespace(
        number_of_age_groups=num_age,
        np_contact_matrix=np.eye(num_age, dtype=float),
        disease_parameters={
            "compartments": compartments,
            "R0": R0,
            "E_to_I_days": E_to_I_days,
            "I_to_R_days": I_to_R_days,
            "R_to_S_days": R_to_S_days,
            "T_to_R_days": "5",
            "rel_inf_T_to_I": "0.5",
            "relative_susceptibility": [1.0]*num_age,
        },
        antiviral_parameters=antiviral_parameters or {},
        relative_susceptibility=[1.0]*num_age,
    )

def make_seirs_model(test_params):
    days = Day(1)
    npi = NonPharmaInterventions([], days.day, 1, test_params.number_of_age_groups)
    parent = DiseaseModel(test_params, npi, 0)
    return DeterministicSEIRS(parent)

class DummyVax:
    def __init__(self, ve_by_age):
        self.vaccine_effectiveness = list(ve_by_age)

def get_group(*, age=0, risk=RiskGroup.L.value, vax=VaccineGroup.U.value):
    return Group.Group(age=age, risk_group=risk, vaccine_group=vax)

#/////////////////////////////////////
#### Tests: SEIRS waning behavior ####

def test_init_omega_from_immune_period_zero_and_365():
    """omega should be 0 for R_to_S_days=0; 1/365 for 365."""
    m0 = make_seirs_model(make_params(R_to_S_days=0))
    assert m0.omega == 0.0

    m365 = make_seirs_model(make_params(R_to_S_days=365))
    assert np.isclose(m365.omega, 1/365)

def test_seirs_step_no_transmission_omega_zero_equals_seir_local_math():
    """With transmission_prob=0 and omega=0, R must not decrease and S must not increase."""
    y = np.array([900.0, 0.0, 0.0, 100.0])
    transmission_prob = 0.0
    sigma = 1/3.0
    gamma = 1/4.0
    omega = 0.0

    dy = SEIRS_model(y, transmission_prob, sigma, gamma, omega)
    y_next = y + dy

    # S unchanged, R unchanged (no I to feed R, and omega=0)
    np.testing.assert_allclose(y_next[0], 900.0, atol=1e-12) # S
    np.testing.assert_allclose(y_next[3], 100.0, atol=1e-12) # R

def test_seirs_step_no_transmission_omega_365_returns_R_to_S():
    """With transmission_prob=0 and omega=1/365, S increases by omega*R and R decreases by same."""
    y = np.array([900.0, 0.0, 0.0, 100.0])
    transmission_prob = 0.0
    sigma = 1/3.0
    gamma = 1/4.0
    omega = 1/365.0

    dy = SEIRS_model(y, transmission_prob, sigma, gamma, omega)
    y_next = y + dy

    delta = 100.0 / 365.0
    np.testing.assert_allclose(y_next[0], 900.0 + delta, rtol=0, atol=1e-9) # S
    np.testing.assert_allclose(y_next[3], 100.0 - delta, rtol=0, atol=1e-9) # R


def test_seitrs_step_moves_t_to_r_without_creating_t():
    y = np.array([900.0, 0.0, 10.0, 20.0, 70.0])

    dy = SEITRS_model(
        y,
        transmission_prob=0.0,
        sigma=1 / 3.0,
        gamma=1 / 4.0,
        T_to_R_rate=1 / 5.0,
        omega=0.0,
    )
    y_next = y + dy

    np.testing.assert_allclose(y_next, [900.0, 0.0, 7.5, 16.0, 76.5], atol=1e-12)
    assert np.isclose(dy.sum(), 0.0)


def test_seitrs_step_keeps_t_zero_when_no_antivirals_created_it():
    y = np.array([900.0, 0.0, 10.0, 0.0, 90.0])

    dy = SEITRS_model(
        y,
        transmission_prob=0.0,
        sigma=1 / 3.0,
        gamma=1 / 4.0,
        T_to_R_rate=1 / 5.0,
        omega=0.0,
    )

    assert (y + dy)[3] == 0.0

def test_simulate_waning_zero_no_R_to_S_flow():
    """Full simulate(): with R_to_S_days=0 and no infectious, R must not move back to S."""
    net = make_network_with_population()
    node = net.nodes[0]
    g = get_group(age=0, vax=VaccineGroup.U.value)

    # Put everyone in S/R, no E/I to isolate waning behavior
    v = np.array([900.0, 0.0, 0.0, 100.0])
    node.compartments.set_compartment_vector_for(g, v)

    params = make_params(num_age=1, R_to_S_days=0)
    model = make_seirs_model(params)
    vax = DummyVax([0.0])

    model.simulate(node, time=0, vaccine_model=vax)
    S_after, E_after, I_after, R_after = node.compartments.get_compartment_vector_for(g)

    np.testing.assert_allclose([S_after, E_after, I_after, R_after],
                               [900.0, 0.0, 0.0, 100.0], atol=1e-12)

def test_simulate_waning_365_moves_R_to_S_by_expected_amount():
    """Full simulate(): with R_to_S_days=365 and no infectious, S+=R/365 and R-=R/365."""
    net = make_network_with_population()
    node = net.nodes[0]
    g = get_group(age=0, vax=VaccineGroup.U.value)

    v = np.array([900.0, 0.0, 0.0, 100.0])
    node.compartments.set_compartment_vector_for(g, v)

    params = make_params(num_age=1, R_to_S_days=365)
    model = make_seirs_model(params)
    vax = DummyVax([0.0])

    model.simulate(node, time=0, vaccine_model=vax)
    S_after, E_after, I_after, R_after = node.compartments.get_compartment_vector_for(g)

    delta = 100.0 / 365.0
    np.testing.assert_allclose(S_after, 900.0 + delta, rtol=0, atol=1e-9)
    np.testing.assert_allclose(E_after, 0.0, rtol=0, atol=1e-12)
    np.testing.assert_allclose(I_after, 0.0, rtol=0, atol=1e-12)
    np.testing.assert_allclose(R_after, 100.0 - delta, rtol=0, atol=1e-9)

def test_simulate_waning_and_transmission_both_apply_in_S_equation():
    """
    With nonzero transmission and omega>0, S change should reflect:
        ΔS ≈ - (transmission_prob * S) + (omega * R)
    We create a small I to induce some transmission and verify sign & rough magnitude.
    """
    net = make_network_with_population()
    node = net.nodes[0]
    g = get_group(age=0, vax=VaccineGroup.U.value)

    # Seed some I and R to activate both terms (keep numbers modest to avoid edge caps)
    v = np.array([900.0, 10.0, 10.0, 80.0])  # S,E,I,R
    node.compartments.set_compartment_vector_for(g, v)

    # Identity contact matrix → focal contacts itself; R0 large enough for noticeable transmission
    params = make_params(num_age=1, R0=3.0, E_to_I_days=3.0,
                         I_to_R_days=4.0, R_to_S_days=365)
    model = make_seirs_model(params)
    vax = DummyVax([0.0])

    # Record S before
    S_before = node.compartments.get_compartment_vector_for(g)[Compartments.S.value]
    model.simulate(node, time=0, vaccine_model=vax)
    S_after = node.compartments.get_compartment_vector_for(g)[Compartments.S.value]

    # Expected: S should go DOWN overall (transmission dominates) but not by more than S
    assert S_after < S_before, "S should decrease when transmission is present"
    assert S_after >= 0.0, "S must not go negative (guarded by min(trans_prob*S, S))"


def test_simulate_uses_treated_compartment_when_present():
    net = make_network_with_population(compartment_labels=["S", "E", "I", "T", "R"])
    node = net.nodes[0]
    g = get_group(age=0, vax=VaccineGroup.U.value)
    node.compartments.set_compartment_vector_for(g, np.array([900.0, 0.0, 10.0, 20.0, 70.0]))

    params = make_params(
        num_age=1,
        compartments=["S", "E", "I", "T", "R"],
        antiviral_parameters={"antiviral_stockpile": []},
    )
    model = make_seirs_model(params)
    vax = DummyVax([0.0])

    model.simulate(node, time=0, vaccine_model=vax)
    S_after, E_after, I_after, T_after, R_after = node.compartments.get_compartment_vector_for(g)

    assert model.has_treated_compartment is True
    assert T_after < 20.0
    assert R_after > 70.0
    assert min(S_after, E_after, I_after, T_after, R_after) >= 0.0
