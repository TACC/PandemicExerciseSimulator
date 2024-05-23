#!/usr/bin/env python3
import numpy as np

class ModelParameters:

    def __init__(self, simulation_properties):
        self.R0             = simulation_properties.R0 
        self.beta_scale     = simulation_properties.beta_scale 
        self.tau            = simulation_properties.tau
        self.kappa          = simulation_properties.kappa
        self.gamma          = simulation_properties.gamma
        self.chi            = simulation_properties.chi
        self.low_death_rate = True if simulation_properties.nu_high == "yes" else False

        self.vaccine_effectiveness = []
        self.vaccine_adherence = []

        with open(simulation_properties.vaccine_effectiveness_file, 'r') as f:
            self.vaccine_effectiveness = [ line.rstrip() for line in f ]

        with open(simulation_properties.vaccine_adherence_file, 'r') as f:
            self.vaccine_adherence = [ line.rstrip() for line in f ]



    def __str__(self):
        return(f'R0={self.R0}, beta_scale={self.beta_scale}, tau={self.tau}, '
               f'kappa={self.kappa}, gamma={self.gamma}, chi={self.chi}, low_death_rate={self.low_death_rate}, '
               f'number_of_age_groups={self.number_of_age_groups}')

    def load_contact_matrix(self, filename):
        """
        The file contact_matrix.5 contains 5 rows and 5 columns

        45.1228487783,8.7808312353,11.7757947836,6.10114751268,4.02227175596
        8.7808312353,41.2889143668,13.3332813497,7.847051289,4.22656343551
        11.7757947836,13.3332813497,21.4270155984,13.7392636644,6.92483172729
        6.10114751268,7.847051289,13.7392636644,18.0482119252,9.45371062356
        4.02227175596,4.22656343551,6.92483172729,9.45371062356,14.0529294262

        """
        #filename = f'../../{filename}'

        try:
            self.np_contact_matrix = np.genfromtxt(filename, delimiter=',')
        except FileNotFoundError as e:
            raise Exception(f'Could not open {filename}') from e
            sys.exit(1)

        self.set_age_group_size()

    def set_age_group_size(self):
        self.number_of_age_groups = (np.shape(self.np_contact_matrix)[0])
            


