from src.baseclasses.Day import Day
import pytest


NUM=1

def test_Day():
    d = Day(NUM)
    assert d.number_of_days == NUM
    assert (f'{d}') == f'Day:{NUM}'


def test_Day_exceptions():
    with pytest.raises(Exception):
        d = Day('s')
