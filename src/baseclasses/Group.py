#!/usr/bin/env python3
from enum import Enum


class RiskGroup(Enum):
    L=0 #LOW=0
    H=1 #HIGH=1

class VaccineGroup(Enum):
    U=0 #UNVACCINATED=0
    V=1 #VACCINATED=1

# Group.py
from enum import Enum

_active_compartments = None  # not set until set_compartments() called

def _make_enum_from_labels(labels):
    if not labels:
        raise RuntimeError("Compartment labels required (got empty/None).")
    labels = [str(x).strip().upper() for x in labels]
    if len(labels) != len(set(labels)):
        dupes = sorted({x for x in labels if labels.count(x) > 1})
        raise ValueError(f"Duplicate compartment labels: {dupes}")
    if "S" not in labels:
        raise ValueError("Compartments must include 'S' for initialization.")
    if "E" not in labels:
        raise ValueError("Compartments must include 'E' for initialization.")
    if any(not s.isidentifier() for s in labels):
        bad = [s for s in labels if not s.isidentifier()]
        raise ValueError(f"Invalid labels (not identifiers): {bad}")
    return Enum("Compartments", {lbl: i for i, lbl in enumerate(labels)})

def set_compartments(labels_or_enum):
    # Called once at startup to choose the active Compartments enum
    global _active_compartments
    if isinstance(labels_or_enum, type) and issubclass(labels_or_enum, Enum):
        _active_compartments = labels_or_enum
    else:
        _active_compartments = _make_enum_from_labels(labels_or_enum)

def get_compartments_enum():
    if _active_compartments is None:
        raise RuntimeError("Compartments enum not set; call Group.set_compartments([...]) before use.")
    return _active_compartments

class _EnumProxy:
    def _enum(self):
        if _active_compartments is None:
            raise RuntimeError("Compartments enum not set; cannot access members.")
        return _active_compartments
    def __getattr__(self, name):   # e.g., Compartments.S
        return getattr(self._enum(), name)
    def __iter__(self):            # for c in Compartments
        return iter(self._enum())
    def __len__(self):             # len(Compartments)
        return len(self._enum())
    def __repr__(self):
        return "<Compartments proxy (unset)>" if _active_compartments is None \
               else f"<Compartments proxy -> {self._enum().__name__}>"

# Export to name used throughout codebase
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
