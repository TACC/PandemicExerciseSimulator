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
