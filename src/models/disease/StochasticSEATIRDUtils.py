#!/usr/bin/env python3
from enum import Enum
import logging
import math
from numpy.random import mtrand
from typing import Type

from baseclasses.Group import Group
from baseclasses.ModelParameters import ModelParameters

logger = logging.getLogger(__name__)


def rand_exp(lambda_val:float, rand_val:float) -> float:
    """
    Return negative log of a random value divided by the provided lambda value
    """
    return (-math.log(rand_val)/lambda_val)


def rand_int(lower:int, upper:int) -> int:
    """
    Expected behavior is that the int returned is in the range [lower, upper], inclusive
    """
    return (mtrand.randint(lower, upper+1))


class EventType(Enum):
    EtoA=0    # exposed to asymptomatic
    AtoT=1    # asymptomatic to treatable
    AtoR=2    # asymptomatic to recovered
    AtoD=3    # asymptomatic to deceased
    TtoI=4    # treatable to infections
    TtoR=5    # treatable to recovered
    TtoD=6    # treatable to deceased
    ItoR=7    # infectious to recovered
    ItoD=8    # infectious to deceased
    CONTACT=9


class StochasticEvent:

    def __init__(self, init_time:float, time:float, event_type:Type[EventType],
                       origin:Type[Group], destination:Type[Group]):
        self.init_time = init_time
        self.time = time
        self.event_type = event_type
        self.origin = origin
        self.destination = destination

    def __str__(self) -> str:
        return(f'StochasticEvent object: init_time={self.init_time}, time={self.time}, '
               f'event_type={self.event_type}, origin={self.origin}, destination={self.destination}')

    # TODO rename this method so that it is clearer what it is doing
    def compare_event_time(self, other) -> bool:
        return (True if self.time > other.time else False)



class Schedule:

    def __init__(self, parameters:type[ModelParameters], now:float, group:Type[Group]):
        """
        TAU      # exposed to asymptomatic
        KAPPA    # asymptomatic to treatable
        CHI      # treatable to infectious -- fixed rate, in days
        GAMMA    # asymptomatic/treatable/infectious to recovered
        NU       # asymptomatic/treatable/infectious to deceased

        self._Ta         # Time from exposed to asymptomatic
        self._Tt         # Time from asymptomatic to treatable
        self._Ti         # Time from treatable to infectious
        self._Td_a       # Time from asymptomatic to death
        self._Td_ti      # Time from treatable/infectious to death
        self._Tr_a       # Time from asymptomatic to recovered
        self._Tr_ti      # Time from treatable/infectious to recovered
        self._Trd_ati    # Time from A/T/I to R/D
        """

        self._Ta    = rand_exp(parameters.tau, mtrand.rand()) + now
        self._Tt    = rand_exp(parameters.kappa, mtrand.rand()) + self._Ta
        self._Ti    = self._Tt + parameters.chi
        self._Td_a  = rand_exp(parameters.nu_values[group.age][group.risk], mtrand.rand()) + self._Ta
        self._Td_ti = rand_exp(parameters.nu_values[group.age][group.risk], mtrand.rand()) + self._Tt
        self._Tr_a  = rand_exp(parameters.gamma, mtrand.rand()) + self._Ta
        self._Tr_ti = rand_exp(parameters.gamma, mtrand.rand()) + self._Tt

        # exit_asymptomatic_time means via recovery or death, not progression to symptomatic stage
        self.exit_asymptomatic_time = min(self._Td_a, self._Tr_a)
        if (self._Tt < self.exit_asymptomatic_time): self.exit_asymptomatic_time = float('inf')
        self.exit_infectious_time = min(self._Td_ti, self._Tr_ti)

        self._Trd_ati = min(self.exit_asymptomatic_time, self.exit_infectious_time)

        return
       

    def update(self, parameters:type[ModelParameters], now:float, group:Type[Group], compartment_num:int):
        """
        Used when reinitializing events
        S=0, E=1, A=2, T=3, I=4, R=5, D=6
        """
        assert int(compartment_num) > 0 and int(compartment_num) < 5
        self._Ta    = (rand_exp(parameters.tau, mtrand.rand()) + now) if compartment_num < 2 else now
        self._Tt    = (rand_exp(parameters.kappa, mtrand.rand()) + self._Ta) if compartment_num < 3 else self._Ta
        self._Ti    = (self._Tt + parameters.chi) if compartment_num < 4 else self._Tt
        self._Td_a  = (rand_exp(parameters.nu_values[group.age][group.risk], mtrand.rand())) + self._Ta if compartment_num < 3 else float('inf')
        self._Td_ti = rand_exp(parameters.nu_values[group.age][group.risk], mtrand.rand()) + self._Tt
        self._Tr_a  = (rand_exp(parameters.gamma, mtrand.rand())) if compartment_num < 3 else float('inf')
        self._Tr_ti = rand_exp(parameters.gamma, mtrand.rand()) + self._Tt
        
        self.exit_asymptomatic_time = min(self._Td_a, self._Tr_a)
        if (self._Tt < self.exit_asymptomatic_time): self.exit_asymptomatic_time = float('inf')
        self.exit_infectious_time = min(self._Td_ti, self._Tr_ti)

        self._Trd_ati = min(self.exit_asymptomatic_time, self.exit_infectious_time)

        return

    def Ta(self):      return(self._Ta)
    def Tt(self):      return(self._Tt)
    def Ti(self):      return(self._Ti)
    def Td_a(self):    return(self._Td_a)
    def Td_ti(self):   return(self._Td_ti)
    def Tr_a(self):    return(self._Tr_a)
    def Tr_ti(self):   return(self._Tr_ti)
    def Trd_ati(self): return(self._Trd_ati)

