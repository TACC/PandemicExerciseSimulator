import logging
import warnings
from typing import Type

from baseclasses.Node import Node
from baseclasses.Group import Group
from baseclasses.PopulationCompartments import Compartments

class Vaccination:

    def __init__(self):
        pass

    # Taking in the unvax and vax groups in case we ever want more than 2 compartments, e.g. boosters, multiple vaccines
    def vaccinate_number_of_people(self, node: Type[Node], unvax_group: Type[Group], vax_group: Type[Group], num_to_vaccinate: int):
        """
        Moves individuals from an unvaccinated group to a vaccinated group.

        Args:
            node (Node): The node where vaccination occurs
            unvax_group (Group): The group to decrement (unvaccinated)
            vax_group (Group): The group to increment (vaccinated)
            num_to_vaccinate (int): Number of individuals to vaccinate
        """
        if isinstance(num_to_vaccinate, float):
            if num_to_vaccinate.is_integer():
                num_to_vaccinate = int(num_to_vaccinate)
            else:
                warnings.warn(
                    f"num_to_vaccinate ({num_to_vaccinate}) is not an integer. Flooring to {int(num_to_vaccinate)}.",
                    UserWarning)
                num_to_vaccinate = int(num_to_vaccinate)
        elif not isinstance(num_to_vaccinate, int):
            raise ValueError("num_to_vaccinate must be an integer or integer-valued float")

        current_unvax = int(node.compartments.compartment_data[unvax_group.age][unvax_group.risk][unvax_group.vaccine][Compartments.S.value])
        logging.debug(f'Current unvaccinated susceptibles: {current_unvax}')

        # Determine how many we can actually vaccinate (cannot vaccinate more than available)
        num_vaccinating = min(num_to_vaccinate, current_unvax)
        logging.debug(f'Vaccinating {num_vaccinating} individuals from {unvax_group} to {vax_group}')

        # Decrement from unvaccinated group directly
        node.compartments.compartment_data[unvax_group.age][unvax_group.risk][unvax_group.vaccine][Compartments.S.value] -= num_vaccinating

        # Increment to vaccinated group directly
        node.compartments.compartment_data[vax_group.age][vax_group.risk][vax_group.vaccine][Compartments.S.value] += num_vaccinating

        return