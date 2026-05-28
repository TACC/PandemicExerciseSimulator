# Calibration And Beta

The simulator derives a baseline transmission coefficient \(\beta\) from the
requested \(R_0\) and the next-generation matrix.

Let:

```{math}
K = \beta S C \operatorname{diag}(w)
```

where:

- \(S\) is a diagonal relative susceptibility matrix;
- \(C\) is the contact matrix;
- \(w\) is an age-specific infectiousness-duration weight.

The simulator solves:

```{math}
\rho(K) = R_0
```

so:

```{math}
\beta = \frac{R_0}{\rho(S C \operatorname{diag}(w))}.
```

For basic SEIRS:

```{math}
w_i = \frac{1}{\gamma}.
```

For intervention scenarios such as antiviral treatment, baseline \(\beta\)
should be calibrated to untreated natural history. The intervention then
changes realized transmission during simulation by moving people into treated
compartments with lower infectiousness.
