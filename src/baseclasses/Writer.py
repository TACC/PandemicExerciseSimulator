#!/usr/bin/env python3
import json
import logging
import os
import sys
import numpy as np
from typing import Type

from .Network import Network

logger = logging.getLogger(__name__)


class Writer:

    def __init__(self, output_dir_path:str = 'output', realization_index:int=0):
        self.output_dir = os.path.join(output_dir_path, f"output_sim{realization_index}")
        os.makedirs(self.output_dir, exist_ok=True)

        filename = 'output.json'
        self.output_filename = os.path.join(self.output_dir, filename)
        print(self.output_filename)
        try:
            with open(self.output_filename, 'w') as o:
                try:
                    o.write('')
                except (IOError, OSError) as e:
                    raise Exception(f'Error writing to {self.output_filename}') from e
                    sys.exit(1)
            os.remove(self.output_filename)
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
        # TODO collect daily reports of important events for the output, perhaps in the Day object
        # TODO Vaccines wasted/decayed or remaining in stockpile also good for report
        data = {'day': day, 'reports': [], 'data': [], 'total_summary': {}}
        for node in network.nodes:
            nd = node.return_dict()  # includes named compartment_summary
            data['data'].append(nd)
            for c, v in nd['compartment_summary'].items():
                data['total_summary'][c] = float(data['total_summary'].get(c, 0.0) + float(v))

        with open(f'{self.output_filename[:-5]}_{day}.json', 'w') as o:
            o.write(json.dumps(data, indent=2))
        return


