import json
import pytest

from src.baseclasses.InputProperties import InputProperties

# This file is no longer a valid input format
# Probably best to make a 1 of everything test per model
FILENAME = './test/data/texas/INPUT.json'
#IP = InputProperties(FILENAME)

with open(FILENAME, 'r') as f:
    DATA = json.load(f)

# We'll need new tests since there are many different types of inputs
def test_fileinputs():
    pass

@pytest.fixture
def valid_config(tmp_path):
   # Create fake files
   data_dir = tmp_path / "data"
   data_dir.mkdir()

   pop = data_dir / "pop.csv"
   contact = data_dir / "contact.csv"
   flow = data_dir / "flow.csv"
   risk = data_dir / "risk.csv"

   for f in [pop, contact, flow, risk]:
      f.write_text("dummy")

   output_dir = tmp_path / "out"
   output_dir.mkdir()

   config = {
      "output_dir_path": str(output_dir),
      "batch_num": "GENERATE",
      "number_of_realizations": 5,
      "data": {
         "population": str(pop),
         "contact": str(contact),
         "flow": str(flow),
         "high_risk_ratios": str(risk)
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 10
   }

   config_path = tmp_path / "config.json"
   config_path.write_text(json.dumps(config))

   return config_path

def test_batch_num_generate(valid_config):
   ip = InputProperties(str(valid_config))

   # UUIDv7 = string + length ~36
   assert isinstance(ip.batch_num, str)
   assert len(ip.batch_num) >= 30

def test_batch_num_is_unique(valid_config):
   ip1 = InputProperties(str(valid_config))
   ip2 = InputProperties(str(valid_config))

   assert ip1.batch_num != ip2.batch_num

def test_batch_num_preserved(tmp_path):
   config = {
      "output_dir_path": str(tmp_path),
      "batch_num": "my-batch-123",
      "number_of_realizations": 2,
      "data": {
         "population": __file__,
         "contact": __file__,
         "flow": __file__,
         "high_risk_ratios": __file__
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 1
   }

   path = tmp_path / "config.json"
   path.write_text(json.dumps(config))

   ip = InputProperties(str(path))
   assert ip.batch_num == "my-batch-123"

def test_number_of_realizations(valid_config):
   ip = InputProperties(str(valid_config))

   assert ip.realization_start == 0
   assert ip.realization_end == 4
   assert ip.realization_indices == [0,1,2,3,4]

def test_realization_range(tmp_path):
   config = {
      "output_dir_path": str(tmp_path),
      "batch_num": "abc",
      "realization_range": [2, 4],
      "data": {
         "population": __file__,
         "contact": __file__,
         "flow": __file__,
         "high_risk_ratios": __file__
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 1
   }

   path = tmp_path / "config.json"
   path.write_text(json.dumps(config))

   ip = InputProperties(str(path))

   assert ip.realization_indices == [2,3,4]

def test_invalid_realization_range(tmp_path):
   config = {
      "output_dir_path": str(tmp_path),
      "batch_num": "abc",
      "realization_range": [5, 2],  # invalid
      "data": {
         "population": __file__,
         "contact": __file__,
         "flow": __file__,
         "high_risk_ratios": __file__
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 1
   }

   path = tmp_path / "config.json"
   path.write_text(json.dumps(config))

   with pytest.raises(ValueError):
      InputProperties(str(path))

def test_missing_realization_fields(tmp_path):
   config = {
      "output_dir_path": str(tmp_path),
      "batch_num": "abc",
      "data": {
         "population": __file__,
         "contact": __file__,
         "flow": __file__,
         "high_risk_ratios": __file__
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 1
   }

   path = tmp_path / "config.json"
   path.write_text(json.dumps(config))

   with pytest.raises(ValueError):
      InputProperties(str(path))

def test_invalid_output_dir(tmp_path):
   config = {
      "output_dir_path": str(tmp_path / "does_not_exist"),
      "batch_num": "abc",
      "number_of_realizations": 1,
      "data": {
         "population": __file__,
         "contact": __file__,
         "flow": __file__,
         "high_risk_ratios": __file__
      },
      "disease_model": {"identity": "SEIR", "parameters": {}},
      "travel_model": {"identity": "binomial", "parameters": {}},
      "initial_exposed": 1
   }

   path = tmp_path / "config.json"
   path.write_text(json.dumps(config))

   ip = InputProperties(str(path))
   # object still created, but validation failed silently

