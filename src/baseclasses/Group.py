#!/usr/bin/env python3
from enum import Enum


class RiskGroup(Enum):
    L=0 #LOW=0
    H=1 #HIGH=1

class VaccineGroup(Enum):
    U=0 #UNVACCINATED=0
    V=1 #VACCINATED=1

class Compartments(Enum):
    S=0 #SUSCEPTIBLE=0
    E=1 #EXPOSED=1
    A=2 #ASYMPTOMATIC=2
    T=3 #TREATABLE=3
    I=4 #INFECTIOUS=4
    R=5 #RECOVERED=5
    D=6 #DECEASED=6


class Group:

    def __init__(self, age:int, risk_group:int, vaccine_group:int):
        try:
            assert self._validate_input(age) == True
            self.age = age
        except AssertionError as e:
            raise Exception('Group class must be instantiated with a positive integer for age group') from e

        try:
            assert self._validate_input(risk_group) == True
            self.risk = risk_group
            self.risk_group_name = RiskGroup(risk_group).name
        except AssertionError as e:
            raise Exception('Group class must be instantiated with a positive integer for risk group') from e

        try:
            assert self._validate_input(vaccine_group) == True
            self.vaccine = vaccine_group
            self.vaccine_group_name = VaccineGroup(vaccine_group).name
        except AssertionError as e:
            raise Exception('Group class must be instantiated with a positive integer for vaccine group') from e
        return


    def __str__(self) -> str:
        return(f'Group object: age={self.age}, risk={self.risk}, vaccine={self.vaccine}')

    def __repr__(self):
        return self.__str__()

    def __eq__(self, other) -> bool:
        return ( self.age == other.age and 
                 self.risk == other.risk and 
                 self.vaccine == other.vaccine
               )


    def _validate_input(self, num:int) -> bool:
        """
        Helper function to check input values
        """
        return(str(num).isnumeric())
