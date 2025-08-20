import pytest
import numpy as np
from icecream import ic
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.baseclasses.ModelParameters import ModelParameters
from src.baseclasses.Day import Day

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
        self.non_pharma_interventions = [
            {
                "name": "School Closure",
                "day": "0",
                "duration": "2",
                "location": "113,141,201",
                "effectiveness": ["0.9", "0.0"]
            }
        ]
        self.high_risk_ratios_file = "not_used.txt"
        self.relative_susceptibility_file = "not_used.txt"
        self.flow_reduction_file = "not_used.txt"
        self.contact_data_file = "not_used.csv"
        
        self.antiviral_effectiveness = None
        self.antiviral_wastage_factor = None
        self.antiviral_stockpile = []
        self.vaccine_wastage_factor = None
        self.vaccine_pro_rata = None
        self.vaccine_adherence = None
        self.vaccine_effectiveness = [0.0, 0.0]
        self.vaccine_eff_lag_days = None
        self.vaccine_stockpile = []

def test_node_specific_npi_effect():
    dummy_input = DummyInput()
    params = ModelParameters(dummy_input)
    params.high_risk_ratios = [0.0, 0.0]
    params.relative_susceptibility = [1.0, 1.0]
    params.flow_reduction = [0.0, 0.0]
    params.np_contact_matrix = np.eye(2)
    params._set_age_group_size()

    # Create 5 dummy nodes with IDs: 113, 141, 201, 300, 400
    network = Network()
    fips_ids = [113, 141, 201, 300, 400]
    for idx, fips in enumerate(fips_ids):
        pc = PopulationCompartments([10, 10], [0.0, 0.0])
        node = Node(node_index=idx, node_id=fips, fips_id=fips, compartments=pc)
        network._add_node(node)

    # Setup NPI
    npi = NonPharmaInterventions(dummy_input.non_pharma_interventions, 10, len(fips_ids), 2)
    npi.pre_process(network)

    model = DiseaseModel(params, npi, False, 0.0)
    model.npis_schedule = npi.schedule
    model.now = 1  # simulate Day 1 (index 0)

    beta_baseline = params.beta
    beta_expected = expected_reduced_beta = [
        beta_baseline * (1.0 - 0.9),  # 90% reduction for "children"
        beta_baseline * (1.0 - 0.0)   # no reduction for "adults"
    ]

    affected_node_ids = {113, 141, 201}
    for day in range(0, 5):  # test 2 extra day to check the drop-off
        model.now = day
        for node in network.nodes:
            beta_result = model._calculate_beta_w_npi(node.node_index, node.node_id)
            ic(f"now day {day} for node {node.node_id}")
            ic(beta_result)

            # days of NPI are inclusive [0, 3]
            if node.node_id in affected_node_ids and day <= 2:
                assert np.allclose(beta_result, beta_expected, atol=1e-8), (
                    f"Node {node.node_id} beta mismatch: {beta_result} vs expected {beta_expected}"
                )
                ic(beta_expected)
            else:
                assert np.allclose(beta_result, [beta_baseline] * 2, atol=1e-8), (
                    f"Node {node.node_id} should not be affected: got {beta_result}"
                )
                ic([beta_baseline] * 2)