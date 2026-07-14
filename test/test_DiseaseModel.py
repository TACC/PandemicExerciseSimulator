import pytest
import sys
import importlib
from types import SimpleNamespace
import numpy as np
from numpy.random import SeedSequence

# keep Group module path consistent if you need it elsewhere
GroupModule = importlib.import_module("src.baseclasses.Group")
sys.modules.setdefault("baseclasses.Group", GroupModule)

from src.baseclasses.ModelParameters import ModelParameters
from src.baseclasses.Network import Network
from src.baseclasses.Node import Node
from src.baseclasses.PopulationCompartments import PopulationCompartments
from src.models.disease.DiseaseModel import DiseaseModel
from src.models.treatments.NonPharmaInterventions import NonPharmaInterventions


def make_dummy_input(tmp_path):
   high_risk_file = tmp_path / "high_risk.txt"
   contact_file = tmp_path / "contact.csv"

   # only these two need to exist for ModelParameters.__init__
   high_risk_file.write_text("0.0\n0.0\n")
   contact_file.write_text("1,0\n0,1\n")   # 2x2 identity matrix

   return SimpleNamespace(
      disease_model="seaitrd-stochastic",
      disease_parameters={
         "compartments": ["S", "E", "A", "I", "T", "R", "D"],
         "R0": "1.0",
         "beta_scale": "1.0",
         "E_to_A_days": "4.0",
         "A_to_I_days": "4.0",
         "I_to_R_days": "4.0",
         "T_to_R_days": "2.0",
         "T_to_I_days": "4.0",
         "I_to_D_invdays": ["0.25", "0.25"],
         "sigma": ["1.0", "1.0"],
      },
      travel_model="binomial",
      travel_parameters={
         "rho": "0.0",
         "flow_reduction": ["0.0", "0.0"],
         "traveling_compartments": {"A": "1.0"},
         "transmitting_compartments": {"A": "1.0", "T": "1.0", "I": "1.0"},
      },
      non_pharma_interventions=[
         {
            "name": "School Closure",
            "day": "0",
            "duration": "2",
            "location": "113,141,201",
            "effectiveness": ["0.9", "0.0"],
         }
      ],
      antiviral_parameters={},
      vaccine_parameters={},
      high_risk_ratios_file=str(high_risk_file),
      contact_data_file=str(contact_file),
   )


def make_params(tmp_path):
   dummy_input = make_dummy_input(tmp_path)
   params = ModelParameters(dummy_input)
   return params


def make_network():
   compartment_labels = ["S", "E", "A", "I", "T", "R", "D"]
   net = Network(compartment_labels)
   node = Node(
      node_index=0,
      node_id=101,
      fips_id=101,
      compartments=PopulationCompartments([10, 30], [0.0, 0.0]),
   )
   net._add_node(node)
   return net


def test_node_specific_npi_effect(tmp_path):
   params = make_params(tmp_path)
   params.beta = 1.0

   compartment_labels = ["S", "E", "A", "I", "T", "R", "D"]
   network = Network(compartment_labels)

   fips_ids = [113, 141, 201, 300, 400]
   for idx, fips in enumerate(fips_ids):
      pc = PopulationCompartments([10, 10], [0.0, 0.0])
      node = Node(node_index=idx, node_id=fips, fips_id=fips, compartments=pc)
      network._add_node(node)

   npi = NonPharmaInterventions(params.non_pharma_interventions, 10, len(fips_ids), 2)
   npi.pre_process(network)

   model = DiseaseModel(params, npi, now=0.0)
   model.beta = params.beta

   beta_baseline = model.beta
   beta_expected = [
      beta_baseline * (1.0 - 0.9),
      beta_baseline * (1.0 - 0.0),
   ]

   affected_node_ids = {113, 141, 201}
   for day in range(0, 5):
      model.now = day
      for node in network.nodes:
         beta_result = model._calculate_beta_w_npi(node.node_index, node.node_id)

         if node.node_id in affected_node_ids and day <= 2:
            assert np.allclose(beta_result, beta_expected, atol=1e-8)
         else:
            assert np.allclose(beta_result, [beta_baseline] * 2, atol=1e-8)


def test_rng_raises_before_set_seed(tmp_path):
   params = make_params(tmp_path)
   npis = SimpleNamespace(schedule=[[[0.0, 0.0]]])
   model = DiseaseModel(params, npis, now=0.0)

   with pytest.raises(RuntimeError, match="RNG not set"):
      _ = model.rng


def test_set_seed_is_reproducible(tmp_path):
   params = make_params(tmp_path)
   npis = SimpleNamespace(schedule=[[[0.0, 0.0]]])

   model1 = DiseaseModel(params, npis, now=0.0)
   model2 = DiseaseModel(params, npis, now=0.0)

   rng1 = model1.set_seed(SeedSequence(123))
   rng2 = model2.set_seed(SeedSequence(123))

   assert np.allclose(rng1.random(5), rng2.random(5))


def test_spectral_radius_returns_largest_eigenvalue():
   K = np.diag([1.0, 3.5, 2.0])
   assert DiseaseModel.spectral_radius(K) == 3.5


def test_estimate_baseline_beta_matches_target_R0():
   contact_matrix = np.array([[3.0, 1.0], [1.0, 2.0]])
   susceptibility = np.array([1.0, 0.5])
   w = np.array([4.0, 2.0])
   R0 = 2.5

   beta = DiseaseModel.estimate_baseline_beta(
      contact_matrix,
      R0,
      w,
      susceptibility,
   )
   K = DiseaseModel.build_NGM(beta, contact_matrix, w, susceptibility)

   assert np.isclose(DiseaseModel.spectral_radius(K), R0)


def test_adjust_two_way_split_proportion_realizes_desired_fraction():
   target_rate = 1 / 3.0
   competing_rate = 1 / 7.0
   desired = 0.25

   adjusted = DiseaseModel.adjust_two_way_split_proportion(
      desired_realized_fraction=desired,
      competing_rate=competing_rate,
      target_rate=target_rate,
   )

   realized = adjusted * target_rate / (
      adjusted * target_rate + (1 - adjusted) * competing_rate
   )
   assert np.isclose(realized, desired)


def test_adjust_competing_clock_split_proportions_realizes_desired_fractions():
   desired = [0.2, 0.3, 0.5]
   rates = [1 / 2.0, 1 / 4.0, 1 / 9.0]

   adjusted = DiseaseModel.adjust_competing_clock_split_proportions(
      desired_realized_fractions=desired,
      rates=rates,
   )

   realized_rates = np.array(adjusted) * np.array(rates)
   realized = realized_rates / realized_rates.sum()

   assert np.isclose(sum(adjusted), 1.0)
   assert np.allclose(realized, desired)


def test_group_cache_per_node_sums_to_one(tmp_path):
   params = make_params(tmp_path)
   npis = SimpleNamespace(schedule=[[[0.0, 0.0]]])
   model = DiseaseModel(params, npis, now=0.0)

   net = make_network()
   model._group_cache_per_node(net)

   cache = net.nodes[0].group_cache
   assert cache.shape == (2, 2, 2)
   assert np.isclose(cache.sum(), 1.0)


def test_demographic_sizes_match_population_split(tmp_path):
   params = make_params(tmp_path)
   npis = SimpleNamespace(schedule=[[[0.0, 0.0]]])
   model = DiseaseModel(params, npis, now=0.0)

   net = make_network()
   node = net.nodes[0]
   cache = np.zeros((2, 2, 2))

   out = model._demographic_sizes(node, cache)

   # all starting population is low-risk unvaccinated
   assert np.isclose(out[0, 0, 0], 10 / 40)
   assert np.isclose(out[1, 0, 0], 30 / 40)
   assert np.isclose(out[0, 0, 1], 0.0)
   assert np.isclose(out[1, 0, 1], 0.0)


def test_get_child_raises_on_unknown_model(tmp_path):
   params = make_params(tmp_path)
   npis = SimpleNamespace(schedule=[[[0.0, 0.0]]])
   model = DiseaseModel(params, npis, now=0.0)

   with pytest.raises(Exception, match="not recognized"):
      model.get_child("not-a-real-model")


def test_age_values_expands_scalar_to_age_groups():
   assert DiseaseModel.age_values("0.5", 3) == [0.5, 0.5, 0.5]


def test_age_values_accepts_age_specific_sequence():
   assert DiseaseModel.age_values(["0.1", 0.2, "0.3"], 3) == [0.1, 0.2, 0.3]


def test_age_values_rejects_wrong_length_sequence():
   with pytest.raises(ValueError, match="Expected 3 age-specific values"):
      DiseaseModel.age_values(["0.1", "0.2"], 3)
