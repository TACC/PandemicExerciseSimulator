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


