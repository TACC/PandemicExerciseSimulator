#!/usr/bin/env python3
from collections.abc import MutableMapping
from copy import deepcopy


class TrackingDict(MutableMapping):
   def __init__(self, data=None):
      self._data = {}
      self._used_keys = set()

      if data is None:
         data = {}

      if not isinstance(data, dict):
         raise TypeError(f"TrackingDict expected dict, got {type(data).__name__}")

      for k, v in data.items():
         self._data[k] = self._wrap_value(v)

   def _wrap_value(self, value):
      if isinstance(value, dict):
         return TrackingDict(value)
      if isinstance(value, list):
         return [self._wrap_value(x) for x in value]
      return value

   def __getitem__(self, key):
      self._used_keys.add(key)
      return self._data[key]

   def get(self, key, default=None):
      if key in self._data:
         self._used_keys.add(key)
      return self._data.get(key, default)

   def __setitem__(self, key, value):
      self._data[key] = self._wrap_value(value)

   def __delitem__(self, key):
      del self._data[key]

   def __iter__(self):
      for k in self._data:
         self._used_keys.add(k)
      return iter(self._data)

   def __len__(self):
      return len(self._data)

   def items(self):
      for k in self._data:
         self._used_keys.add(k)
      return self._data.items()

   def keys(self):
      for k in self._data:
         self._used_keys.add(k)
      return self._data.keys()

   def values(self):
      for k in self._data:
         self._used_keys.add(k)
      return self._data.values()

   def _extract_used(self, value):
      if isinstance(value, TrackingDict):
         used_nested = value.used_only()
         if used_nested:
            return used_nested
         return value.all_data()

      if isinstance(value, list):
         return [self._extract_used(x) for x in value]

      return deepcopy(value)

   def used_only(self):
      out = {}
      for key in self._used_keys:
         val = self._data[key]
         used_val = self._extract_used(val)
         if used_val not in ({}, [], None):
            out[key] = used_val
      return out

   def _extract_all(self, value):
      if isinstance(value, TrackingDict):
         return value.all_data()
      if isinstance(value, list):
         return [self._extract_all(x) for x in value]
      return deepcopy(value)

   def all_data(self):
      out = {}
      for key, val in self._data.items():
         out[key] = self._extract_all(val)
      return out