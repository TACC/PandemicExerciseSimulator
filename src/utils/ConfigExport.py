#!/usr/bin/env python3
import hashlib
import json
import csv
import subprocess
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

from baseclasses.TrackingDict import TrackingDict

HASH_FLOAT_PLACES = 8
EXPORT_EXCLUDE = {"parameters", "logger", "random_state", "rng"}


def get_git_info():
   def run(cmd):
      return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()

   try:
      commit = run(["git", "rev-parse", "HEAD"])
      branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])

      status = run(["git", "status", "--porcelain"])
      dirty = len(status) > 0

      return {
         "git_commit": commit,
         "git_branch": branch,
         "git_dirty": dirty
      }

   except Exception:
      return {
         "git_commit": None,
         "git_branch": None,
         "git_dirty": None
      }


def extract_geo_name(path: str) -> str:
   parts = Path(path).parts
   if "data" in parts:
      idx = parts.index("data")
      if idx + 1 < len(parts):
         return parts[idx + 1]
   return "Unknown-Geo"


def extract_geo_level(pop_file: str) -> str:
   name = Path(pop_file).stem  # remove .csv

   if "_pop_by_age" in name:
      return name.split("_pop_by_age")[0]

   return "Unknown-Geo-Sublevel"


def extract_age_labels(pop_file: str):
   with open(pop_file, "r") as f:
      reader = csv.reader(f)
      header = next(reader)

   return header[1:]


def normalize_data_path(path: str) -> str:
   """
   Normalize paths so:
      ../data/New-York/file.csv
      data/New-York/file.csv
   hash the same.
   """
   parts = Path(path).parts

   if "data" in parts:
      idx = parts.index("data")
      return "/".join(parts[idx:])

   return Path(path).name


def normalize_float(x: float, places: int = HASH_FLOAT_PLACES) -> float:
   q = Decimal("1." + ("0" * places))
   return float(Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP))


def is_jsonable(x) -> bool:
   try:
      json.dumps(x)
      return True
   except (TypeError, OverflowError):
      return False


def normalize_for_json(value):
   """
   Convert TrackingDict and nested values into plain JSON-safe Python types.
   """
   if hasattr(value, "all_data") and callable(value.all_data):
      return value.all_data()

   if isinstance(value, list):
      return [normalize_for_json(x) for x in value]

   if isinstance(value, dict):
      return {k: normalize_for_json(v) for k, v in value.items()}

   return deepcopy(value)


def export_public_state(obj, exclude=None):
   """
   Export public runtime attributes from a model object.
   """
   if exclude is None:
      exclude = set()

   if obj is None:
      return {}

   if isinstance(obj, (list, dict, str, int, float, bool)):
      normalized = normalize_for_json(obj)
      return normalized if is_jsonable(normalized) else {}

   if not hasattr(obj, "__dict__"):
      normalized = normalize_for_json(obj)
      return normalized if is_jsonable(normalized) else {}

   out = {}
   for k, v in obj.__dict__.items():
      if k.startswith("_"):
         continue
      if k in exclude:
         continue

      normalized = normalize_for_json(v)

      if is_jsonable(normalized):
         out[k] = normalized

   return out


def canonicalize_for_hash(value, float_places: int = HASH_FLOAT_PLACES):
   """
   Recursively normalize values so semantically equivalent scenarios hash the same.
   e.g. R0=2 to 2.0 when values aren't bools
   """
   if isinstance(value, bool):
      return value

   if isinstance(value, (int, float)):
      return normalize_float(float(value), places=float_places)

   if isinstance(value, dict):
      return {
         str(k): canonicalize_for_hash(v, float_places=float_places)
         for k, v in sorted(value.items())
      }

   if isinstance(value, list):
      return [canonicalize_for_hash(v, float_places=float_places) for v in value]

   return value


def canonicalize_initial_infected_for_hash(initial_infected):
   rows = normalize_for_json(initial_infected or [])

   out = []
   for row in rows:
      out.append({
         "county": str(row.get("county", "")),
         "infected": float(row.get("infected", 0)),
         "age_group": int(row.get("age_group", 0))
      })

   return sorted(
      out,
      key=lambda x: (
         x["county"],
         x["age_group"],
         x["infected"]
      )
   )


def canonicalize_npis_for_hash(npis):
   '''
   Excluding "name" from hash as it's irrelevant to what the intervention does
   The name is more a note of the user than a hard rule used to look up a pattern
   '''
   rows = normalize_for_json(npis or [])

   out = []
   for row in rows:
      out.append({
         #"name": str(row.get("name", "")),
         "day": int(row.get("day", 0)),
         "duration": int(row.get("duration", 0)),
         "location": str(row.get("location", "")),
         "effectiveness": [float(x) for x in row.get("effectiveness", [])]
      })

   return sorted(
      out,
      key=lambda x: (
         x["day"],
         #x["name"],
         x["duration"],
         x["location"],
         tuple(x["effectiveness"])
      )
   )


def build_hash_payload(simulation_properties,
                       disease_model,
                       travel_model,
                       antiviral_model,
                       vaccine_model):
   payload = {
      "data": {
         "population": normalize_data_path(simulation_properties.population_data_file),
         "contact": normalize_data_path(simulation_properties.contact_data_file),
         "flow": normalize_data_path(simulation_properties.flow_data_file),
         "high_risk_ratios": normalize_data_path(simulation_properties.high_risk_ratios_file),
      },
      "disease_model": {
         "identity": simulation_properties.disease_model,
         "runtime_attributes": export_public_state(
            disease_model,
            exclude=EXPORT_EXCLUDE
         )
      },
      "travel_model": {
         "identity": simulation_properties.travel_model,
         "runtime_attributes": export_public_state(
            travel_model,
            exclude=EXPORT_EXCLUDE
         )
      },
      "initial_infected": canonicalize_initial_infected_for_hash(
         simulation_properties.initial
      ),
      "non_pharma_interventions": canonicalize_npis_for_hash(
         simulation_properties.non_pharma_interventions
      ),
      "vaccine_model": {
         "identity": simulation_properties.vaccine_model,
         "runtime_attributes": export_public_state(
            vaccine_model,
            exclude=EXPORT_EXCLUDE
         ) if vaccine_model is not None else {}
      },
      "antiviral_model": {
         "identity": simulation_properties.antiviral_model,
         "runtime_attributes": export_public_state(
            antiviral_model,
            exclude=EXPORT_EXCLUDE
         ) if antiviral_model is not None else {}
      }
   }

   return canonicalize_for_hash(payload, float_places=HASH_FLOAT_PLACES)


def generate_scenario_hash(payload: dict) -> str:
   """
   Return full SHA-256 hex digest.
   """
   canonical_json = json.dumps(payload, sort_keys=True, separators=(",", ":"))
   return hashlib.sha256(canonical_json.encode("utf-8")).hexdigest()


def build_executed_config(simulation_properties,
                          parameters,
                          disease_model,
                          travel_model,
                          npi_model,
                          antiviral_model,
                          vaccine_model,
                          node_count,
                          base_seed,
                          cli_args=None):
   indices = simulation_properties.realization_indices

   hash_payload = build_hash_payload(
      simulation_properties=simulation_properties,
      disease_model=disease_model,
      travel_model=travel_model,
      antiviral_model=antiviral_model,
      vaccine_model=vaccine_model
   )

   scenario_hash = generate_scenario_hash(hash_payload)
   geo_name = extract_geo_name(simulation_properties.population_data_file)
   output_dir_path = f"{geo_name}_{scenario_hash}"

   out = {
      "created_at_utc": datetime.now(timezone.utc).isoformat(),
      "scenario_hash": scenario_hash,
      "output_dir_path": output_dir_path,
      "orig_output_dir_path": simulation_properties.output_dir_path,
      "metadata_tags": simulation_properties.tags,
      "realization_indices": {
         "min": min(indices),
         "max": max(indices),
         "count": len(indices)
      } if indices else {},
      "batch_num": simulation_properties.batch_num,
      "data": {
         "population": simulation_properties.population_data_file,
         "contact": simulation_properties.contact_data_file,
         "flow": simulation_properties.flow_data_file,
         "high_risk_ratios": simulation_properties.high_risk_ratios_file
      },
      "disease_model": {
         "identity": simulation_properties.disease_model,
         "parameters": parameters.disease_parameters.used_only(),
         "runtime_attributes": export_public_state(
            disease_model,
            exclude=EXPORT_EXCLUDE
         )
      },
      "travel_model": {
         "identity": simulation_properties.travel_model,
         "parameters": parameters.travel_parameters.used_only(),
         "runtime_attributes": export_public_state(
            travel_model,
            exclude=EXPORT_EXCLUDE
         )
      },
      "initial_infected": canonicalize_initial_infected_for_hash(simulation_properties.initial),
      "non_pharma_interventions": {
         "parameters": normalize_for_json(simulation_properties.non_pharma_interventions),
         "runtime_attributes": (
            { # gives the network details passed to NPIs
            **export_public_state(
               npi_model,
               exclude=EXPORT_EXCLUDE | {"schedule", "npis"}
            ), # gives the sorted schedule used in the hash for visual validation
              "npis": canonicalize_npis_for_hash(npi_model.npis)
            } if npi_model is not None else {}
         )
      },
      "antiviral_model": {
         "identity": simulation_properties.antiviral_model,
         "parameters": parameters.antiviral_parameters.used_only(),
         "runtime_attributes": export_public_state(
            antiviral_model,
            exclude=EXPORT_EXCLUDE
         ) if antiviral_model is not None else {}
      },
      "vaccine_model": {
         "identity": simulation_properties.vaccine_model,
         "parameters": parameters.vaccine_parameters.used_only(),
         "runtime_attributes": export_public_state(
            vaccine_model,
            exclude=EXPORT_EXCLUDE
         ) if vaccine_model is not None else {}
      }
   }

   if cli_args is not None:
      out["cli_args"] = {
         "days": cli_args.days,
         "loglevel": cli_args.loglevel,
         "input_filename": cli_args.input_filename,
      }

   out["geo"] = {
      "region": extract_geo_name(simulation_properties.population_data_file),
      "level": extract_geo_level(simulation_properties.population_data_file),
      "node_count": node_count
   }

   out["age_structure"] = {
      "num_groups": parameters.number_of_age_groups,
      "labels": extract_age_labels(simulation_properties.population_data_file)
   }

   out["git_info"] = get_git_info()

   out["random_seed"] = {
      "base_seed": base_seed,
      "seed_strategy": "numpy.SeedSequence.spawn",
      "seed_width_bits": 128
   }

   return out


def write_metadata_json(executed_config, output_dir, batch_num, logger=None):
   out_path = Path(output_dir) / f"metadata_batch-{batch_num}.json"

   with open(out_path, "w") as f:
      json.dump(executed_config, f, indent=3)

   if logger is not None:
      logger.info(f"Wrote metadata file to: {out_path}")