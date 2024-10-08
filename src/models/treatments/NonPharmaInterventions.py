#!/usr/bin/env python3
import json
import logging
import numpy as np
from typing import Type

from baseclasses.Network import Network

logger = logging.getLogger(__name__)


class NonPharmaInterventions:

    def __init__(self, npis:list, num_days:int, num_locations:int, num_age_groups:int):
        self.npis = npis
        self.length = num_days+1
        self.num_locations = num_locations
        self.num_age_groups = num_age_groups
        self.schedule = np.zeros(( self.length,
                                   self.num_locations,
                                   self.num_age_groups
                                ))
        logger.info(f'instantiated a NonPharmInterventions object of shape: {np.shape(self.schedule)}')
        return


    def __str__(self) -> str:
        return(f'NPI class: The raw input NPIs are: {json.dumps(self.npis, indent=2)}')


    def pre_process(self, network:Type[Network]):
        """
        Iterate over each NPI and calculate total effectiveness for each age
        group by Day & County
        """
        if self.npis is not None:
            for npi in self.npis:

                npi_day = int(npi['day'])
                npi_duration = int(npi['duration'])
                npi_location = npi['location']
                npi_index_list = self._location_to_index_list(npi_location, network)
                npi_effectiveness = [float(x) for x in npi['effectiveness']]

                logging.debug(f'npi_index_list = {npi_index_list}')
                logging.debug(f'npi_day = {npi_day}; npis_length = {self.length}')
                logging.debug(f'duration = {npi_duration}; effectiveness = {npi_effectiveness}')

                for i in range(npi_day, npi_day+npi_duration):
                    if (i > self.length-1): continue
                    for j in npi_index_list:
                        self._add_percent_effectiveness(i, int(j), npi_effectiveness)
        return


    def _location_to_index_list(self, location:str, network: Type[Network]) -> list:
        """
        Convert a location ID to a list of indices
        """
        if (location == '0'):
            return [x for x in range(self.num_locations)]
        else:
            index_list = []
            for item in location.split(','):
                index_list.append(network.get_node_index_by_id(int(item)))
                logging.debug(f'item = {item}; index_list = {index_list}')
            return index_list


    def _add_percent_effectiveness(self, day:int, loc:int, npi_effectiveness:list):
        """
        Add the effectiveness of an NPI to the schedule

        Overlapping NPIs have an additive effectiveness following the formula:
        Tot = A + ((1-A)*B)

        where A = percent effectiveness of NPI A, expressed as decimal
              B = percent effectiveness of NPI B, expressed as decimal
        """
        for eff in range(len(npi_effectiveness)):
            logging.debug(f'this schedule = {self.schedule[day][loc][eff]}')
            logging.debug(f'this effectiveness = {npi_effectiveness[eff]}')
            self.schedule[day][loc][eff] = self.schedule[day][loc][eff] + \
                                           ((1-self.schedule[day][loc][eff]) * npi_effectiveness[eff])
        return
