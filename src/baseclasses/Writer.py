#!/usr/bin/env python3
from .Network import Network

class Writer:

    def __init__(self, filename:str = 'output.json') -> bool:
        self.output_filename=filename
        try:
            with open(self.output_filename, 'w') as o:
                try:
                    o.write('output')
                except (IOError, OSError) as e:
                    raise Exception(f'Error writing to {self.output_filename}') from e
                    sys.exit(1)
        except (FileNotFoundError, PermissionError, OSError) as e:
            raise Exception(f'Error opening {self.output_filename}') from e
            sys.exit(1)

        return

    def __str__(self):
        return(f'Writer class: Output file handle to {self.output_filename}')

    def write(self, network):
       with open(self.output_filename, 'w') as o:
           o.write(network.nodes[0].compartment)
