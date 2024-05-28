import numpy as np
from scipy.integrate import solve_ivp
import matplotlib.pyplot as plt

def SEATIRD_model(t, y, beta, nu, mu, tau, gamma, delta, rho):
    S, E, A, T, I, R, D = y
    
    dS_dt = -beta * (A + I) * S
    dE_dt = beta * (A + I) * S - nu * E
    dA_dt = nu * E - (mu + tau) * A
    dT_dt = tau * A - rho * T
    dI_dt = mu * A - (gamma + delta) * I
    dR_dt = gamma * I + rho * T
    dD_dt = delta * I
    
    return [dS_dt, dE_dt, dA_dt, dT_dt, dI_dt, dR_dt, dD_dt]

# Initial conditions
S0 = 0.99
E0 = 0.01
A0 = 0
T0 = 0
I0 = 0
R0 = 0
D0 = 0
initial_conditions = [S0, E0, A0, T0, I0, R0, D0]

# Parameters
beta = 0.3
nu = 0.2
mu = 0.1
tau = 0.05
gamma = 0.1
delta = 0.01
rho = 0.1
params = (beta, nu, mu, tau, gamma, delta, rho)

# Time points
t_span = (0, 160)
t_eval = np.linspace(*t_span, 1000)

# Solve ODE
solution = solve_ivp(SEATIRD_model, t_span, initial_conditions, args=params, t_eval=t_eval, vectorized=True)

# Extract solutions
S, E, A, T, I, R, D = solution.y

# Plot results
plt.figure(figsize=(10, 6))
plt.plot(t_eval, S, label='Susceptible')
plt.plot(t_eval, E, label='Exposed')
plt.plot(t_eval, A, label='Asymptomatic Infectious')
plt.plot(t_eval, T, label='Treated')
plt.plot(t_eval, I, label='Infected (Symptomatic)')
plt.plot(t_eval, R, label='Recovered')
plt.plot(t_eval, D, label='Deceased')

plt.xlabel('Time')
plt.ylabel('Proportion of Population')
plt.title('SEATIRD Model')
plt.legend()
plt.grid()
plt.show()
