import numpy as np
from scipy.stats import binom

def simulate_bidirectional_infections(R0, size_i, size_j, flux_ij, flux_ji, E_i, IA_i, E_j, IA_j, S_i, S_j):
    """
    Simulate the number of infections transmitted between nodes i and j.
    
    Parameters:
    R0 (float): Basic reproduction number.
    size_i (int): Population of node i.
    size_j (int): Population of node j.
    flux_ij (int): Daily travelers from node i to node j.
    flux_ji (int): Daily travelers from node j to node i.
    E_i (float): Proportion of latent individuals in node i.
    IA_i (float): Proportion of asymptomatic individuals in node i.
    E_j (float): Proportion of latent individuals in node j.
    IA_j (float): Proportion of asymptomatic individuals in node j.
    S_i (float): Susceptibility of node i.
    S_j (float): Susceptibility of node j.
    
    Returns:
    tuple: Number of infections transmitted from i to j and from j to i.
    """
    
    # Calculate probability p that an individual sparks an epidemic in node j
    p_ij = 1 - 1 / (R0 * S_j)
    # Calculate the weekly probability of traveling from node i to node j
    pij = 1 - (1 - flux_ij / size_i) ** 7
    # Calculate the expected number of infected travelers from node i to node j
    tau_ij = pij * size_i * (E_i + IA_i)
    # Number of infections transmitted from i to j
    infections_ij = binom.rvs(n=int(tau_ij), p=p_ij)
    
    # Calculate probability p that an individual sparks an epidemic in node i
    p_ji = 1 - 1 / (R0 * S_i)
    # Calculate the weekly probability of traveling from node j to node i
    pji = 1 - (1 - flux_ji / size_j) ** 7
    # Calculate the expected number of infected travelers from node j to node i
    tau_ji = pji * size_j * (E_j + IA_j)
    # Number of infections transmitted from j to i
    infections_ji = binom.rvs(n=int(tau_ji), p=p_ji)
    
    return infections_ij, infections_ji

# Example usage
R0 = 2.5
size_i = 1000
size_j = 1200
flux_ij = 50
flux_ji = 40
E_i = 0.1
IA_i = 0.05
E_j = 0.08
IA_j = 0.04
S_i = 0.75
S_j = 0.8

infections_ij, infections_ji = simulate_bidirectional_infections(R0, size_i, size_j, flux_ij, flux_ji, E_i, IA_i, E_j, IA_j, S_i, S_j)
print(f'Number of infections transmitted from node i to node j: {infections_ij}')
print(f'Number of infections transmitted from node j to node i: {infections_ji}')
