import pytest
import numpy as np
from icecream import ic
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.disease.DeterministicSEATIRD import SEATIRD_model
from src.models.disease.DeterministicSEATIRD import DeterministicSEATIRD
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.ModelParameters import ModelParameters
from src.baseclasses.Day import Day

# disable print of all the icecream/ic print statements
ic.disable()

class DummyInput:
    def __init__(self):
        self.R0 = 1.0
        self.beta_scale = 1.0
        self.tau = 4.0
        self.kappa = 4.0
        self.gamma = 4.0
        self.chi = 4.0
        self.rho = 0.0
        self.nu = [0.25, 0.25]
        self.non_pharma_interventions = []

        # dummy paths, won’t be used
        self.high_risk_ratios_file = "not_used.txt"
        self.relative_susceptibility_file = "not_used.txt"
        self.flow_reduction_file = "not_used.txt"
        self.contact_data_file = "not_used.csv"

        # required for init but currently unused in _calculate_beta_w_npi
        self.antiviral_effectiveness = None
        self.antiviral_wastage_factor = None
        self.antiviral_stockpile = []
        
        self.vaccine_wastage_factor = None
        self.vaccine_pro_rata = None
        self.vaccine_adherence = None
        self.vaccine_effectiveness = [0.0, 0.0]
        self.vaccine_eff_lag_days = None
        self.vaccine_stockpile = []

def test_two_days_transmission():
    # Setup: 2 age groups, each with 10 people
    groups = [10, 10]
    high_risk_ratios = [0.0, 0.0]  # all low-risk for simplicity

    # Create compartment structure (fills everyone into S compartments)
    pc = PopulationCompartments(groups, high_risk_ratios)
    ic("made pop compartments")
    ic(pc)

    # Expose 1 person in group 0, low risk, unvaccinated
    initial = [
        {
            "county": 0,  # node_id
            "age_group": 0,  # group 0
            "infected": 1  # how many people to expose
        }
    ]

    # Create node and add compartments
    node = Node(node_index=0, node_id=0, fips_id=0, compartments = pc)
    ic("made node")
    ic(node)

    # Add node to a dummy network
    network = Network()
    network._add_node(node)
    ic("node in network")

    dummy_input = DummyInput()
    params = ModelParameters(dummy_input)
    ic("made parameters")

    # Manually override what load_data_files would normally load
    params.high_risk_ratios = [0.0, 0.0]
    params.relative_susceptibility = [1.0, 1.0]  # or any test value
    params.flow_reduction = [0.0, 0.0]  # unused in most tests
    ic("added more params")

    # Manually assign a contact matrix instead of calling load_contact_matrix
    params.np_contact_matrix = np.array([
        [1.0, 0],
        [0, 1.0]
    ])
    ic("added contact")
    params._set_age_group_size()  # important: sets `number_of_age_groups`
    ic("num age groups set")

    # Simulate: 1 day, 1 node, 2 age groups
    simulation_days = Day(1)
    empty_npi = NonPharmaInterventions([], simulation_days.day, 1, 2)
    ic("empty npis made")

    disease_model = DiseaseModel(params, empty_npi, False, 0.0)
    disease_model = DeterministicSEATIRD(disease_model)
    ic("model defined")

    disease_model.set_initial_conditions(initial, network)
    ic("initialized model")
    disease_model.simulate(node, 0)
    ic("model simulated one day")

    ############# DAY 1 TESTS ##################
    snapshot = simulation_days.snapshot(network)
    ic(snapshot)
    S_total, E_total, A_total, *_ = snapshot

    # a) Only 1 person should have moved out of susceptible
    expected_S_total = sum(groups) - 1  # we seeded 1 exposed
    assert abs(S_total - expected_S_total) < 1e-6, f"Expected S={expected_S_total}, got {S_total}"

    # b) No more than 0.25 should have moved from E to A
    # (with tau = 1/4, dt = 1.0, E -> A ~ E * tau * dt = 1 * (1/4) * 1 = 0.25)
    # so we assert that no more than 0.34 is in A
    assert A_total <= 0.25, f"Too much in A: got {A_total}"

    disease_model.simulate(node, 1)

    ############# DAY 2 TESTS ##################
    snapshot = simulation_days.snapshot(network)
    S_total, E_total, A_total, *_ = snapshot
    ic(snapshot)

    expected_snapshot_day2 = {
        "S": 18.8875, "E": 0.675, "A": 0.25, "T": 0.0625,
        "I": 0.0, "R": 0.0625, "D": 0.0625
    }

    labels = ["S", "E", "A", "T", "I", "R", "D"]
    for i, expected in enumerate(expected_snapshot_day2.values()):
        actual = snapshot[i]
        label = labels[i]
        assert abs(actual - expected) < 1e-5, f"{label} expected {expected}, got {actual}"

def test_euler_step_mass_conservation():
    # Initial compartments: S, E, A, T, I, R, D
    y = np.array([9.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    # Parameters (very simple ones)
    transmission_rate = 0.0  # No new infections
    tau = 1.0  # Latent period
    kappa = 1.0  # Asymptomatic period
    chi = 1.0  # Treatable period
    gamma = 1.0  # Symptomatic period
    nu = 0.0  # No deaths

    # Euler time step forward of difference
    y_diff = SEATIRD_model(y, transmission_rate, tau, kappa, chi, gamma, nu)
    # New y values after 1 time step forward
    y_new = y + y_diff

    # Total population should remain constant (no deaths, no births)
    np.testing.assert_allclose(np.sum(y), np.sum(y_new), atol=1e-6)


