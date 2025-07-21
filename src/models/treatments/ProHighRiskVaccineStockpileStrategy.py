import logging
from baseclasses.Group import Group
from baseclasses.Node import Node
from baseclasses.Network import Network


class ProHighRiskVaccineStockpileStrategy:
    def __init__(self, vaccination, network):
        """
        Args:
            vaccination (Vaccination): An instance of the Vaccination class
            network (Network): Network object with all nodes
        """
        self.vaccination = vaccination

        # Convert list of dicts to {day: amount}
        self.stockpile_by_day = {
            int(entry["day"]): float(entry["amount"])
            for entry in self.vaccination.vaccine_stockpile
        }