#!/usr/bin/env python3
import numpy as np
import logging
from typing import Type

from baseclasses.Group import Group, RiskGroup, VaccineGroup
from baseclasses.Node import Node
from models.disease.DiseaseModel import DiseaseModel
from models.treatments.Vaccination import Vaccination

logger = logging.getLogger(__name__)

def adjust_two_way_split_proportion(
    *,
    desired_realized_fraction: float,
    competing_rate: float,
    target_rate: float,
) -> float:
    """
    Compute the adjustment factor π for a two-way split so that the realized
    fraction to the *target* branch equals p, per:

        π = (p * γ) / ( (γ - η) * p + η )

    See Appendix of this paper: https://www.researchsquare.com/article/rs-3467930/v1
    Or worked-out GoogleDoc from Remy F. Pasco

    Variable mapping to your model:
      - p        : desired_realized_fraction  (e.g., prop_hosp from self.prop_*[…])
      - γ (gamma): competing_rate             (e.g., self.IS_to_R_rate)
      - η (eta)  : target_rate                (e.g., self.IS_to_H_rate)

    Returns:
      π in [0,1], to be used as:
        flow_to_target    = π * η * compartment_level
        flow_to_competing = (1 - π) * γ * compartment_level
    """
    if not (0.0 <= desired_realized_fraction <= 1.0):
        raise ValueError("desired_realized_fraction must be in [0, 1].")
    if competing_rate <= 0.0 or target_rate <= 0.0:
        raise ValueError("Rates must be positive.")

    denom = (competing_rate - target_rate) * desired_realized_fraction + target_rate
    corrected_fraction = (desired_realized_fraction * competing_rate) / denom

    return corrected_fraction

#### Estimate the generation time based only on input parameters
def compute_generation_time(
        E_out_rate, IP_to_IS_rate, IS_to_H_rate, IS_to_R_rate, IA_to_R_rate,
        prop_E_to_IA, rel_inf_IP_to_IS=1.0, rel_inf_IA_to_IS=1.0, rel_inf_IS=1.0):
    """
    Approximate mean generation time (days) from input parameters.
    Generation time (GT) is time interval between the infection of a primary case (infector)
      and the infection of a secondary case (infectee).
    Generation time is about WHEN infection occurs, not how many infections occur (R0).
    In the real world, we observe the serial interval based on symptom onset, but here we can estimate GT.

    Returns
    -------
    float : mean generation time (days)
    """
    # ----- durations -----
    D_E  = 1.0 / E_out_rate               # latent period
    D_IP = 1.0 / IP_to_IS_rate
    D_IS = 1.0 / (IS_to_H_rate + IS_to_R_rate)
    D_IA = 1.0 / IA_to_R_rate

    # ----- asymptomatic -----
    prop_asymp      = np.array(prop_E_to_IA, dtype=float)   # per-age, then take mean
    prop_asymp_mean = prop_asymp.mean()

    # ----- total infectious durations (weighted) -----
    W_IP = (1 - prop_asymp_mean) * rel_inf_IP_to_IS * D_IP
    W_IS = (1 - prop_asymp_mean) * rel_inf_IS       * D_IS
    W_IA = prop_asymp_mean       * rel_inf_IA_to_IS * D_IA
    W_total = W_IP + W_IS + W_IA

    # ----- mean generation time numerator -----
    numerator = (
        W_IP * (D_E + D_IP) +
        W_IS * (D_E + D_IP + D_IS) +
        W_IA * (D_E + D_IA)
    )

    return numerator / W_total

#### Get beta from R0 and Next Generation Matrix
def compute_w(prop_E_to_IA,
              IP_to_IS_rate, IS_to_H_rate, IS_to_R_rate, IA_to_R_rate,
              rel_inf_IP=1.0, rel_inf_IS=1.0, rel_inf_IA=1.0):
    """
    Compute per-group infectiousness weights w_j.
    prop_E_to_IA : array-like (n,)
        Fraction asymptomatic for each group j.
    A_to_B_rate: scalar rates (already 1/days).
    rel_inf_* : relative infectiousness multipliers.
    """
    prop_E_to_IA = np.asarray(prop_E_to_IA, dtype=float)

    # Durations are reciprocals of total exit rates, i.e. back to days
    d_IP = 1.0 / IP_to_IS_rate
    d_IS = 1.0 / (IS_to_H_rate + IS_to_R_rate)
    d_IA = 1.0 / IA_to_R_rate

    symptomatic_block = rel_inf_IP * d_IP + rel_inf_IS * d_IS
    asymptomatic_block = rel_inf_IA * d_IA

    w = (1.0 - prop_E_to_IA) * symptomatic_block + prop_E_to_IA * asymptomatic_block
    return w


def estimate_baseline_beta(
    contact_matrix: list[list[float]],         # (n,n) matrix C, rows susceptible i, cols infectious j
    R0: float,                                 # scalar
    w: np.ndarray,                             # (n,) vector to diagonal matrix from compute_w
    susceptibility: np.ndarray | None = None,  # optional (n,) S_i; defaults to 1s = identity matrix
) -> float:
    """
    Compute beta so that rho( beta * S * C * diag(w) ) = R0.
    rho() refers to the spectral radius = the dominant eigenvalue of matrix K
    beta is scalar so beta * rho(M) = R0 => beta = R0/rho(M), where M = S * C * diag(w)
    """
    C = np.array(contact_matrix, dtype=float)
    w = np.asarray(w, dtype=float)
    n = C.shape[0] # number of age groups
    assert C.shape == (n, n), "contact_matrix must be square"
    assert w.shape == (n,), "w must be length-n"

    if susceptibility is None:
        S_mat = np.eye(n)
    else:
        s = np.asarray(susceptibility, dtype=float)
        assert s.shape == (n,), "susceptibility must be length-n"
        S_mat = np.diag(s)

    M = S_mat @ C @ np.diag(w)    # this is the beta-free NGM core
    rho = DiseaseModel.spectral_radius(M)      # spectral radius

    if rho <= 0:
        raise ValueError("Spectral radius is non-positive; check inputs (C, w, susceptibility).")

    beta = R0 / rho
    return beta

# This should probably be moved to a pytest once debug phase over
def build_NGM(beta: float, contact_matrix: np.ndarray, w: np.ndarray, susceptibility: np.ndarray | None = None) -> np.ndarray:
    """
    Optionally construct K to verify rho(K) ≈ R0 after solving for beta.
    """
    C = np.asarray(contact_matrix, dtype=float)
    w = np.asarray(w, dtype=float)
    n = C.shape[0]
    S_mat = np.diag(susceptibility) if susceptibility is not None else np.eye(n)
    return beta * (S_mat @ C @ np.diag(w))


def SEIHRD_model(y,
                 transmission_rate, # S => E
                 E_out_rate,        # E => IA & IP, goes in Poisson then split by prop
                 prop_E_to_IA,      # fraction leaving E that are asymptomatic
                 IP_to_IS_rate,     # IP => IS
                 IS_to_H_rate,      # IS => H, rate * (1 - VE_hosp) * proportion hospitalized
                 IS_to_R_rate,      # IS => R, rate * (1 - proportion hospitalized)
                 H_to_D_rate,       # H => D,
                 H_to_R_rate,       # H => R,
                 IA_to_R_rate,      # IA => R,
                 rng):
    """
    SEIHRD compartmental model ODE function.
    Parameters:
        y (List[float]): Current values for compartments [S, E, IA, IP, IS, H, R, D]
        transmission_rate (float): beta modified by NPIs, vaccine effectiveness, contact rate,
                                   has I/N hidden in it to do node based proportion of population infectious
        E_out_rate (float):
        prop_E_to_IA (float):
        IP_to_IS_rate (float):
        IS_to_H_rate (float):
        IS_to_R_rate (float):
        H_to_D_rate (float):
        H_to_R_rate (float):
        IA_to_R_rate (float):
        rng ():
    Returns:
       List[float]: Derivatives [dS/dt, dE/dt, dIA/dt, dIP/dt, dIS/dt, dH/dt, dR/dt, dD/dt].
   """

    # ensure integer state for stochastic model
    S, E, IA, IP, IS, H, R, D = map(int, y)

    # per-channel intensities λ = rate_per_capita * count * dt (dt=1)
    lam_inf    = max(transmission_rate, 0.0) * S
    lam_EIPIA  = max(E_out_rate, 0.0) * E         # This gets split into two paths below
    lam_IPIS   = max(IP_to_IS_rate, 0.0) * IP
    # IS/H rates are used below to prevent over-draw of IS/H compartments
    rate_ISH = max(IS_to_H_rate, 0.0)
    rate_ISR = max(IS_to_R_rate, 0.0)
    rate_HD = max(H_to_D_rate, 0.0)
    rate_HR = max(H_to_R_rate, 0.0)

    lam_IAR    = max(IA_to_R_rate, 0.0) * IA

    # Prevent compartments from going negative by only removing as many people remain in the compartment
    max_new_infections = min(rng.poisson(lam_inf), S)
    total_e_out = min(rng.poisson(lam_EIPIA),  E)
    e_to_ia     = np.floor(prop_E_to_IA * total_e_out)
    e_to_ip     = total_e_out - e_to_ia
    ip_to_is    = min(rng.poisson(lam_IPIS),  IP)
    ia_to_r = min(rng.poisson(lam_IAR), IA)

    # IS split: draw target first (IS→H), then compete from remaining (IS→R)
    is_to_h = min(rng.poisson(rate_ISH * IS), IS)
    remaining_IS = IS - is_to_h
    is_to_r = min(rng.poisson(rate_ISR * remaining_IS), remaining_IS)

    # H split: draw target first (H→D), then compete from remaining (H→R)
    h_to_d = min(rng.poisson(rate_HD * H), H)
    remaining_H = H - h_to_d
    h_to_r = min(rng.poisson(rate_HR * remaining_H), remaining_H)

    # Get derivatives
    dS_dt  = -max_new_infections
    dE_dt  = max_new_infections - e_to_ia - e_to_ip
    dIA_dt = e_to_ia - ia_to_r
    dIP_dt = e_to_ip - ip_to_is
    dIS_dt = ip_to_is - is_to_h - is_to_r
    dH_dt  = is_to_h - h_to_d - h_to_r
    dD_dt  = h_to_d
    dR_dt  = is_to_r + h_to_r + ia_to_r

    return np.array([dS_dt, dE_dt, dIA_dt, dIP_dt, dIS_dt, dH_dt, dR_dt, dD_dt])

class StochasticSEIHRD(DiseaseModel):

    def __init__(self, disease_model:Type[DiseaseModel]): # add antiviral_model
        self.now = disease_model.now
        self.parameters = disease_model.parameters

        # R0 and rate out of compartments, immune period for waning optional
        self.R0            = float(self.parameters.disease_parameters['R0'])
        self.E_out_rate    = 1 / float(self.parameters.disease_parameters['E_to_IPandIA_days'])
        self.IP_to_IS_rate = 1 / float(self.parameters.disease_parameters['IP_to_IS_days'])
        self.IS_to_H_rate  = 1 / float(self.parameters.disease_parameters['IS_to_H_days'])
        self.H_to_D_rate   = 1 / float(self.parameters.disease_parameters['H_to_D_days'])
        self.H_to_R_rates  = [1 / float(x) for x in self.parameters.disease_parameters['H_to_R_days']]
        self.IS_to_R_rate  = 1 / float(self.parameters.disease_parameters['IS_to_R_days'])
        self.IA_to_R_rate  = 1 / float(self.parameters.disease_parameters['IA_to_R_days'])

        # Proportions of population for each split by age, & risk for hospitalization
        self.prop_E_to_IA   = [float(x) for x in self.parameters.disease_parameters['prop_E_to_IA']]
        highrisk_hosp_multi = float(self.parameters.disease_parameters['highrisk_hosp_multiplier'])
        lowrisk             = [float(x) for x in self.parameters.disease_parameters['prop_IS_to_H_lowrisk']]
        highrisk            = [highrisk_hosp_multi * v for v in lowrisk]

        # IS → H vs R proportion correction for EACH [risk][age]
        self.prop_IS_to_H = []
        for risk_group_props in [lowrisk, highrisk]:
            corrected_for_this_risk = [
                adjust_two_way_split_proportion(
                    desired_realized_fraction=p,       # age and risk specific
                    competing_rate=self.IS_to_R_rate,  # γ = IS→R
                    target_rate=self.IS_to_H_rate,     # η = IS→H
                )
                for p in risk_group_props
            ]
            self.prop_IS_to_H.append(corrected_for_this_risk)

        #---------------------------------
        # H → D vs R proportion correction
        prop_H_to_D    = [float(x) for x in self.parameters.disease_parameters['prop_H_to_D']]
        self.prop_H_to_D = [
            adjust_two_way_split_proportion(
                desired_realized_fraction=p,
                competing_rate=r_rate,         # γ = H→R (age-specific)
                target_rate=self.H_to_D_rate,  # η = H→D (fixed/uniform)
            )
            for p, r_rate in zip(prop_H_to_D, self.H_to_R_rates)
        ]

        # Relative infectiousness of other compartments
        self.rel_inf_IP_to_IS = float(self.parameters.disease_parameters['rel_inf_IP_to_IS'])
        self.rel_inf_IA_to_IS = float(self.parameters.disease_parameters['rel_inf_IA_to_IS'])

        # Relative susceptibility required for travel model, make 1's if not specified
        num_age_grps = self.parameters.number_of_age_groups
        self.relative_susceptibility = [
            float(x) for x in self.parameters.disease_parameters.get(
                "relative_susceptibility", [1.0] * num_age_grps
            )]

        #----------------------------------------------------
        # `beta` is a required name for _calculate_beta_w_npi
        # estimate with R0 and next generation matrix
        w = compute_w(self.prop_E_to_IA,
                  self.IP_to_IS_rate, self.IS_to_H_rate, self.IS_to_R_rate, self.IA_to_R_rate,
                  rel_inf_IP=self.rel_inf_IP_to_IS, rel_inf_IA=self.rel_inf_IA_to_IS)
        self.beta  = estimate_baseline_beta(self.parameters.np_contact_matrix, self.R0, w, self.relative_susceptibility)
        logger.info(f'baseline beta is {self.beta}')

        # Recalc/derive passed R0 with the beta we estimate
        NGM_K = build_NGM(self.beta, self.parameters.np_contact_matrix, w, self.relative_susceptibility)
        rederive_R0 = DiseaseModel.spectral_radius(NGM_K)
        logger.info(f'original R0={self.R0} and the derived one is {rederive_R0}')

        # ----------------------------------------------------
        gen_time = compute_generation_time(
            self.E_out_rate, self.IP_to_IS_rate, self.IS_to_H_rate, self.IS_to_R_rate, self.IA_to_R_rate,
            self.prop_E_to_IA, self.rel_inf_IP_to_IS, self.rel_inf_IA_to_IS)
        logger.info(f'Estimated mean generation time is {gen_time}')

        # this isn't used in this file, but _calculate_beta_w_npi inherits from this init
        self.npis_schedule = disease_model.npis_schedule

        logger.info(f'instantiated StochasticSEIRS object')
        logger.debug(f'{self.parameters}')
        return

    def expose_number_of_people(self, node:Type[Node], group:Type[Group], num_to_expose:int, vaccine_model:Type[Vaccination]):
        # this is a bulk transfer of people to move from S to E by group
        node.compartments.expose_number_of_people_bulk(group, num_to_expose)
        return

    def simulate(self, node:Type[Node], time: int, vaccine_model:Type[Vaccination]):
        """
        Main simulation logic for stochastic SEIHRD model.
        Each group (age, risk, vaccine) is simulated separately via ODE.

        S = Susceptible, E = Exposed, IA = Infectious Asymptomatic
        IP = Infectious Pre-symptomatic, IS = Infectious Symptomatic
        H = Hospitalized, R = Recovered, D = Deceased
        """

        logger.debug(f'node={node}, time={time}')

        # Need to update the node sense of time to get NPIs to take effect
        self.now = time

        # Snapshot: all compartments at start of the day so we don't call the updated subgroups
        compartments_today = {
            (group.age, group.risk, group.vaccine): np.array(node.compartments.get_compartment_vector_for(group))
            for group in node.compartments.get_all_groups()
        }

        # Get the total population of node
        total_node_pop = node.total_population()

        # beta is set for all age groups by node and day, so calc before loop over groups in node
        # the baseline beta is only one value, not age specific then NPIs modify it to be age specific
        beta_vector = self._calculate_beta_w_npi(node.node_index, node.node_id)

        # focal_group is the group we are simulating forward in time
        # contacted_group is the group causing disease spread interaction
        for focal_group in node.compartments.get_all_groups():
            # print(focal_group)  # e.g. Group object: age=0, risk=0, vaccine=0
            focal_group_compartments_today = np.array(node.compartments.get_compartment_vector_for(focal_group))
            if sum(focal_group_compartments_today) == 0:
                continue  # skip empty groups

            # Determine vaccine effect on focal group susceptibility
            # 1 is vaccinated subgroup, 0 unvaccinated subgroup
            if focal_group.vaccine == 1:
                vaccine_effectiveness_inf  = vaccine_model.vaccine_effectiveness[focal_group.age]
                vaccine_effectiveness_hosp = vaccine_model.vaccine_effectiveness_hosp[focal_group.age]
            else:
                vaccine_effectiveness_inf  = 0.0
                vaccine_effectiveness_hosp = 0.0

            #### Get focal group specific rate params ####
            IS_to_H_rate =      self.prop_IS_to_H[focal_group.risk][focal_group.age] * self.IS_to_H_rate \
                            * (1 - vaccine_effectiveness_hosp)
            IS_to_R_rate = (1 - self.prop_IS_to_H[focal_group.risk][focal_group.age]) * self.IS_to_R_rate
            H_to_D_rate  = self.prop_H_to_D[focal_group.age] * self.H_to_D_rate
            H_to_R_rate  = (1 - self.prop_H_to_D[focal_group.age]) * self.H_to_R_rates[focal_group.age]

            #### Get force of infection from each interaction subgroup ####
            # This is constant in time if we don't have an NPI schedule hitting beta each day
            transmission_rate = 0
            for contacted_group in node.compartments.get_all_groups():
                contact_rate = float(self.parameters.np_contact_matrix[focal_group.age][contacted_group.age])
                if contact_rate== 0:
                    continue

                # contacted_group_compartments_today
                S, E, IA, IP, IS, H, R, D = \
                    compartments_today[(contacted_group.age, contacted_group.risk, contacted_group.vaccine)]
                infectious_contacted = self.rel_inf_IP_to_IS * IP + \
                                       self.rel_inf_IA_to_IS * IA + \
                                       IS # `IS` is base compartment so rel inf = 1

                # infectious_contacted/total_node_pop this captures the fraction of population we need to move from S -> E
                # NOTE: Maybe an under-weighting if we should be doing age group specific: infectious_age/total_age_pop
                transmission_rate += beta_vector[contacted_group.age] * contact_rate \
                                     * (infectious_contacted/total_node_pop)
            # Apply VE to the susceptible group (focal group)
            transmission_rate *= (1.0 - vaccine_effectiveness_inf) * self.relative_susceptibility[focal_group.age]
            #print(f"{node.node_id}, {focal_group}, transmission_rate: {transmission_rate}")
            transmission_rate = max(transmission_rate, 0) # Can't have negative transmission_rate
            #transmission_prob = 1.0 - np.exp(-transmission_rate)
            #print(f"transmission probability: {transmission_prob}")

            model_parameters = (
                transmission_rate,     # S => E
                self.E_out_rate,       # E => IA & IP, goes in Poisson then split by prop
                self.prop_E_to_IA[focal_group.age], #
                self.IP_to_IS_rate,    # IP => IS
                IS_to_H_rate,          # IS => H, rate * (1 - VE_hosp) * proportion hospitalized
                IS_to_R_rate,          # IS => R, rate * (1 - proportion hospitalized)
                H_to_D_rate,           # H => D, rate * (1 -
                H_to_R_rate,           # H => R,
                self.IA_to_R_rate      # IA => R,
            )

            # Euler's Method solve of the system, can't do integer people
            daily_change = SEIHRD_model(focal_group_compartments_today, *model_parameters, rng=self.rng)
            compartments_tomorrow = focal_group_compartments_today + daily_change
            node.compartments.set_compartment_vector_for(focal_group, compartments_tomorrow)

        return


