#!/usr/bin/env python3
import json
import logging
from typing import Type
import sys

from .Network import Network

logger = logging.getLogger(__name__)


class Writer:

    def __init__(self, filename:str = 'output.json') -> bool:
        self.output_filename=filename
        try:
            with open(self.output_filename, 'w') as o:
                try:
                    o.write('')
                except (IOError, OSError) as e:
                    raise Exception(f'Error writing to {self.output_filename}') from e
                    sys.exit(1)
        except (FileNotFoundError, PermissionError, OSError) as e:
            raise Exception(f'Error opening {self.output_filename}') from e
            sys.exit(1)

        logger.info(f'instantiated Writer object with output file {self.output_filename}')
        return


    def __str__(self) -> str:
        return(f'Writer class: Output file handle to {self.output_filename}')


    def write(self, day:int, network:Type[Network]):
        """
        Write output of network to JSON file

        Args:
            day (int): simulation day
            network (Network): Network object with list of nodes
        """
        data = {'day': day, 'data': []}
        for each_node in network.nodes[:]:
            data['data'].append(each_node.return_dict())
        #with open(self.output_filename, 'a') as o:
        with open(f'{self.output_filename[:-5]}_{day}.json', 'w') as o:
            o.write(json.dumps(data, indent=2))
        return


