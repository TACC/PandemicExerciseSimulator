import pytest

from src.baseclasses.Day import Day

NUM=1
D=Day(NUM)


def test_Day():
    assert D.day == NUM
    assert (f'{D}') == f'Day:{NUM}'


def test_Day_exceptions():
    with pytest.raises(Exception):
        bad = Day('s')


def test_validate_input():
    assert Day._validate_input(D, 1) == True
    assert Day._validate_input(D, 0) == True
    assert Day._validate_input(D, 1.5) == False
    assert Day._validate_input(D, -1) == False
    assert Day._validate_input(D, 's') == False


def test_increment_day():
    this_value = D.day
    D.increment_day(0)
    assert D.day == (this_value + 0)
    D.increment_day(1) 
    assert D.day == (this_value + 1)


def test_increment_day_exceptions():
    with pytest.raises(Exception):
        D.increment_day(1.5)
    with pytest.raises(Exception):
        D.increment_day(-1)
    with pytest.raises(Exception):
        D.increment_day('s')

