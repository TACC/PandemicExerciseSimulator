#!/usr/bin/env python3
import logging
import matplotlib.pyplot as plt
import sys
from typing import Type

from .Group import Compartments
from .Network import Network

logger = logging.getLogger(__name__)


class Day:

    def __init__(self, num:int):
        try:
            assert self._validate_input(num) == True
        except AssertionError as e:
            raise Exception('Day class must be initialized with positive integer') from e
            sys.exit(1)
        self.day = int(num)
        self.summary = []
        logger.info(f'instantiated Day object with seed {num}')
        logger.debug(f'{self}')
        return


    def __str__(self) -> str:
        return(f'Day:{self.day}')


    def _validate_input(self, num:int) -> bool:
        return(str(num).isnumeric())


    def increment_day(self, num:int):
        try:
            assert self._validate_input(num) == True
        except AssertionError as e:
            raise Exception('Day class can only be incremented by a positive integer') from e
            sys.exit(1)
        self.day += int(num)
        return


    def snapshot(self, network:Type[Network]):
        """
        Store summary information for each day
        """
        this_summary = [0.0] * 7
        for node in network.nodes:
            this_summary[Compartments.S.value] += node.compartments.susceptible_population()
            this_summary[Compartments.E.value] += node.compartments.exposed_population()
            this_summary[Compartments.A.value] += node.compartments.asymptomatic_population()
            this_summary[Compartments.T.value] += node.compartments.treatable_population()
            this_summary[Compartments.I.value] += node.compartments.infectious_population()
            this_summary[Compartments.R.value] += node.compartments.recovered_population()
            this_summary[Compartments.D.value] += node.compartments.deceased_population()
        self.summary.append(this_summary)
        logging.info(f'summary information for day {len(self.summary)-1} = {this_summary}')
        return this_summary


    def plot(self):
        """
        Save a plot of all compartments over time
        """
        days = [ val for val in range(len(self.summary)) ]
        logging.info(f'days simulated = {days}')
        for comp in Compartments:
            #if comp.value == 0: continue
            values = [ row[comp.value] for row in self.summary ]
            plt.plot(days, values, label=f'Compartment={comp.name}')  
        plt.legend()
        plt.savefig('plot.png')
        return


