#!/usr/bin/env python3
import matplotlib.pyplot as plt
from numpy.random import mtrand
import statistics
import math


def rand_exp(lambda_val: float) -> float:
   return -math.log(mtrand.rand()) / lambda_val


def rand_rayleigh(sigma_val: float) -> float:
   return sigma_val * math.sqrt(-2 * math.log(mtrand.rand()))


def plot(this_list, this_title, this_offset, this_height):
   this_mean = statistics.mean(this_list)
   this_med = statistics.median(this_list)

   plt.hist(this_list, bins=100)
   plt.gca().set(title=this_title, ylabel="Frequency")
   plt.text(this_offset, this_height, f"Mean = {this_mean}", fontsize=10, color="black")
   plt.text(this_offset, this_height - 50, f"Median = {this_med}", fontsize=10, color="black")
   plt.show()


def main():
   gamma = 4.1
   gamma_list_exp = []
   gamma_list_ray = []

   for _ in range(10000):
      gamma_list_exp.append(rand_exp(1 / gamma))
      gamma_list_ray.append(rand_rayleigh(gamma))

   plot(gamma_list_exp, "rand_exp(1/gamma) where gamma=4.1", 15, 600)
   plot(gamma_list_ray, "rand_rayleigh(gamma) where gamma=4.1", 10, 250)


if __name__ == "__main__":
   main()