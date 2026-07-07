import pytest
from types import SimpleNamespace
from src.baseclasses.TrackingDict import TrackingDict
from src.utils.ConfigExport import (
   normalize_data_path, normalize_float, normalize_for_json,
   export_public_state, canonicalize_for_hash, generate_scenario_hash
)


def test_normalize_data_path_equivalent():
   a = "../data/New-York/file.csv"
   b = "data/New-York/file.csv"
   assert normalize_data_path(a) == normalize_data_path(b) == "data/New-York/file.csv"


def test_normalize_float_rounding():
   assert normalize_float(1.234567891, places=8) == 1.23456789


def test_normalize_for_json_trackingdict():
   td = TrackingDict({"a": {"b": 1}})
   assert normalize_for_json(td) == {"a": {"b": 1}}


def test_export_public_state_excludes_private_and_excluded():
   obj = SimpleNamespace(
      public=1,
      _private=2,
      logger="secret",
      nested=TrackingDict({"a": 1})
   )
   out = export_public_state(obj, exclude={"logger"})
   assert out == {"public": 1, "nested": {"a": 1}}


def test_canonicalize_for_hash_sorts_keys_and_rounds():
   payload1 = {"b": 2.0, "a": 1.123456789}
   payload2 = {"a": 1.123456789, "b": 2.0}
   assert canonicalize_for_hash(payload1) == canonicalize_for_hash(payload2)


def test_canonicalize_for_hash_list():
   from src.utils.ConfigExport import canonicalize_for_hash

   out = canonicalize_for_hash([1, 2.0, True, {"a": 3}])

   assert out == [1.0, 2.0, True, {"a": 3.0}]


def test_age_risk_priority_numeric_forms_hash_the_same():
   string_runtime_state = {"age_risk_priority_groups": [float(x) for x in ["0", "0.5", "1"]]}
   numeric_runtime_state = {"age_risk_priority_groups": [0, 0.5, 1.0]}

   string_hash = generate_scenario_hash(canonicalize_for_hash(string_runtime_state))
   numeric_hash = generate_scenario_hash(canonicalize_for_hash(numeric_runtime_state))

   assert string_hash == numeric_hash


def test_generate_scenario_hash_stable():
   payload = {"a": 1.0, "b": 2.0}
   assert generate_scenario_hash(canonicalize_for_hash(payload)) == generate_scenario_hash(canonicalize_for_hash({"b": 2, "a": 1}))


def test_bool_identity_not_just_value():
   payload = {"flag": True}
   out = canonicalize_for_hash(payload)

   assert out["flag"] is True  # not just == True


def test_canonicalize_preserves_bool_type():
   payload = {"flag": True, "other": False}
   out = canonicalize_for_hash(payload)

   assert isinstance(out["flag"], bool)
   assert isinstance(out["other"], bool)
   assert out["flag"] is True
   assert out["other"] is False


def test_bool_not_equal_to_int_in_hash():
   payload_bool = {"a": True}
   payload_int  = {"a": 1}

   hash_bool = generate_scenario_hash(canonicalize_for_hash(payload_bool))
   hash_int  = generate_scenario_hash(canonicalize_for_hash(payload_int))

   assert hash_bool != hash_int


def test_hash_stable_with_bool_and_order():
   payload1 = {"a": True, "b": 2.0}
   payload2 = {"b": 2, "a": True}

   h1 = generate_scenario_hash(canonicalize_for_hash(payload1))
   h2 = generate_scenario_hash(canonicalize_for_hash(payload2))

   assert h1 == h2


def test_nested_bool_preserved():
   payload = {"outer": {"flag": True, "val": 1}}
   out = canonicalize_for_hash(payload)

   assert isinstance(out["outer"]["flag"], bool)
   assert out["outer"]["flag"] is True
   assert isinstance(out["outer"]["val"], float)


def test_get_git_info(monkeypatch):
   from src.utils.ConfigExport import get_git_info
   import subprocess

   outputs = {
      ("git", "rev-parse", "HEAD"): b"abc123\n",
      ("git", "rev-parse", "--abbrev-ref", "HEAD"): b"main\n",
      ("git", "status", "--porcelain"): b"",
   }

   def fake_check_output(cmd, stderr=None):
      return outputs[tuple(cmd)]

   monkeypatch.setattr(subprocess, "check_output", fake_check_output)

   out = get_git_info()
   assert out == {
      "git_commit": "abc123",
      "git_branch": "main",
      "git_dirty": False,
   }


def test_get_git_info_failure(monkeypatch):
   from src.utils.ConfigExport import get_git_info
   import subprocess

   def fake_check_output(cmd, stderr=None):
      raise subprocess.CalledProcessError(1, cmd)

   monkeypatch.setattr(subprocess, "check_output", fake_check_output)

   out = get_git_info()
   assert out == {
      "git_commit": None,
      "git_branch": None,
      "git_dirty": None,
   }

def test_extract_geo_name():
   from src.utils.ConfigExport import extract_geo_name

   assert extract_geo_name("../data/New-York/file.csv") == "New-York"
   assert extract_geo_name("file.csv") == "Unknown-Geo"


def test_extract_geo_level():
   from src.utils.ConfigExport import extract_geo_level

   assert extract_geo_level("county_pop_by_age_TX.csv") == "county"
   assert extract_geo_level("weird_name.csv") == "Unknown-Geo-Sublevel"


def test_extract_age_labels(tmp_path):
   from src.utils.ConfigExport import extract_age_labels

   f = tmp_path / "pop.csv"
   f.write_text("county,0-4,5-17,18+\n001,10,20,30\n")

   assert extract_age_labels(str(f)) == ["0-4", "5-17", "18+"]


def test_build_hash_payload():
   from src.utils.ConfigExport import build_hash_payload

   sim = SimpleNamespace(
      population_data_file="../data/Texas/pop.csv",
      contact_data_file="../data/Texas/contact.csv",
      flow_data_file="../data/Texas/flow.csv",
      high_risk_ratios_file="../data/Texas/risk.csv",
      disease_model="seaitrd-stochastic",
      travel_model="binomial",
      vaccine_model=None,
      antiviral_model=None,
      initial=[],
      non_pharma_interventions=[],
   )

   disease_model = SimpleNamespace(public_attr=1, _private=2)
   travel_model = SimpleNamespace(scale=2.0)

   out = build_hash_payload(
      simulation_properties=sim,
      disease_model=disease_model,
      travel_model=travel_model,
      vaccine_model=None,
      antiviral_model=None,
   )

   assert out["data"]["population"] == "data/Texas/pop.csv"
   assert out["disease_model"]["identity"] == "seaitrd-stochastic"
   assert out["travel_model"]["identity"] == "binomial"
   assert out["disease_model"]["runtime_attributes"] == {"public_attr": 1.0}
   assert out["vaccine_model"]["runtime_attributes"] == {}


def test_build_executed_config(tmp_path, monkeypatch):
   from src.utils.ConfigExport import build_executed_config
   from src.baseclasses.TrackingDict import TrackingDict

   pop_file = tmp_path / "county_pop_by_age_TX.csv"
   pop_file.write_text("county,0-4,5-17\n001,10,20\n")

   sim = SimpleNamespace(
      realization_indices=[0, 1, 2],
      population_data_file=str(pop_file),
      contact_data_file="contact.csv",
      flow_data_file="flow.csv",
      high_risk_ratios_file="risk.csv",
      output_dir_path="orig_out",
      batch_num="123",
      disease_model="seaitrd-stochastic",
      travel_model="binomial",
      vaccine_model=None,
      antiviral_model=None,
      initial=[{"county": "001", "infected": "1", "age_group": "0"}],
      non_pharma_interventions=[{
         "name": "school",
         "day": "0",
         "duration": "7",
         "location": "0",
         "effectiveness": ["0.5", "0.25"],
      }],
      tags={},
   )

   disease_params = TrackingDict({"R0": "3", "tau": "7"})
   _ = disease_params["R0"]   # mark used

   travel_params = TrackingDict({"rho": "1"})
   _ = travel_params["rho"]

   npi = TrackingDict({
      "name": "school",
      "day": "0",
      "duration": "7",
      "location": "0",
      "effectiveness": ["0.5", "0.25"],
   })
   _ = npi["name"]

   params = SimpleNamespace(
      disease_parameters=disease_params,
      travel_parameters=travel_params,
      antiviral_parameters=TrackingDict({}),
      vaccine_parameters=TrackingDict({}),
      non_pharma_interventions=[npi],
      number_of_age_groups=2,
   )

   disease_model = SimpleNamespace(foo=1)
   travel_model = SimpleNamespace(bar=2)
   npi_model = SimpleNamespace(
      npis=[npi],
      length=31,
      num_locations=5,
      num_age_groups=2,
   )

   monkeypatch.setattr(
      "src.utils.ConfigExport.get_git_info",
      lambda: {"git_commit": "abc", "git_branch": "main", "git_dirty": False},
   )

   cli_args = SimpleNamespace(
      days=30,
      loglevel="INFO",
      input_filename="input.json"
   )

   monkeypatch.setattr(
      "src.utils.ConfigExport.get_git_info",
      lambda: {"git_commit": "abc", "git_branch": "main", "git_dirty": False},
   )

   out = build_executed_config(
      simulation_properties=sim,
      parameters=params,
      disease_model=disease_model,
      travel_model=travel_model,
      npi_model=npi_model,
      vaccine_model=None,
      antiviral_model=None,
      node_count=5,
      base_seed=123,
      cli_args=cli_args,
   )

   assert out["batch_num"] == "123"
   assert out["realization_indices"] == {"min": 0, "max": 2, "count": 3}
   assert out["geo"]["region"] == "Unknown-Geo"
   assert out["geo"]["level"] == "county"
   assert out["geo"]["node_count"] == 5
   assert out["age_structure"]["num_groups"] == 2
   assert out["age_structure"]["labels"] == ["0-4", "5-17"]
   assert out["disease_model"]["parameters"] == {"R0": "3"}
   assert out["travel_model"]["parameters"] == {"rho": "1"}
   assert out["non_pharma_interventions"]["parameters"] == [{
      "name": "school",
      "day": "0",
      "duration": "7",
      "location": "0",
      "effectiveness": ["0.5", "0.25"],
   }]
   assert out["non_pharma_interventions"]["runtime_attributes"] == {
      "length": 31,
      "num_locations": 5,
      "num_age_groups": 2,
      "npis": [{
         "day": 0.0,
         "duration": 7.0,
         "location": "0",
         "effectiveness": [0.5, 0.25],
      }],
   }
   assert out["git_info"]["git_commit"] == "abc"
   assert out["random_seed"]["base_seed"] == 123
   assert out["cli_args"] == {
      "days": 30,
      "loglevel": "INFO",
      "input_filename": "input.json",
   }


def test_write_metadata_json(tmp_path):
   from src.utils.ConfigExport import write_metadata_json
   import json

   payload = {"a": 1, "b": "x"}
   write_metadata_json(payload, tmp_path, "123")

   out_file = tmp_path / "metadata_batch-123.json"
   assert out_file.exists()

   with open(out_file) as f:
      data = json.load(f)

   assert data == payload


def test_write_metadata_json_logs(tmp_path):
   from src.utils.ConfigExport import write_metadata_json

   class DummyLogger:
      def __init__(self):
         self.messages = []

      def info(self, msg):
         self.messages.append(msg)

   logger = DummyLogger()
   payload = {"a": 1}

   write_metadata_json(payload, tmp_path, "1", logger=logger)

   assert len(logger.messages) == 1
   assert "metadata_batch-1.json" in logger.messages[0]


def test_is_jsonable_false_for_non_jsonable_object():
   from src.utils.ConfigExport import is_jsonable

   class NotJsonable:
      pass

   assert is_jsonable(NotJsonable()) is False


def test_normalize_for_json_list():
   from src.utils.ConfigExport import normalize_for_json

   assert normalize_for_json([1, {"a": 2}]) == [1, {"a": 2}]


def test_normalize_for_json_dict():
   from src.utils.ConfigExport import normalize_for_json

   assert normalize_for_json({"x": [1, 2], "y": {"z": 3}}) == {"x": [1, 2], "y": {"z": 3}}

def test_export_public_state_none_returns_empty_dict():
   from src.utils.ConfigExport import export_public_state

   assert export_public_state(None) == {}


def test_export_public_state_plain_dict_with_default_exclude():
   from src.utils.ConfigExport import export_public_state

   assert export_public_state({"a": 1}) == {"a": 1}


def test_export_public_state_plain_list():
   from src.utils.ConfigExport import export_public_state

   assert export_public_state([1, 2, 3]) == [1, 2, 3]


def test_export_public_state_object_without_dict():
   from src.utils.ConfigExport import export_public_state

   assert export_public_state(5) == 5


def test_export_public_state_tuple_without_dict():
   from src.utils.ConfigExport import export_public_state

   out = export_public_state((1, 2))
   assert out == (1, 2)
