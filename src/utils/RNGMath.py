#!/usr/bin/env python3
import math
from numpy.random import default_rng, mtrand


def rand_mt() -> float:
    """
    Return random number [0, 1) using Mersenne Twister pseudo-random number generator 
    """
    return (mtrand.rand())


def rand_exp(lambda_val:float) -> float:
    """
    Return negative log of a random value [0,1) divided by the provided lambda value
    """
    return (-math.log(mtrand.rand())/lambda_val)


def rand_int(lower:int, upper:int) -> int:
    """
    Expected behavior is that the int returned is in the range [lower, upper], inclusive
    """
    return (mtrand.randint(lower, upper+1))


def rand_binomial(num:int, prob:float) -> int:
    """
    Given a number and a probability, return one sample from binomial distribution
    """
    return (default_rng().binomial(num, prob))
    
