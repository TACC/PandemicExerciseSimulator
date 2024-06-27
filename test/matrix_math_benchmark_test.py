#!/usr/bin/env python3
import numpy as np
import timeit

def brute_force(my_matrix):
    flat_list = [0] * 7
    for a in range(5):
        for b in range(2):
            for c in range(2):
                for d in range(7):
                    flat_list[d] += my_matrix[a][b][c][d]
    return flat_list

def numpy_sum(my_matrix):
    return(my_matrix.sum(axis=(0,1,2)))


def main():

    my_matrix = np.zeros(( 5, 2, 2, 7 ))
    for a in range(5):
        for b in range(2):
            for c in range(2):
                for d in range(7):
                    my_matrix[a][b][c][d] = np.random.randint(1,11)


    t1=timeit.timeit(lambda: numpy_sum(my_matrix), number=100000)
    t2=timeit.timeit(lambda: brute_force(my_matrix), number=100000)
    print(f'numpy_sum={t1}, brute_force={t2}')
    return

if __name__ == '__main__':
    main()
