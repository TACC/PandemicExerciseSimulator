import logging
import warnings
from typing import Type

from baseclasses.ModelParameters import ModelParameters
from baseclasses.Network import Network
from baseclasses.Node import Node
from baseclasses.Group import Group
from baseclasses.PopulationCompartments import Compartments

logger = logging.getLogger(__name__)

class Vaccination:

    def __init__(self, parameters:Type[ModelParameters]):
        self.vaccine_model_str = 'parent'
        self.parameters = parameters

        num_age_grps = parameters.number_of_age_groups

        # VE is used in travel model and disease model
        self.vaccine_effectiveness  = [ # float 0.0 to 1.0
            float(x) for x in self.parameters.vaccine_parameters.get('vaccine_effectiveness', []) ]
        if not self.vaccine_effectiveness:
            self.vaccine_effectiveness = [0.0] * num_age_grps

        logger.info(f'Instantiated VaccineModel object with model={self.vaccine_model_str}')
        logger.debug(f'Vaccination.parameters = {self.parameters}')


    def get_child(self, vaccine_model_str:str, network:Type[Network]):
        """
        vaccine_model_str (str): Name of vaccine_model from input file
        Choose vaccination strategy if not "None"
        """
        if vaccine_model_str is None:
            logger.info("No vaccine strategy specified; using base Vaccination class.")
            return self  # still has effectiveness, but no distribution behavior

        if vaccine_model_str == "uniform-stockpile":
            from .UniformVaccineStockpileStrategy import UniformVaccineStockpileStrategy
            return UniformVaccineStockpileStrategy(self, network)
        else:
            raise Exception(f'Vaccination model "{vaccine_model_str}" not recognized')
        return

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

    def distribute_vaccines_to_nodes(self, network: Type[Network], day: int):
        pass

    def distribute_vaccines_to_population(self, node: Type[Node], day: int):
        pass