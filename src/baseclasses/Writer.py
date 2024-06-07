#!/usr/bin/env python3
import json
import logging
from typing import Type

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
        # TODO have it output FIPS in addition to node_id
       
        data = {'day': day, 'data': []}
        #for each_node in network.nodes:
        for each_node in network.nodes[:3]:    # Only writing three nodes for testing
            data['data'].append(each_node.return_dict())
        with open(self.output_filename, 'a') as o:
            o.write(json.dumps(data, indent=2))

        return


