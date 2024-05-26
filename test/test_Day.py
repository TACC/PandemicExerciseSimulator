import pytest

from src.baseclasses.Day import Day

NUM=1
D=Day(NUM)


def test_Day():
    assert D.number_of_days == NUM
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
    this_value = D.number_of_days
    D.increment_day(0)
    assert D.number_of_days == (this_value + 0)
    D.increment_day(1) 
    assert D.number_of_days == (this_value + 1)


def test_increment_day_exceptions():
    with pytest.raises(Exception):
        D.increment_day(1.5)
    with pytest.raises(Exception):
        D.increment_day(-1)
    with pytest.raises(Exception):
        D.increment_day('s')
    

