#!/usr/bin/env python3

class ModelParameters:

    def __init__(self, simulation_properties):
        self.R0             = simulation_properties.R0 
        self.beta_scale     = simulation_properties.beta_scale 
        self.tau            = simulation_properties.tau
        self.kappa          = simulation_properties.kappa
        self.gamma          = simulation_properties.gamma
        self.low_death_rate = True if simulation_properties.nu_high == "yes" else False

        self.vaccine_effectiveness = [ simulation_properties.vaccine_effectiveness_age_0,
                                       simulation_properties.vaccine_effectiveness_age_1,
                                       simulation_properties.vaccine_effectiveness_age_2,
                                       simulation_properties.vaccine_effectiveness_age_3,
                                       simulation_properties.vaccine_effectiveness_age_4, ]

        self.vaccine_adherence = [ simulation_properties.vaccine_adherence_age_0,
                                   simulation_properties.vaccine_adherence_age_1,
                                   simulation_properties.vaccine_adherence_age_2,
                                   simulation_properties.vaccine_adherence_age_3,
                                   simulation_properties.vaccine_adherence_age_4, ]

    def __str__(self):
        return(f'R0={self.R0}, beta_scale={self.beta_scale}, tau={self.tau}, '
               f'kappa={self.kappa}, gamma={self.gamma}, low_death_rate={self.low_death_rate}')

