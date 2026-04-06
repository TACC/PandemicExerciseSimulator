import pytest
from types import SimpleNamespace
from src.baseclasses.TrackingDict import TrackingDict
from src.utils.config_export import (
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

def test_generate_scenario_hash_stable():
   payload = {"a": 1, "b": 2}
   assert generate_scenario_hash(payload) == generate_scenario_hash({"b": 2, "a": 1})


