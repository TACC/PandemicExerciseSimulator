#!/usr/bin/env python3
from enum import Enum
import logging
from typing import Type

from baseclasses.Group import Group
from baseclasses.ModelParameters import ModelParameters
from utils.RNGMath import rand_exp

logger = logging.getLogger(__name__)


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
        return


    def __str__(self) -> str:
        return(f'StochasticEvent object: init_time={self.init_time}, time={self.time}, '
               f'event_type={self.event_type}, origin={self.origin}, destination={self.destination}')


    def compare_event_time(self, other) -> bool:
        """
        Given a StochasticEvent object (other), return True if self is greater than (happens after)
        other
        """
        return (True if self.time > other.time else False)


class Schedule:

    def __init__(self, parameters:type[ModelParameters], now:float, group:Type[Group]):
        """
        TAU      # Latency period in days (exposed to asymptomatic)
        KAPPA    # Asymptomatic infectious period in days (asymptomatic to treatable)
        CHI      # Treatable to infectious rate in days
        GAMMA    # Total infectious period in days (asymptomatic/treatable/infectious to recovered)
        NU       # Mortality rate (asymptomatic/treatable/infectious to deceased)

        self._Ta         # Time from exposed to asymptomatic
        self._Tt         # Time from asymptomatic to treatable
        self._Ti         # Time from treatable to infectious
        self._Td_a       # Time from asymptomatic to death
        self._Td_ti      # Time from treatable/infectious to death
        self._Tr_a       # Time from asymptomatic to recovered
        self._Tr_ti      # Time from treatable/infectious to recovered
        self._Trd_ati    # Time from A/T/I to R/D
        """

        self._Ta    = rand_exp(parameters.tau) + now
        self._Tt    = rand_exp(parameters.kappa) + self._Ta
        self._Ti    = self._Tt + parameters.chi
        self._Td_a  = rand_exp(parameters.nu_values[group.age][group.risk]) + self._Ta
        self._Td_ti = rand_exp(parameters.nu_values[group.age][group.risk]) + self._Tt
        self._Tr_a  = rand_exp(parameters.gamma) + self._Ta
        self._Tr_ti = rand_exp(parameters.gamma) + self._Tt

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
        self._Ta    = (rand_exp(parameters.tau) + now) if compartment_num < 2 else now
        self._Tt    = (rand_exp(parameters.kappa) + self._Ta) if compartment_num < 3 else self._Ta
        self._Ti    = (self._Tt + parameters.chi) if compartment_num < 4 else self._Tt
        self._Td_a  = (rand_exp(parameters.nu_values[group.age][group.risk])) + self._Ta if compartment_num < 3 else float('inf')
        self._Td_ti = rand_exp(parameters.nu_values[group.age][group.risk]) + self._Tt
        self._Tr_a  = (rand_exp(parameters.gamma)) if compartment_num < 3 else float('inf')
        self._Tr_ti = rand_exp(parameters.gamma) + self._Tt
        
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

