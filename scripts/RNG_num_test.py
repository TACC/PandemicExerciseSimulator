#!/usr/bin/env python3

#from RNGMath import rand_exp_mod as rand_exp
#from src.utils.RNGMath import rand_exp
import matplotlib.pyplot as plt
from numpy.random import default_rng, mtrand
import statistics
import math

tau=1.2
kappa=1.9
gamma=4.1
tau_list=[]
kappa_list=[]
gamma_list_exp=[]
gamma_list_ray=[]


def rand_exp(lambda_val:float) -> float:
    return (-math.log(mtrand.rand())/lambda_val)

def rand_rayleigh(sigma_val:float) -> float:
    return (sigma_val * math.sqrt(-2 * math.log(mtrand.rand())))



for _ in range(10000):
    #tau_list.append(rand_exp(1/tau))
    #kappa_list.append(rand_exp(1/kappa))
    gamma_list_exp.append(rand_exp(1/gamma))
    gamma_list_ray.append(rand_rayleigh(gamma))
    


def plot(this_list, this_title, this_offset, this_height):

    this_mean = statistics.mean(this_list)
    this_med = statistics.median(this_list)
    this_stdev = statistics.stdev(this_list)
    
    print(this_mean)
    print(this_med)

    plt.hist(this_list, bins=100)
    plt.gca().set(title=this_title, ylabel='Frequency');
    plt.text(this_offset, this_height, f'Mean = {this_mean}', fontsize=10, color='black')
    plt.text(this_offset, this_height-50, f'Median = {this_med}', fontsize=10, color='black')
    #plt.text(this_offset, 400, f'Stdev = {this_stdev}', fontsize=10)
    plt.show()
    #plt.savefig(fname=f'ex_out.png')

    return


#plot(tau_list, 'rand_exp(1/tau) where tau=1.2', 3)
#plot(kappa_list, 'rand_exp(1/kappa) where kappa=1.9', 5)
plot(gamma_list_exp, 'rand_exp(1/gamma) where gamma=4.1', 15, 600)
plot(gamma_list_ray, 'rand_rayleigh(gamma) where gamma=4.1', 10, 250)

