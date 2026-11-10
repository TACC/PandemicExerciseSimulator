import pytest
import numpy as np
from types import SimpleNamespace

from src.models.disease.DiseaseModel import DiseaseModel
from src.models.disease.DeterministicSEAITRD import SEAITRD_model, DeterministicSEAITRD
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.Day import Day

#////////////////////
#### Helper Funs ####

# Make a single node for tests below
def make_network_with_population(pop=100):
    compartment_labels = ["S", "E", "I", "R"]
    net = Network(compartment_labels)
    pc   = PopulationCompartments(age_group_pops=[pop], high_risk_ratios=[0.0])
    node = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    net._add_node(node)
    return net

def make_params(num_age_grp=2, compartments=None):
    params = SimpleNamespace(
        number_of_age_groups=num_age_grp,
        np_contact_matrix=np.eye(num_age_grp, dtype=float),
        high_risk_ratios=[0.0] * num_age_grp,
        disease_parameters={
            "compartments": compartments or ["S", "E", "A", "I", "T", "R", "D"],
            "R0":    "1.0",
            "beta_scale": "1.0",
            "E_to_A_days":   "4.0",
            "A_to_I_days": "4.0",
            "I_to_R_days": "4.0",
            "T_to_R_days": "2.0",
            "I_to_D_invdays":    ["0.25"] * num_age_grp,
            "highrisk_death_multiplier": "9",
            "relative_susceptibility": ["1.0"] * num_age_grp
        }
    )
    return params

class DummyVax:
    def __init__(self, ve_by_age):
        self.vaccine_effectiveness = list(ve_by_age)

#//////////////
#### TESTS ####

def test_two_days_transmission():
    # Lots of set-up
    compartment_labels = ["S", "E", "A", "I", "T", "R", "D"]
    network = Network(compartment_labels)
    groups  = [10, 10]; high_risk_ratios = [0.0, 0.0]  # all low-risk for simplicity
    pc      = PopulationCompartments(age_group_pops=groups, high_risk_ratios=high_risk_ratios)
    node    = Node(node_index=0, node_id=0, fips_id=0, compartments=pc)
    network._add_node(node)

    # Expose 1 person in group 0, low risk, unvaccinated
    initial = [
        {
            "county": 0,  # node_id
            "age_group": 0,  # group 0
            "infected": 1  # how many people to expose
        }
    ]
    params =  make_params() # not using ModelParameters bc it requires travel params etc
    simulation_days = Day(1)
    npi = NonPharmaInterventions([], simulation_days.day, 1, 2)
    vax = DummyVax([0.0])
    parent = DiseaseModel(params, npi, 0)
    disease_model = DeterministicSEAITRD(parent)
    disease_model.set_initial_conditions(initial, network, vax)

    # Simulate: 1 day, 1 node, 2 age groups
    disease_model.simulate(node, 0, vax)

    ############# DAY 1 TESTS ##################
    snapshot = simulation_days.snapshot(network)
    S_total, E_total, A_total, *_ = snapshot

    # a) compartments in should equal compartments out
    assert len(compartment_labels) == len(snapshot)

    # b) Only 1 person should have moved out of susceptible
    expected_S_total = sum(groups) - 1  # we seeded 1 exposed
    assert abs(S_total - expected_S_total) < 1e-6, f"Expected S={expected_S_total}, got {S_total}"

    # c) No more than 0.25 should have moved from E to A
    # (with E_to_A_rate = 1/4, dt = 1.0, E -> A ~ E * E_to_A_rate * dt = 1 * (1/4) * 1 = 0.25)
    # so we assert that no more than 0.34 is in A
    assert A_total <= 0.25, f"Too much in A: got {A_total}"

    disease_model.simulate(node, 1, vax)

    ############# DAY 2 TESTS ##################
    snapshot = simulation_days.snapshot(network)
    S_total, E_total, A_total, *_ = snapshot

    expected_snapshot_day2 = {
        "S": 18.8882002, "E": 0.6742998, "A": 0.375, "I": 0.0625,
        "T": 0.0, "R": 0.0, "D": 0.0
    }
    expected_vec = np.array([expected_snapshot_day2[lbl] for lbl in compartment_labels], dtype=float)

    # with transmission probability we aren't taking exactly linear Euler steps
    np.testing.assert_allclose(snapshot, expected_vec, rtol=1e-3, atol=1e-4,
        err_msg=f"Day 2 snapshot mismatch; order={compartment_labels}"
    )

def test_euler_step_mass_conservation():
    # Initial compartments: S, E, A, I, T, R, D
    y = np.array([9.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    # Parameters (very simple ones)
    transmission_rate = 0.0  # No new infections
    E_to_A_rate = 1.0  # Exposed to asymptomatic rate
    A_to_I_rate = 1.0  # Asymptomatic to infectious rate
    I_to_R_rate = 1.0
    T_to_R_rate = 1.0
    I_to_D_rate = 0.0
    T_to_D_rate = 0.0

    # Euler time step forward of difference
    y_diff = SEAITRD_model(
        y, transmission_rate, E_to_A_rate, A_to_I_rate,
        I_to_R_rate, T_to_R_rate, I_to_D_rate, T_to_D_rate
    )
    # New y values after 1 time step forward
    y_new = y + y_diff

    # Total population should remain constant (no deaths, no births)
    np.testing.assert_allclose(np.sum(y), np.sum(y_new), atol=1e-6)


def test_deterministic_seaitrd_has_no_natural_i_to_t_flow():
    y = np.array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])

    y_diff = SEAITRD_model(
        y,
        transmission_prob=0.0,
        E_to_A_rate=1.0,
        A_to_I_rate=1.0,
        I_to_R_rate=0.0,
        T_to_R_rate=0.0,
        I_to_D_rate=0.0,
        T_to_D_rate=0.0,
    )

    assert y_diff[3] == 0.0
    assert y_diff[4] == 0.0


def test_deterministic_seaitrd_existing_t_exits_without_new_t_entry():
    y = np.array([0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0])

    y_diff = SEAITRD_model(
        y,
        transmission_prob=0.0,
        E_to_A_rate=1.0,
        A_to_I_rate=1.0,
        I_to_R_rate=0.25,
        T_to_R_rate=1.0,
        I_to_D_rate=0.0,
        T_to_D_rate=0.0,
    )

    np.testing.assert_allclose(y_diff, np.array([0.0, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0]))


def test_deterministic_seaitrd_rejects_omitting_t_compartment():
    y = np.array([0.0, 1.0, 0.0, 0.0, 0.0, 0.0])

    with pytest.raises(ValueError, match="SEAITRD requires compartments"):
        SEAITRD_model(
            y,
            transmission_prob=0.0,
            E_to_A_rate=1.0,
            A_to_I_rate=1.0,
            I_to_R_rate=0.0,
            T_to_R_rate=0.0,
            I_to_D_rate=0.0,
            T_to_D_rate=0.0,
        )


def test_deterministic_seaitrd_requires_t_compartment():
    params = make_params(compartments=["S", "E", "A", "I", "R", "D"])
    npi = NonPharmaInterventions([], 1, 1, 2)
    parent = DiseaseModel(params, npi, 0)

    with pytest.raises(ValueError, match="SEAITRD requires the T compartment"):
        DeterministicSEAITRD(parent)


def test_deterministic_seaitrd_uses_configured_highrisk_death_multiplier():
    params = make_params(num_age_grp=1)
    params.disease_parameters["I_to_D_invdays"] = ["0.2"]
    params.disease_parameters["highrisk_death_multiplier"] = "3"
    npi = NonPharmaInterventions([], 1, 1, 1)
    parent = DiseaseModel(params, npi, 0)

    model = DeterministicSEAITRD(parent)

    assert model.I_to_D_rates_by_risk[0][0] == 0.2
    assert model.I_to_D_rates_by_risk[0][1] == pytest.approx(0.6)


def test_deterministic_seaitrd_t_uses_separate_recovery_and_reduced_death_rates():
    y = np.array([0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0])

    y_diff = SEAITRD_model(
        y,
        transmission_prob=0.0,
        E_to_A_rate=1.0,
        A_to_I_rate=1.0,
        I_to_R_rate=0.25,
        T_to_R_rate=0.5,
        I_to_D_rate=0.25,
        T_to_D_rate=0.125,
    )

    expected = np.array([0.0, 0.0, 0.0, -0.5, -0.625, 0.75, 0.375])
    np.testing.assert_allclose(y_diff, expected)
