import pytest
from src.baseclasses.TrackingDict import TrackingDict

def test_init_requires_dict():
   with pytest.raises(TypeError):
      TrackingDict(["not", "a", "dict"])

def test_nested_dicts_are_wrapped():
   td = TrackingDict({"a": {"b": 1}, "c": [ {"d": 2} ]})
   assert isinstance(td["a"], TrackingDict)
   assert isinstance(td["c"][0], TrackingDict)

def test_getitem_marks_key_as_used():
   td = TrackingDict({"a": 1, "b": 2})
   _ = td["a"]
   assert td.used_only() == {"a": 1}

def test_get_marks_key_as_used_only_if_present():
   td = TrackingDict({"a": 1})
   assert td.get("a") == 1
   assert td.used_only() == {"a": 1}

   td2 = TrackingDict({"a": 1})
   assert td2.get("missing") is None
   assert td2.used_only() == {}

def test_used_only_nested_partial_access():
   td = TrackingDict({"outer": {"x": 1, "y": 2}})
   assert td["outer"]["x"] == 1
   assert td.used_only() == {"outer": {"x": 1}}

def test_used_only_nested_parent_access_only_returns_all_nested_data():
   td = TrackingDict({"outer": {"x": 1, "y": 2}})
   _ = td["outer"]
   assert td.used_only() == {"outer": {"x": 1, "y": 2}}

def test_all_data_returns_full_plain_dict():
   td = TrackingDict({"a": {"b": 1}, "c": [ {"d": 2} ]})
   assert td.all_data() == {"a": {"b": 1}, "c": [{"d": 2}]}

def test_setitem_wraps_new_nested_dict():
   td = TrackingDict()
   td["a"] = {"b": 1}
   assert isinstance(td["a"], TrackingDict)

def test_iter_marks_all_keys_used():
   td = TrackingDict({"a": 1, "b": 2})
   list(td)
   assert td.used_only() == {"a": 1, "b": 2}

def test_items_marks_all_keys_used():
   td = TrackingDict({"a": 1, "b": 2})
   td.items()
   assert td.used_only() == {"a": 1, "b": 2}


