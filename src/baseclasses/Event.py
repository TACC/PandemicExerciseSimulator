#!/usr/bin/env python3
from enum import Enum
import logging
from typing import Type

from .Group import Group

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


class Event:

    def __init__(self, init_time:float, time:float, event_type:Type[EventType],
                       origin:Type[Group], destination:Type[Group]):
        self.init_time = init_time
        self.time = time
        self.event_type = event_type
        self.origin = origin
        self.destination = destination
        return


    def __str__(self) -> str:
        return(f'Event object: init_time={self.init_time}, time={self.time}, '
               f'event_type={self.event_type}, origin={self.origin}, destination={self.destination}')


    def compare_event_time(self, other) -> bool:
        """
        Given an Event object (other), return True if self is greater than (happens after)
        other
        """
        return (True if self.time > other.time else False)


