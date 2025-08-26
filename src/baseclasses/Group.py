#!/usr/bin/env python3
from enum import Enum


class RiskGroup(Enum):
    L=0 #LOW=0
    H=1 #HIGH=1

class VaccineGroup(Enum):
    U=0 #UNVACCINATED=0
    V=1 #VACCINATED=1

# 1) Your default enum (used if user doesn't override)
_CompartmentsDefault = Enum("CompartmentsDefault", {
    "S": 0, "E": 1, "A": 2, "T": 3, "I": 4, "R": 5, "D": 6
})

# 2) The "active" enum backing the proxy
_active_compartments = _CompartmentsDefault

def _make_enum_from_labels(labels, name="Compartments"):
    labels = [str(x).strip().upper() for x in labels]
    if len(labels) != len(set(labels)):
        raise ValueError(f"Duplicate compartment labels: {labels}")
    return Enum(name, {lbl: i for i, lbl in enumerate(labels)})

def set_compartments(labels_or_enum):
    """Call this once at startup to choose the active Compartments enum."""
    global _active_compartments
    if isinstance(labels_or_enum, type) and issubclass(labels_or_enum, Enum):
        _active_compartments = labels_or_enum
    else:
        _active_compartments = _make_enum_from_labels(labels_or_enum)

def get_compartments_enum():
    """If you ever need the real Enum class."""
    return _active_compartments

class _EnumProxy:
    """Proxy so code can keep using `Compartments.S.value`, `len(Compartments)`, etc."""
    def __getattr__(self, name):
        # Return the current Enum member (e.g., S/E/I/R)
        return getattr(_active_compartments, name)
    def __iter__(self):
        return iter(_active_compartments)
    def __len__(self):
        return len(_active_compartments)
    def __repr__(self):
        return f"<Compartments proxy -> {_active_compartments.__name__} {list(_active_compartments)}>"

# 3) Export the proxy under the familiar name
Compartments = _EnumProxy()

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
